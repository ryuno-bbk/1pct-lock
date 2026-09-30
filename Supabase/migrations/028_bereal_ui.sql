-- ============================================
-- 028_bereal_ui.sql
-- Backend for the big BeReal-style UI overhaul (spec finalized 2026-07-10)
--
--   1. user_posts.view_count (total taps that opened the post detail, visible to everyone)
--   2. post_views table (raw log of who viewed what, when and how many times)
--      → also serves as the training signal for the later "recommendation algorithm". Unique view
--        counts can be derived too
--   3. record_post_view RPC (counts views. Self-views of your own posts are not counted)
--   4. fetch_feed_extras RPC (batch fetch of likers ≤3 + comment previews ≤3 for feed cards
--      with post/quote mixed. 1 round trip per screen)
--
-- Design notes:
--   - view_count is a denormalized counter for display (same style as users.total_block_seconds)
--   - post_views is an upsert with a (post_id, viewer_id) PK. Direct INSERT/UPDATE is
--     not allowed for the client, only through record_post_view (same style as block_sessions)
--   - Comment previews return the latest 3, oldest first (the natural reading order)
--   - Likers exclude blocked users, latest 3 people
-- ============================================

-- --------------------------------------------
-- 1. user_posts.view_count
-- --------------------------------------------

ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.user_posts.view_count IS '投稿詳細が開かれた合計タップ数 (record_post_view で加算、自己閲覧は除外)';

-- --------------------------------------------
-- 2. post_views (view log / signal source for the recommendation algorithm)
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

-- No direct access at all (only through record_post_view / future aggregation RPCs)
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
        -- E.g. a post just deleted. Silently ignore it instead of erroring (view counting is best-effort)
        RETURN;
    END IF;

    -- Self-views of your own posts are not counted
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
--    Return "likers (≤3)" + "comment previews (≤3)" for the cards shown in the feed,
--    with post / quote mixed, in 1 query
-- --------------------------------------------

CREATE OR REPLACE FUNCTION public.fetch_feed_extras(
    post_ids  uuid[] DEFAULT '{}',
    quote_ids uuid[] DEFAULT '{}'
)
RETURNS TABLE (
    kind     text,
    item_id  uuid,
    likers   jsonb,   -- [{user_id, display_name, avatar_url}] newest first ≤3
    comments jsonb    -- [{id, author_name, text}] latest 3, oldest first
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
            -- Pick the latest 3, then reorder them oldest first
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
