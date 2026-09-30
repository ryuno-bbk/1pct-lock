-- ============================================================================
-- 073_feed_language_affinity.sql
-- Add the groundwork for the feed to prioritize "posts in the same language as the viewer"
-- (2026-08-01)
-- ============================================================================
--
-- [Purpose]
-- Store the poster's device language (user_posts.lang) and the viewer's device language (users.lang),
-- and add a "bonus if the same language" term to the scoring of fetch_mixed_feed_random.
-- However, it ships with the weight at 0 (disabled) right after this file is applied. See §3 for why.
--
-- [🔴 Strictly required: do not change the arguments or RETURNS TABLE]
-- The signature and return columns of
-- fetch_mixed_feed_random(limit_count integer DEFAULT 50, seed text DEFAULT NULL)
-- are not changed at all from 063_feed_seeded_shuffle.sql.
-- Everything is done with CREATE OR REPLACE FUNCTION only (no DROP FUNCTION is written).
-- With CREATE OR REPLACE, the existing GRANT/REVOKE (the permissions fixed in 064) are kept as they
-- are, so an accident like the one in 064 ("anon can execute it again after the replacement") cannot
-- happen.
-- ⚠️ If the arguments or return value of this function ever need to change, DROP FUNCTION becomes
-- required, and the same REVOKE FROM PUBLIC / FROM anon + GRANT TO authenticated as in 064
-- must be written at the end of the same file (the lesson from 063, which missed this once and left
-- all posts readable without authentication in production).
--
-- [Design decisions]
--   1. The lang column is added only to user_posts / users. It is not added to quotes
--      (official quotes have no concept of a specific poster's device language, so the
--      same-language bonus only needs to target UGC posts (kind='post')).
--   2. No CHECK constraint. The AppLanguage enum (en/ja) is designed on the assumption that more
--      cases will be added (see the comment in AppLanguage.swift). A CHECK would require a
--      migration for every new language, which contradicts ADD COLUMN being "hard to get stuck".
--      The expected values are AppLanguage rawValues ("en" / "ja" / future additions), but
--      the DB side keeps it as free text.
--   3. The initial value of the weight w_same_lang is 0. At launch the corpus is almost 100%
--      Japanese (see the recent commits: the history up to publishing the legal URLs, dropping
--      real names, etc.), and there is no data to judge "how feed diversity and engagement change
--      when the same language is prioritized". With 0, we can verify that the feed output is
--      exactly the same before and after applying this file (§5 verification step (C)). Once
--      English-language posts increase, it can be enabled just by running CREATE OR REPLACE on this
--      function in the SQL Editor and raising the w_same_lang value. No app change or redeploy is
--      needed (follows the same "only rewrite the params CTE" design as 029/063).
--   4. The viewer's language is fetched without adding an argument, using
--      (SELECT u.lang FROM public.users u WHERE u.id = auth.uid()). auth.uid() is already used by
--      this function in the follow/block filters (063:137-139, 154-158), so it resolves fine
--      under SECURITY DEFINER too.
--   5. No index is added. fetch_mixed_feed_random references user_posts.lang only in a CASE
--      expression (score bonus) inside the scored CTE, not as a WHERE filter condition. This
--      function already filters with created_at > now() - interval '30 days' and then scans all
--      remaining rows every time (063:164, expected to use idx_user_posts_created_at), so adding a
--      partial index on lang alone would not change this function's execution plan (an index
--      that is not used for filtering is pointless). If lang is ever used in a WHERE clause
--      (e.g. a "show only this language" filter feature), consider a composite/partial index
--      like idx_user_posts_created_at at that point.
--
-- Execution order: after 072 is done. Safe to run any number of times (idempotent pattern of
-- ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE FUNCTION).
-- ============================================================================

-- ============================================================================
-- 1. Add the lang column
-- ============================================================================
ALTER TABLE public.user_posts ADD COLUMN IF NOT EXISTS lang text;
ALTER TABLE public.users      ADD COLUMN IF NOT EXISTS lang text;

COMMENT ON COLUMN public.user_posts.lang IS
    '投稿者の端末言語。投稿時にクライアントが mainLanguage (UserDefaults) の値を書き込む '
    '(UserPostService.createPost / createPostV2)。想定値は AppLanguage の rawValue '
    '("en"/"ja"、将来 case 追加で増える) だが CHECK 制約は付けない。'
    '073: fetch_mixed_feed_random の同一言語ボーナス判定に使う。旧投稿は NULL '
    '(NULL は「言語不明」として同一言語ボーナスの対象外= 通常のスコアのまま)';

COMMENT ON COLUMN public.users.lang IS
    '閲覧者(本人)の端末言語。サインイン時 (AppBlockerApp.syncSignInState) と '
    '設定の言語 Picker 変更時 (SettingsListView の @AppStorage("mainLanguage") を '
    'UserDefaults.didChangeNotification 経由で検知) にクライアントが同期する。'
    '想定値は AppLanguage の rawValue。CHECK 制約は付けない (将来の言語追加に備える)。'
    '073: fetch_mixed_feed_random がこの列を読んで同一言語ボーナスの基準にする。'
    '未同期のユーザーは NULL (同一言語ボーナスは常に0扱い)';

-- ============================================================================
-- 2. fetch_mixed_feed_random: add the same-language bonus term (CREATE OR REPLACE only)
-- ============================================================================
-- Copies the current definition from 063 in full. The only changes are these 2 places:
--   (a) add w_same_lang (initial value 0) and viewer_lang to the params CTE
--   (b) in the score expression of the post branch, add "add w_same_lang if up.lang matches
--       viewer_lang"
-- Everything else (quote branch / ranked / quota / final SELECT / ORDER BY / LIMIT) is unchanged.
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(
    limit_count integer DEFAULT 50,
    seed text DEFAULT NULL
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    WITH params AS MATERIALIZED (
        -- ============ Tuning weights (adjust by rewriting only this part and running CREATE OR REPLACE) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- Max recency score (right after posting)
            24.0 ::double precision AS recency_half_hours, -- The recency score halves after this much time
            0.5  ::double precision AS w_like,             -- Coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- Coefficient of ln(1+comment_count) (a comment shows stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- Bonus for posters you follow
            1.0  ::double precision AS w_seen,             -- Coefficient of the read penalty ln(1+own view count) (deduction)
            1.5  ::double precision AS w_jitter,           -- Max jitter (exploration)
            0.45 ::double precision AS quote_base,         -- 062: quotes are weighted lower than user posts
            2    ::integer          AS author_cap,         -- Max number of posts from the same poster per feed (posts only)
            15   ::integer          AS quote_cap,          -- 062: minimum quote slots when there are enough posts (adaptive)
            -- 063: seed for the order. The app passes a new value every time. If omitted, the server creates one
            COALESCE(seed, gen_random_uuid()::text) AS shuffle_seed,
            -- 073: same-language bonus. Initial value 0 = disabled (see the end of the file for how to enable it)
            0.0  ::double precision AS w_same_lang,
            -- 073: the viewer's (own) device language. Fetched with a subquery, without adding an argument.
            -- If users.lang is not synced (NULL), the same-language bonus is always treated as 0
            (SELECT u.lang FROM public.users u WHERE u.id = auth.uid()) AS viewer_lang
    ),
    scored AS (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            CASE WHEN q.category IS NULL THEN '{}'::text[] ELSE ARRAY[q.category] END AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path,
            NULL::integer AS image_count,
            (
                p.quote_base
                + p.w_like * ln(1 + q.like_count)
                + p.w_comment * ln(1 + q.comment_count)
                -- 063: uniform jitter derived from the seed (the same seed gives the same order / a different seed
                -- always changes it)
                + p.w_jitter * (
                    ('x' || substr(md5(q.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        CROSS JOIN params p

        UNION ALL

        SELECT
            'post'::text   AS kind,
            up.id           AS item_id,
            up.text_jp      AS body_jp,
            up.text_en      AS body_en,
            up.tags,
            up.like_count,
            up.comment_count,
            up.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            up.background_id,
            up.title,
            up.image_path,
            up.image_count,
            (
                p.w_recency / (
                    1 + GREATEST(EXTRACT(EPOCH FROM (now() - up.created_at)) / 3600.0, 0)
                        / p.recency_half_hours
                )
                + p.w_like * ln(1 + up.like_count)
                + p.w_comment * ln(1 + up.comment_count)
                + CASE
                    WHEN EXISTS (
                        SELECT 1 FROM public.user_follows f
                        WHERE f.follower_id = auth.uid() AND f.followed_user_id = u.id
                    ) THEN p.w_follow
                    ELSE 0
                  END
                - p.w_seen * ln(1 + COALESCE(pv.view_count, 0))
                -- 073: add points if the poster's language (up.lang) matches the viewer's language (p.viewer_lang).
                -- If either is NULL (old posts / users whose lang is not synced), no points are added (stays 0, no
                -- deduction either)
                + CASE
                    WHEN up.lang IS NOT NULL AND up.lang = p.viewer_lang THEN p.w_same_lang
                    ELSE 0
                  END
                + p.w_jitter * (
                    ('x' || substr(md5(up.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.user_posts up
        JOIN public.users u ON u.id = up.user_id
        LEFT JOIN public.post_views pv
            ON pv.post_id = up.id AND pv.viewer_id = auth.uid()
        CROSS JOIN params p
        WHERE up.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
          AND up.moderation_status <> 'rejected'
          AND (
            up.moderation_status <> 'flagged'
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
          AND up.created_at > now() - interval '30 days'
    ),
    ranked AS (
        -- posts: cap on consecutive posts from the same poster (052).
        -- quotes: one partition per kind = the quote cap for the whole feed (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- Adaptive quote slots (062): fill the shortfall of post candidates below limit_count with quotes
        SELECT GREATEST(
            p.quote_cap,
            limit_count - (
                SELECT count(*)::integer FROM ranked r2
                WHERE r2.kind = 'post' AND r2.author_rank <= p.author_cap
            )
        ) AS quote_allow
        FROM params p
    )
    SELECT
        r.kind, r.item_id, r.body_jp, r.body_en, r.tags, r.like_count, r.comment_count, r.created_at,
        r.author_id, r.author_name, r.author_avatar_url, r.is_official_author, r.is_pro_author,
        r.background_id, r.title, r.image_path, r.image_count
    FROM ranked r
    CROSS JOIN params p
    CROSS JOIN quota q
    WHERE (r.kind = 'quote' AND r.author_rank <= q.quote_allow)
       OR (r.kind = 'post'  AND r.author_rank <= p.author_cap)
    ORDER BY r.score DESC
    LIMIT limit_count;
$$;

-- ⚠️ CREATE OR REPLACE FUNCTION keeps the existing GRANT/REVOKE (the privilege tables are not
-- touched unless you DROP). So the following, set in 064,
--   REVOKE ... FROM PUBLIC, anon / GRANT ... TO authenticated
-- is kept here without doing anything. Confirm with verification query (B) in §5 that it is
-- actually kept.
-- ⚠️ Warning again: if this function ever needs to be dropped with DROP FUNCTION and recreated,
-- then to avoid the same accident as 063→064 (GRANT/REVOKE was forgotten after the DROP, so all
-- posts became readable without authentication), always put the following at the end of the same
-- file that does the DROP:
--   REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM PUBLIC;
--   REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM anon;
--   GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) TO authenticated;
-- Write these lines.

COMMENT ON FUNCTION public.fetch_mixed_feed_random(integer, text) IS
    'おすすめフィード (名言+投稿の混合、スコアリング+seed 由来ジッター)。'
    '052: 同一投稿者は author_cap 件まで / 062: 名言は適応型 quote_cap / '
    '063: 並びの種をアプリが渡す (毎回変えれば必ず並びが変わる。同じ seed なら再現する) / '
    '073: 同一言語ボーナス (w_same_lang、初期値0=無効。SQL Editor で数値を上げるだけで '
    '有効化できる。有効化のしかたは本ファイル末尾のコメント参照)';

-- ============================================================================
-- 3. How to enable (read this when raising w_same_lang from 0)
-- ============================================================================
-- Prerequisite: user_posts.lang / users.lang must be filled in for enough users.
-- Specifically, check "the share of rows where lang is NULL" with the SQL below, and enable it only
-- after confirming that it is filled in for most active posts and users:
--
--   SELECT
--     (SELECT count(*) FILTER (WHERE lang IS NULL) FROM public.user_posts
--        WHERE created_at > now() - interval '30 days') AS posts_lang_null_30d,
--     (SELECT count(*) FROM public.user_posts
--        WHERE created_at > now() - interval '30 days')  AS posts_total_30d,
--     (SELECT count(*) FILTER (WHERE lang IS NULL) FROM public.users
--        WHERE total_block_seconds > 0)                   AS users_lang_null_active,
--     (SELECT count(*) FROM public.users
--        WHERE total_block_seconds > 0)                   AS users_total_active;
--
-- To enable, re-run this function with CREATE OR REPLACE FUNCTION and, in this line of the params CTE,
--   0.0  ::double precision AS w_same_lang,
-- rewrite only the "0.0" (the arguments and RETURNS TABLE do not change, so the existing
-- GRANT/REVOKE is kept here too).
--
-- Guide for the value (relative to the existing weights):
--   - w_follow = 1.2 (constant bonus for posters you follow) is a reference for a level that
--     "clearly has an effect but does not dominate". The same-language bonus is a similar kind of
--     term (a gentle attribute-based tilt, not a strong individual interest signal), so starting
--     from about 0.3 to 0.8 is recommended.
--   - Unless it is made extremely large compared with the w_recency max of 3.0 or the ln() terms
--     for likes/comments (once popular, 0.5 to 0.7 × ln(N+1) simply adds up to 2 to 3 points),
--     it will not completely overturn the recency/popularity ranking.
--   - A value larger than w_jitter (max 1.5) makes being in the same language a more dominant
--     factor than the exploration jitter. To avoid a split where "exposure is almost zero just
--     because the language differs", use about w_jitter (around 1.5) as a rough upper limit.
--   - A value clearly above 1.2 (w_follow) (e.g. 2.0 or more) makes "same-language posts from
--     people you do not follow" rank above "other-language posts from people you follow". Whether
--     that is intended (language barrier > relationships) is an operational judgment.
--   - Symptom of raising it too far: the feed of users of a given language becomes only posts in
--     that language, and the mix of a multilingual community is lost. If something looks wrong,
--     setting it back to 0 immediately restores the old behavior (equivalent to 063).
-- ============================================================================

-- ============================================================================
-- 4. Verification query (A): are the lang columns added to both tables
-- ============================================================================
-- SELECT table_name, column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name IN ('user_posts', 'users')
--   AND column_name = 'lang'
-- ORDER BY table_name;
-- Expected result: 2 rows, user_posts.lang / users.lang, both data_type = 'text', is_nullable = 'YES'

-- ============================================================================
-- 5. Verification query (B): are the permissions kept after CREATE OR REPLACE
--    (same form as the aclexplode check in 065/068, narrowed to fetch_mixed_feed_random)
-- ============================================================================
-- SELECT p.proname,
--        pg_get_function_identity_arguments(p.oid) AS args,
--        CASE
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
--               THEN '🔴 PUBLIC (executable even without authentication)'
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 'anon'::regrole::oid AND a.privilege_type = 'EXECUTE')
--               THEN '🟠 granted to anon'
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 'authenticated'::regrole::oid AND a.privilege_type = 'EXECUTE')
--               THEN '✅ closed (authenticated only)'
--          ELSE '⚠️ not granted to authenticated either (possible regression)'
--        END AS verdict
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'fetch_mixed_feed_random';
-- Expected result: 1 row with verdict = '✅ closed (authenticated only)' (it must never be granted to
-- anon)

-- ============================================================================
-- 6. Verification query (C): confirm that the feed output has not changed with w_same_lang = 0
-- ============================================================================
-- Pass the same seed before and after applying this file, and confirm that the results match
-- exactly:
--
--   -- Run in the SQL Editor before applying (with everything up to 072 applied) and save the result:
--   SELECT kind, item_id, score IS NOT NULL AS has_score  -- score is not in the return value,
--   -- so only the order of item_id is compared
--   FROM fetch_mixed_feed_random(30, 'verify-073-fixed-seed');
--
--   -- After applying 073, rerun with the same seed:
--   SELECT kind, item_id
--   FROM fetch_mixed_feed_random(30, 'verify-073-fixed-seed');
--
-- If the order of item_id (from the 1st to the 30th item) matches exactly, it proves that the
-- w_same_lang=0 term adds nothing to the score (only the CASE's ELSE 0 is in effect, and the value
-- being added is itself 0, so not even floating-point rounding error appears).
-- If you want to check the difference mechanically, you can also save both results to temporary
-- tables and confirm that
--   SELECT * FROM before_result EXCEPT SELECT * FROM after_result;
-- returns 0 rows.
-- ============================================================================
