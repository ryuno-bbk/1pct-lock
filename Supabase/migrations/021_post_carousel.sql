-- ============================================================
-- 021_post_carousel.sql
-- Support for multi-image posts (up to 4 images)
-- ============================================================
-- Purpose:
--   1. Add image_count to user_posts (1 to 4, default 1)
--      - image_path (1st image/cover) stays as is. The 2nd and later images are managed by the
--        Storage path convention "{uid}/{post_id}_2.jpg" to "{post_id}_4.jpg" (no new DB columns)
--   2. Add image_count integer to the return values of fetch_mixed_feed_random /
--      fetch_following_feed / fetch_tag_feed (appended at the end, keeping all columns from 019/020)
--      - NULL::integer on the official quotes side
--      - the UGC user_posts side returns p.image_count as is
--   3. No column change for overlays jsonb (PostOverlayDTO). The app stores imageIndex inside each
--      element of the jsonb array, so no DB schema change is needed.
--      Existing overlays rows (without an imageIndex key) are read backward-compatibly by the app with
--      decodeIfPresent ?? 0.
--
-- How to apply:
--   Paste and run it in the SQL Editor of the Supabase Dashboard, or
--   `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/021_post_carousel.sql`
--   (either one).
--
-- Run order: apply in the order 019 → 020 → 021 (fetch_following_feed inherits the 020 logic
-- "if you follow the 1% official account, all official quotes").
-- Safe to run any number of times (idempotent with IF NOT EXISTS / DROP IF EXISTS)
-- ============================================================

-- ============================================
-- 1. Add image_count to user_posts (1 to 4, default 1)
-- ============================================
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS image_count integer NOT NULL DEFAULT 1;

ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_image_count_range;

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_image_count_range CHECK (
        image_count >= 1 AND image_count <= 4
    );

COMMENT ON COLUMN public.user_posts.image_count IS
    '複数枚投稿: 画像枚数 (1〜4)。1枚目は image_path、2枚目以降は Storage 側 "{post_id}_2.jpg"〜"_4.jpg" 規約';

-- ============================================
-- 2. Feed RPC v4: append image_count at the end
-- ============================================
-- Adding columns to RETURNS TABLE is not possible with CREATE OR REPLACE, so DROP → CREATE (same as
-- 019/020)

-- ---- 2-1. fetch_mixed_feed_random ----
DROP FUNCTION IF EXISTS public.fetch_mixed_feed_random(integer);

CREATE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
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

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
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
        WHERE p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ---- 2-2. fetch_following_feed ----
-- The WHERE on the quote side keeps the 020 logic "if you follow the 1% official account, all official
-- quotes".
DROP FUNCTION IF EXISTS public.fetch_following_feed(integer);

CREATE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
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
        -- If the user follows "the 1% official account" rather than "the author", all official quotes are
        -- included (same as 020)
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
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ---- 2-3. fetch_tag_feed ----
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
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;
