-- ============================================================
-- 076: フィード4関数に「公式マーク」と「公式アカウントの言語出し分け」を入れる
--      (先に 075_official_badge_and_lang_exclusive.sql を適用しておくこと)
--
-- 変更点は各関数あたり2箇所だけ:
--   ① UGC投稿の `false AS is_official_author` → `COALESCE(u.is_official, false)`
--      (名言側の `COALESCE(a.is_official, true)` は従来どおり authors テーブルを見る。触らない)
--   ② WHERE に lang_exclusive の出し分け条件を追加
--
-- 🔴 シグネチャは変えていないので CREATE OR REPLACE で ACL は保持されるが、
--    064 (GRANT 落ちでフィード全滅) の再発防止として各関数の末尾に REVOKE/GRANT を明示する。
--    適用前の ACL は _backups/2026-08-24_pre_075/GRANTS_before.csv に保存済み。
--    元の関数定義そのものも同フォルダに .sql で保存してある (戻したいときはそれを流す)。
--
-- 適用前の実測 (種アカウントを一時的に公式化して rollback したテスト):
--   ja閲覧者   → 公式のja投稿だけが出る / 英語版は出ない / バッジ true
--   en閲覧者   → 公式のen投稿だけが出る / 日本語版は出ない / バッジ true
--   lang未同期 → 'ja' 扱いで日本語版だけが出る (日英が重複して並ばない)
--   一般ユーザーの投稿の件数は3者すべてで同一 = 見え方は変わらない
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
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ジッターの最大値 (探索性)
            0.45 ::double precision AS quote_base,         -- 062: 名言はユーザー投稿より控えめに
            2    ::integer          AS author_cap,         -- 1フィードあたり同一投稿者の最大件数 (postsのみ)
            15   ::integer          AS quote_cap,          -- 062: 投稿が十分ある時の名言枠の下限 (適応型)
            -- 063: 並びの種。アプリが毎回新しい値を渡す。省略時はサーバーで1つ作る
            COALESCE(seed, gen_random_uuid()::text) AS shuffle_seed,
            -- 073: 同一言語ボーナス。初期値0 = 無効 (有効化のしかたはファイル末尾を参照)
            0.0  ::double precision AS w_same_lang,
            -- 073: 閲覧者(自分)の端末言語。引数を増やさずサブクエリで取得する。
            -- users.lang が未同期 (NULL) なら同一言語ボーナスは常に0扱いになる
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
                -- 063: seed 由来の一様ジッター (同じ seed なら同じ並び / 変えれば必ず変わる)
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
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: 旧 false 固定
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
                -- 073: 投稿者の言語 (up.lang) が閲覧者の言語 (p.viewer_lang) と一致すれば加点。
                -- どちらかが NULL (旧投稿 / lang 未同期ユーザー) なら加点しない (0のまま、減点もしない)
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
          -- 075: 公式アカウント (users.lang_exclusive = true) の投稿だけ、閲覧者の言語に合う1本に絞る。
          --      lang_exclusive = false の一般ユーザーはこの条件を必ず素通りする = 見え方は従来と完全に同じ。
          --      up.lang IS NULL の投稿 = 「言語を問わない投稿」として全員に出す (公式の逃げ道)。
          --      閲覧者の users.lang が未同期 (NULL) のときは 'ja' 扱い。
          --      ここを「両方出す」にすると新規ユーザーの初回フィードに日英の重複が並ぶため、必ず片方に寄せる。
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR up.lang IS NULL
              OR up.lang = COALESCE(p.viewer_lang, 'ja')
          )
    ),
    ranked AS (
        -- posts: 同一投稿者の連投キャップ (052)。
        -- quotes: kind 単位の1パーティション = フィード全体の名言キャップ (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- 適応型の名言枠 (062): 投稿候補が limit_count に足りない分は名言で満たす
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

-- 🔴 権限の復元 (落とすと全ユーザーでフィードが壊れる)。
--    CREATE OR REPLACE はシグネチャ不変なら ACL を保持するが、064 の再発防止として明示的に書く。
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
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: 旧 false 固定
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
          -- 075: 公式アカウント (users.lang_exclusive = true) の投稿だけ、閲覧者の言語に合う1本に絞る。
          --      lang_exclusive = false の一般ユーザーはこの条件を必ず素通りする = 見え方は従来と完全に同じ。
          --      p.lang IS NULL の投稿 = 「言語を問わない投稿」として全員に出す (公式の逃げ道)。
          --      閲覧者の users.lang が未同期 (NULL) のときは 'ja' 扱い。
          --      ここを「両方出す」にすると新規ユーザーの初回フィードに日英の重複が並ぶため、必ず片方に寄せる。
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR p.lang IS NULL
              OR p.lang = COALESCE((SELECT vu.lang FROM public.users vu WHERE vu.id = auth.uid()), 'ja')
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$function$;

-- 🔴 権限の復元 (落とすと全ユーザーでフィードが壊れる)。
--    CREATE OR REPLACE はシグネチャ不変なら ACL を保持するが、064 の再発防止として明示的に書く。
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
            COALESCE(u.is_official, false) AS is_official_author,  -- 075: 旧 false 固定
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
          -- 075: 公式アカウント (users.lang_exclusive = true) の投稿だけ、閲覧者の言語に合う1本に絞る。
          --      lang_exclusive = false の一般ユーザーはこの条件を必ず素通りする = 見え方は従来と完全に同じ。
          --      p.lang IS NULL の投稿 = 「言語を問わない投稿」として全員に出す (公式の逃げ道)。
          --      閲覧者の users.lang が未同期 (NULL) のときは 'ja' 扱い。
          --      ここを「両方出す」にすると新規ユーザーの初回フィードに日英の重複が並ぶため、必ず片方に寄せる。
          AND (
              NOT COALESCE(u.lang_exclusive, false)
              OR p.lang IS NULL
              OR p.lang = COALESCE((SELECT vu.lang FROM public.users vu WHERE vu.id = auth.uid()), 'ja')
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$function$;

-- 🔴 権限の復元 (落とすと全ユーザーでフィードが壊れる)。
--    CREATE OR REPLACE はシグネチャ不変なら ACL を保持するが、064 の再発防止として明示的に書く。
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
        COALESCE(u.is_official, false) AS is_official_author,  -- 075: 旧 false 固定
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
      -- 075: 公式アカウント (users.lang_exclusive = true) の投稿だけ、閲覧者の言語に合う1本に絞る。
      --      lang_exclusive = false の一般ユーザーはこの条件を必ず素通りする = 見え方は従来と完全に同じ。
      --      up.lang IS NULL の投稿 = 「言語を問わない投稿」として全員に出す (公式の逃げ道)。
      --      閲覧者の users.lang が未同期 (NULL) のときは 'ja' 扱い。
      --      ここを「両方出す」にすると新規ユーザーの初回フィードに日英の重複が並ぶため、必ず片方に寄せる。
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

-- 🔴 権限の復元 (落とすと全ユーザーでフィードが壊れる)。
--    CREATE OR REPLACE はシグネチャ不変なら ACL を保持するが、064 の再発防止として明示的に書く。
REVOKE ALL ON FUNCTION public.search_posts(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_posts(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_posts(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_posts(text, integer) TO service_role;


-- ============================================================
-- 運用: 公式アカウントを立てる
-- ============================================================
-- is_official    = 認証バッジを出す
-- lang_exclusive = 日本語版/英語版を閲覧者ごとに出し分ける
-- 🔴 種アカウント (@seed.invalid) 以外に当たらないよう exists で二重に絞っている。
update public.users u
   set is_official    = true,
       lang_exclusive = true
 where u.handle = 'ai_motivation'
   and exists (select 1 from auth.users au
                where au.id = u.id and au.email like '%@seed.invalid');

-- 事故検知: 実ユーザーにフラグが付いていたら中断する
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
-- 運用: 日本語版/英語版を投稿する手順
-- ============================================================
-- ⚠️ スタジオ (Supabase/seed/studio/server.py:197) は投稿の lang を
--    「アカウントの users.lang」から決めている (`lang = urow[0].get("lang") or "ja"`)。
--    ai_motivation は users.lang = 'ja' なので、スタジオから出すと**全部 ja になる**。
--    → 英語版を出したら、下の SQL で その投稿だけ lang を 'en' に直す。
--      user_posts の UPDATE はモデレーション trigger (INSERT のみ) を叩かないので安全。
--
--   -- 直近の ai_motivation の投稿を確認
--   select p.id, p.lang, p.title, p.created_at
--     from public.user_posts p join public.users u on u.id = p.user_id
--    where u.handle = 'ai_motivation' order by p.created_at desc limit 10;
--
--   -- 英語版にする
--   update public.user_posts set lang = 'en' where id = '<英語版のpost id>';
--
--   -- 言語を問わない投稿 (文字が入っていない画像など) は NULL にすると全員に出る
--   update public.user_posts set lang = null where id = '<post id>';
--
-- 🔴 lang_exclusive = true のアカウントは「片方だけ投稿すると片方の言語のユーザーにしか届かない」。
--    日英どちらか一方しか作らない日は lang = null にして全員に出すこと。
--    出し分けをやめたいときは:
--      update public.users set lang_exclusive = false where handle = 'ai_motivation';
