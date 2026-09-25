-- ============================================
-- 028_bereal_ui.sql
-- BeReal 風 UI 大改修のバックエンド (2026-07-10 確定仕様)
--
--   1. user_posts.view_count (投稿詳細が開かれた合計タップ数、全員に見える)
--   2. post_views テーブル (誰がいつ何回見たかの生ログ)
--      → 後続の「おすすめアルゴリズム」の学習信号を兼ねる。ユニーク閲覧数も導出可能
--   3. record_post_view RPC (計上。自分の投稿の自己閲覧はカウントしない)
--   4. fetch_feed_extras RPC (フィードカード用のいいねした人≤3 + コメントプレビュー≤3 を
--      post/quote 混在でバッチ取得。1 画面 1 ラウンドトリップ)
--
-- 設計メモ:
--   - view_count は表示用の非正規化カウンタ (users.total_block_seconds と同じ流儀)
--   - post_views は (post_id, viewer_id) PK の upsert 方式。直接の INSERT/UPDATE は
--     クライアントに許さず、record_post_view 経由のみ (block_sessions と同じ流儀)
--   - コメントプレビューは最新 3 件を古い順で返す (読み順が自然になる)
--   - いいねした人はブロック済みユーザーを除外、最新 3 人
-- ============================================

-- --------------------------------------------
-- 1. user_posts.view_count
-- --------------------------------------------

ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.user_posts.view_count IS '投稿詳細が開かれた合計タップ数 (record_post_view で加算、自己閲覧は除外)';

-- --------------------------------------------
-- 2. post_views (閲覧ログ / おすすめアルゴリズムの信号源)
-- --------------------------------------------

CREATE TABLE IF NOT EXISTS public.post_views (
    post_id         uuid NOT NULL REFERENCES public.user_posts(id) ON DELETE CASCADE,
    viewer_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    view_count      integer NOT NULL DEFAULT 1,
    first_viewed_at timestamptz NOT NULL DEFAULT now(),
    last_viewed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, viewer_id)
);

COMMENT ON TABLE public.post_views IS '投稿詳細の閲覧ログ。表示用カウンタは user_posts.view_count、こちらはユニーク判定 + おすすめアルゴリズム用の生データ';

CREATE INDEX IF NOT EXISTS idx_post_views_viewer_last
    ON public.post_views (viewer_id, last_viewed_at DESC);

ALTER TABLE public.post_views ENABLE ROW LEVEL SECURITY;

-- 直接アクセスは一切許可しない (record_post_view / 将来の集計 RPC 経由のみ)
DROP POLICY IF EXISTS post_views_no_direct ON public.post_views;

-- --------------------------------------------
-- 3. record_post_view RPC
-- --------------------------------------------

CREATE OR REPLACE FUNCTION public.record_post_view(target_post_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id uuid := auth.uid();
    post_owner_id   uuid;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT user_id INTO post_owner_id
    FROM public.user_posts
    WHERE id = target_post_id;

    IF post_owner_id IS NULL THEN
        -- 削除直後の投稿など。エラーにせず黙って無視 (閲覧計上はベストエフォート)
        RETURN;
    END IF;

    -- 自分の投稿の自己閲覧はカウントしない
    IF post_owner_id = current_user_id THEN
        RETURN;
    END IF;

    INSERT INTO public.post_views (post_id, viewer_id)
        VALUES (target_post_id, current_user_id)
    ON CONFLICT (post_id, viewer_id) DO UPDATE
        SET view_count     = public.post_views.view_count + 1,
            last_viewed_at = now();

    UPDATE public.user_posts
        SET view_count = view_count + 1
        WHERE id = target_post_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_post_view(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_post_view(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.record_post_view(uuid) TO authenticated;

-- --------------------------------------------
-- 4. fetch_feed_extras RPC
--    フィードに表示中のカード群の「いいねした人 (≤3)」+「コメントプレビュー (≤3)」を
--    post / quote 混在で 1 回のクエリで返す
-- --------------------------------------------

CREATE OR REPLACE FUNCTION public.fetch_feed_extras(
    post_ids  uuid[] DEFAULT '{}',
    quote_ids uuid[] DEFAULT '{}'
)
RETURNS TABLE (
    kind     text,
    item_id  uuid,
    likers   jsonb,   -- [{user_id, display_name, avatar_url}] 最新順 ≤3
    comments jsonb    -- [{id, author_name, text}] 最新3件を古い順
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    WITH targets AS (
        SELECT 'post'::text AS kind, unnest(post_ids)  AS item_id
        UNION ALL
        SELECT 'quote'::text,        unnest(quote_ids)
    ),
    my_blocks AS (
        SELECT blocked_user_id FROM public.user_blocks
        WHERE blocker_id = auth.uid()
    ),
    liker_rows AS (
        SELECT
            t.kind,
            t.item_id,
            u.id           AS user_id,
            u.display_name,
            u.avatar_url,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY l.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_likes l
            ON (t.kind = 'post'  AND l.post_id  = t.item_id)
            OR (t.kind = 'quote' AND l.quote_id = t.item_id)
        JOIN public.users u ON u.id = l.user_id
        WHERE l.user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
    ),
    comment_rows AS (
        SELECT
            t.kind,
            t.item_id,
            c.id       AS comment_id,
            u.display_name AS author_name,
            c.text,
            c.created_at,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY c.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_comments c
            ON (t.kind = 'post'  AND c.post_id  = t.item_id)
            OR (t.kind = 'quote' AND c.quote_id = t.item_id)
        JOIN public.users u ON u.id = c.author_user_id
        WHERE c.author_user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
    )
    SELECT
        t.kind,
        t.item_id,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'user_id',      lr.user_id,
                'display_name', lr.display_name,
                'avatar_url',   lr.avatar_url
            ) ORDER BY lr.rn)
            FROM liker_rows lr
            WHERE lr.kind = t.kind AND lr.item_id = t.item_id AND lr.rn <= 3
        ), '[]'::jsonb) AS likers,
        COALESCE((
            -- 最新 3 件を拾ってから古い順に並べ直す
            SELECT jsonb_agg(jsonb_build_object(
                'id',          cr.comment_id,
                'author_name', cr.author_name,
                'text',        cr.text
            ) ORDER BY cr.created_at ASC)
            FROM comment_rows cr
            WHERE cr.kind = t.kind AND cr.item_id = t.item_id AND cr.rn <= 3
        ), '[]'::jsonb) AS comments
    FROM targets t;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) TO authenticated;
