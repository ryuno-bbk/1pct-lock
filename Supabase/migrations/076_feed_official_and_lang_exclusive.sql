-- ============================================================
-- 076: Add the "official badge" and "language split for official accounts" to the 4 feed functions
--      (apply 075_official_badge_and_lang_exclusive.sql first)
--
-- Only 2 changes per function:
--   (1) For UGC posts, `false AS is_official_author` → `COALESCE(u.is_official, false)`
--      (the quote side's `COALESCE(a.is_official, true)` still looks at the authors table as before.
--      Do not touch it)
--   (2) Add the lang_exclusive split condition to WHERE
--
-- 🔴 The signature is unchanged, so CREATE OR REPLACE keeps the ACL, but
--    to prevent a repeat of 064 (GRANT dropped and the whole feed broke), REVOKE/GRANT is written
--    explicitly at the end of each function. The ACL before applying is saved in
--    _backups/2026-08-24_pre_075/GRANTS_before.csv. The original function definitions themselves are
--    also saved as .sql in the same folder (run those to roll back).
--
-- Measured before applying (test that temporarily made a seed account official, then rolled back):
--   ja viewer   → only the official ja posts show / the English version does not / badge true
--   en viewer   → only the official en posts show / the Japanese version does not / badge true
--   lang not synced → treated as 'ja', only the Japanese version shows (no Japanese/English duplicates
--   side by side) The number of regular users' posts is the same for all 3 = what they see does not change
-- ============================================================

-- ============================================================
-- fetch_mixed_feed_random
-- ============================================================
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50, seed text DEFAULT NULL::text)
 RETURNS TABLE(kind text, item_id uuid, body_jp text, body_en text, tags text[], like_count integer, comment_count integer, created_at timestamp with time zone, author_id uuid, author_name text, author_avatar_url text, is_official_author boolean, is_pro_author boolean, background_id integer, title text, image_path text, image_count integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH params AS MATERIALIZED (
        -- ============ Tuning weights (to adjust, change only this part and run CREATE OR REPLACE) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- max recency score of a post (right after posting)
            24.0 ::double precision AS recency_half_hours, -- the recency score halves after this much time
            0.5  ::double precision AS w_like,             -- coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- coefficient of ln(1+comment_count) (a comment shows stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- bonus for authors you follow
            1.0  ::double precision AS w_seen,             -- read penalty coefficient on ln(1+own view count) (subtracted)
            1.5  ::double precision AS w_jitter,           -- max jitter (for exploration)
            0.45 ::double precision AS quote_base,         -- 062: quotes are kept lower than user posts
            2    ::integer          AS author_cap,         -- max items from the same author per feed (posts only)
            15   ::integer          AS quote_cap,          -- 062: lower bound of quote slots when there are enough posts (adaptive)
            -- 063: seed for the order. The app passes a new value each time. If omitted, the server makes one
            COALESCE(seed, gen_random_uuid()::text) AS shuffle_seed,
            -- 073: same-language bonus. Initial value 0 = disabled (see the end of the file for how to enable it)
            0.0  ::double precision AS w_same_lang,
            -- 073: the viewer's (own) device language. Fetched with a subquery so no argument has to be added.
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
                -- 063: uniform jitter derived from seed (same seed gives the same order / a different seed always
                -- changes it)
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
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: was fixed to false
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
                -- 073: add points if the author's language (up.lang) matches the viewer's language (p.viewer_lang).
                -- If either is NULL (old posts / users with lang not synced), no points are added (stays 0, no penalty
                -- either)
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
          -- 075: Only for posts by official accounts (users.lang_exclusive = true), narrow down to the one that
          -- matches the viewer's language.
          --      Regular users with lang_exclusive = false always pass this condition = they look exactly the
          --      same as before. Posts with up.lang IS NULL = shown to everyone as "language-independent posts"
          --      (an escape hatch for official accounts). When the viewer's users.lang is not synced (NULL),
          --      treat it as 'ja'. If this were "show both", a new user's first feed would list Japanese and
          --      English duplicates, so always pick one side.
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR up.lang IS NULL
              OR up.lang = COALESCE(p.viewer_lang, 'ja')
          )
    ),
    ranked AS (
        -- posts: cap on consecutive posts from the same author (052).
        -- quotes: 1 partition per kind = quote cap for the whole feed (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- Adaptive quote slots (062): fill with quotes whatever the post candidates lack to reach limit_count
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
$function$;

-- 🔴 Restore privileges (if dropped, the feed breaks for all users).
--    CREATE OR REPLACE keeps the ACL if the signature is unchanged, but we write it explicitly to
--    prevent a repeat of 064.
REVOKE ALL ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) TO service_role;


-- ============================================================
-- fetch_following_feed
-- ============================================================
CREATE OR REPLACE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
 RETURNS TABLE(kind text, item_id uuid, body_jp text, body_en text, tags text[], like_count integer, comment_count integer, created_at timestamp with time zone, author_id uuid, author_name text, author_avatar_url text, is_official_author boolean, is_pro_author boolean, background_id integer, title text, image_path text, image_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT * FROM (
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
            NULL::integer AS image_count
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE EXISTS (
            SELECT 1 FROM public.user_follows
            WHERE follower_id = auth.uid()
              AND author_id = '11111111-1111-1111-1111-111111111111'::uuid
        )

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: was fixed to false
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id,
            p.title,
            p.image_path,
            p.image_count
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE u.id IN (
            SELECT followed_user_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND followed_user_id IS NOT NULL
        )
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
          AND p.moderation_status <> 'rejected'
          AND (
            p.moderation_status <> 'flagged'
            OR (
                NOT p.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
          -- 075: Only for posts by official accounts (users.lang_exclusive = true), narrow down to the one that
          -- matches the viewer's language.
          --      Regular users with lang_exclusive = false always pass this condition = they look exactly the
          --      same as before. Posts with p.lang IS NULL = shown to everyone as "language-independent posts"
          --      (an escape hatch for official accounts). When the viewer's users.lang is not synced (NULL),
          --      treat it as 'ja'. If this were "show both", a new user's first feed would list Japanese and
          --      English duplicates, so always pick one side.
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR p.lang IS NULL
              OR p.lang = COALESCE((SELECT vu.lang FROM public.users vu WHERE vu.id = auth.uid()), 'ja')
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$function$;

-- 🔴 Restore privileges (if dropped, the feed breaks for all users).
--    CREATE OR REPLACE keeps the ACL if the signature is unchanged, but we write it explicitly to
--    prevent a repeat of 064.
REVOKE ALL ON FUNCTION public.fetch_following_feed(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO service_role;


-- ============================================================
-- fetch_tag_feed
-- ============================================================
CREATE OR REPLACE FUNCTION public.fetch_tag_feed(target_tag text, limit_count integer DEFAULT 50)
 RETURNS TABLE(kind text, item_id uuid, body_jp text, body_en text, tags text[], like_count integer, comment_count integer, created_at timestamp with time zone, author_id uuid, author_name text, author_avatar_url text, is_official_author boolean, is_pro_author boolean, background_id integer, title text, image_path text, image_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT * FROM (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            ARRAY[q.category] AS tags,
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
            NULL::integer AS image_count
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE q.category = target_tag

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: was fixed to false
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id,
            p.title,
            p.image_path,
            p.image_count
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE target_tag = ANY(p.tags)
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
          AND p.moderation_status <> 'rejected'
          AND (
            p.moderation_status <> 'flagged'
            OR (
                NOT p.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
          -- 075: Only for posts by official accounts (users.lang_exclusive = true), narrow down to the one that
          -- matches the viewer's language.
          --      Regular users with lang_exclusive = false always pass this condition = they look exactly the
          --      same as before. Posts with p.lang IS NULL = shown to everyone as "language-independent posts"
          --      (an escape hatch for official accounts). When the viewer's users.lang is not synced (NULL),
          --      treat it as 'ja'. If this were "show both", a new user's first feed would list Japanese and
          --      English duplicates, so always pick one side.
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR p.lang IS NULL
              OR p.lang = COALESCE((SELECT vu.lang FROM public.users vu WHERE vu.id = auth.uid()), 'ja')
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$function$;

-- 🔴 Restore privileges (if dropped, the feed breaks for all users).
--    CREATE OR REPLACE keeps the ACL if the signature is unchanged, but we write it explicitly to
--    prevent a repeat of 064.
REVOKE ALL ON FUNCTION public.fetch_tag_feed(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO service_role;


-- ============================================================
-- search_posts
-- ============================================================
CREATE OR REPLACE FUNCTION public.search_posts(query text, limit_count integer DEFAULT 30)
 RETURNS TABLE(kind text, item_id uuid, body_jp text, body_en text, tags text[], like_count integer, comment_count integer, created_at timestamp with time zone, author_id uuid, author_name text, author_avatar_url text, is_official_author boolean, is_pro_author boolean, background_id integer, title text, image_path text, image_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH normalized AS (
        SELECT
            s.stripped AS raw,
            replace(replace(replace(s.stripped, '\', '\\'), '%', '\%'), '_', '\_') AS q
        FROM (
            SELECT CASE
                       WHEN trim(query) LIKE '#%' THEN substring(trim(query) FROM 2)
                       ELSE trim(query)
                   END AS stripped
        ) s
    )
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
        COALESCE(u.is_official, false) AS is_official_author,  -- 075: was fixed to false
        COALESCE(u.is_pro, false) AS is_pro_author,
        up.background_id,
        up.title,
        up.image_path,
        up.image_count
    FROM public.user_posts up
    JOIN public.users u ON u.id = up.user_id
    CROSS JOIN normalized n
    WHERE query IS NOT NULL
      AND n.q <> ''
      AND (
        up.title ILIKE '%' || n.q || '%'
        OR EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE t ILIKE n.q || '%'
        )
      )
      AND up.user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND up.moderation_status <> 'rejected'
      AND (
        up.moderation_status <> 'flagged'
        OR (
            NOT up.report_flagged
            AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
        )
      )
      -- 075: Only for posts by official accounts (users.lang_exclusive = true), narrow down to the one that
      -- matches the viewer's language.
      --      Regular users with lang_exclusive = false always pass this condition = they look exactly the
      --      same as before. Posts with up.lang IS NULL = shown to everyone as "language-independent posts"
      --      (an escape hatch for official accounts). When the viewer's users.lang is not synced (NULL),
      --      treat it as 'ja'. If this were "show both", a new user's first feed would list Japanese and
      --      English duplicates, so always pick one side.
      AND (
          NOT COALESCE(u.lang_exclusive, false)
          OR up.lang IS NULL
          OR up.lang = COALESCE((SELECT vu.lang FROM public.users vu WHERE vu.id = auth.uid()), 'ja')
      )
    ORDER BY
        CASE WHEN EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE lower(t) = lower(n.raw)
        ) THEN 0 ELSE 1 END,
        up.like_count DESC,
        up.created_at DESC
    LIMIT limit_count;
$function$;

-- 🔴 Restore privileges (if dropped, the feed breaks for all users).
--    CREATE OR REPLACE keeps the ACL if the signature is unchanged, but we write it explicitly to
--    prevent a repeat of 064.
REVOKE ALL ON FUNCTION public.search_posts(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_posts(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_posts(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_posts(text, integer) TO service_role;


-- ============================================================
-- Operations: set up an official account
-- ============================================================
-- is_official    = show the verified badge
-- lang_exclusive = show the Japanese/English version depending on the viewer
-- 🔴 Narrowed twice with exists so it cannot hit anything other than seed accounts (@seed.invalid).
update public.users u
   set is_official    = true,
       lang_exclusive = true
 where u.handle = 'ai_motivation'
   and exists (select 1 from auth.users au
                where au.id = u.id and au.email like '%@seed.invalid');

-- Accident detection: abort if a real user has the flag
do $$
declare n int;
begin
    select count(*) into n from public.users u join auth.users au on au.id=u.id
     where (u.is_official or u.lang_exclusive)
       and au.email not like '%@seed.invalid';
    if n > 0 then
        raise exception '実ユーザーに is_official/lang_exclusive が付いた (% 件)。中断する', n;
    end if;
end $$;

-- ============================================================
-- Operations: steps to post Japanese/English versions
-- ============================================================
-- ⚠️ The studio (Supabase/seed/studio/server.py:197) decides a post's lang
--    from "the account's users.lang" (`lang = urow[0].get("lang") or "ja"`).
--    ai_motivation has users.lang = 'ja', so posts made from the studio **all become ja**.
--    → After posting an English version, fix lang to 'en' for just that post with the SQL below.
--      An UPDATE on user_posts does not fire the moderation trigger (INSERT only), so it is safe.
--
--   -- Check the latest ai_motivation posts
--   select p.id, p.lang, p.title, p.created_at
--     from public.user_posts p join public.users u on u.id = p.user_id
--    where u.handle = 'ai_motivation' order by p.created_at desc limit 10;
--
--   -- Make it the English version
--   update public.user_posts set lang = 'en' where id = '<post id of the English version>';
--
--   -- Posts that do not depend on language (e.g. images with no text) are shown to everyone if set to
--   NULL
--   update public.user_posts set lang = null where id = '<post id>';
--
-- 🔴 For accounts with lang_exclusive = true, "if you post only one version, it reaches only users of
--    that language". On days when you make only one of Japanese/English, set lang = null so it is
--    shown to everyone. To stop the language split:
--      update public.users set lang_exclusive = false where handle = 'ai_motivation';
