-- ============================================================
-- 029_recommend_feed.sql
-- おすすめフィード: fetch_mixed_feed_random のヒューリスティックスコアリング化
-- + 3 フィード RPC 共通の comment_count 返却リグレッション修復
-- ============================================================
-- 設計: Fable 5 / 実装: Sonnet 5
--
-- 目的:
--   1. fetch_mixed_feed_random は現在 ORDER BY random() の純粋ランダム。
--      これを「新しさ / 人気 / フォロー / 既読ペナルティ / 探索性ジッター」の
--      加重和スコアで並べ替えるヒューリスティック方式に置換する。ML・新テーブルは
--      一切追加しない (021/027 と同じフィード RPC 3 本の形をそのまま拡張するのみ)。
--   2. 021_post_carousel.sql の DROP → CREATE で戻り値の列を作り直した際、
--      017_b_quote_comments.sql で追加した comment_count 返却列が誤って欠落した
--      (リグレッション)。Swift 側 FeedItem は decodeIfPresent ?? 0 なのでクラッシュ
--      はしないが、フィードカードの「N件のコメントをすべて表示」が常に0件になって
--      いた。本ファイルで fetch_mixed_feed_random / fetch_following_feed /
--      fetch_tag_feed の 3 本とも comment_count 返却を復活させる。
--
-- 設計判断:
--   - スコア式は「新しさ + 人気 (いいね/コメント) + フォローボーナス - 既読ペナルティ
--     + 探索ジッター」の単純な加重和。学習は行わず、全項の重みは params CTE に
--     ハードコードした定数。運用中にチューニングしたくなったら本関数を
--     CREATE OR REPLACE で書き換えて params の数値を変えるだけで良い
--     (027 の moderation_config ルーブリック方式と同じ「SQL Editor で完結」思想)。
--   - 名言 (quote) は created_at が実際の投稿タイミングではなく一括投入日なので、
--     「新しさ」に意味がない。新しさ減衰の代わりに固定ベース点 quote_base を与え、
--     いいね/コメントの人気項だけで UGC 投稿と競争させる。
--   - 既読ペナルティは post_views (028_bereal_ui.sql) の自分の閲覧回数
--     (viewer_id = auth.uid() の view_count) を ln 減点として使う。post_views は
--     投稿詳細をタップして開いた回数のログなので、「一度タップして見た投稿は
--     徐々にフィードで沈んでいく」という効果になる (フィード上でスクロールして
--     通り過ぎただけの投稿は対象外、タップ詳細のみが信号)。
--   - ジッター (w_jitter * random()) は毎回まったく同じ順序にならないようにする
--     ための探索性項。スコアが僅差の投稿同士の順位を撹拌し、同じフィードを
--     再読み込みしても代わり映えしない体験を避ける。
--   - 重みは全て params CTE (CROSS JOIN) に集約。ユーザー (運営) が SQL Editor で
--     本関数を CREATE OR REPLACE し直すだけでチューニング可能な設計にしてある。
--   - 戻り値の列数が増える (comment_count 追加) ため CREATE OR REPLACE は使えず、
--     021 と同じ流儀で DROP FUNCTION IF EXISTS → CREATE FUNCTION とする。
--     DROP すると既存の GRANT/REVOKE も消えるため、3 本とも末尾で再設定する。
--   - fetch_following_feed (created_at DESC) と fetch_tag_feed (random()) は
--     並び順を変更しない。今回はどちらも comment_count 復活のみが変更点。
--   - quote 枝・post 枝の SELECT 列・JOIN・WHERE (moderation フィルタ / ブロック
--     フィルタ / フォロー判定) は 027_ai_moderation.sql の定義を一言一句踏襲する。
--     021 をベースにしていない (021 には moderation フィルタが無く、それをベース
--     にすると層1/層2フィルタが退行してしまうため)。
--
-- 実行順序: 028 完了後。何度実行しても安全 (DROP FUNCTION IF EXISTS → CREATE の
-- 冪等パターン)。新テーブル・新列は追加しない。
-- ============================================================

-- ============================================================
-- 1. fetch_mixed_feed_random (ヒューリスティックスコアリング版)
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_mixed_feed_random(integer);

CREATE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    WITH params AS (
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ランダムジッターの最大値 (探索性)
            0.8  ::double precision AS quote_base          -- 名言の固定ベース点 (新しさ減衰の代替)
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
                + random() * p.w_jitter
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
                + random() * p.w_jitter
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
    )
    SELECT
        kind, item_id, body_jp, body_en, tags, like_count, comment_count, created_at,
        author_id, author_name, author_avatar_url, is_official_author, is_pro_author,
        background_id, title, image_path, image_count
    FROM scored
    ORDER BY score DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ============================================================
-- 2. fetch_following_feed (comment_count 復活のみ、created_at DESC は維持)
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_following_feed(integer);

CREATE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
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
        -- 「著者をフォロー」ではなく「1% 公式アカウントをフォロー」していれば全公式名言が対象 (020 と同じ)
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
            false          AS is_official_author,
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ============================================================
-- 3. fetch_tag_feed (comment_count 復活のみ、random() は維持)
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_tag_feed(text, integer);

CREATE FUNCTION public.fetch_tag_feed(
    target_tag  text,
    limit_count integer DEFAULT 50
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
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
            false          AS is_official_author,
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;

-- ============================================================
-- 4. 動作確認用クエリ (実行不要、コメント)
-- ============================================================
-- SELECT kind, item_id, like_count, comment_count, created_at FROM fetch_mixed_feed_random(20);
-- 同じクエリを2回叩いて順序が変わること (ジッター) を確認
