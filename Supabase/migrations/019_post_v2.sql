-- ============================================================
-- 019_post_v2.sql
-- Post v2: bake the background + freely placed text into one JPEG
-- ============================================================
-- Purpose:
--   1. Add title / image_path / overlays to user_posts
--      - title:      optional title string (may contain # tags, 60 characters max)
--      - image_path: path in the Storage `post-images` bucket (baked JPEG)
--      - overlays:   raw text + placement info for re-editing/search/moderation (jsonb array)
--      Old posts (text_jp/text_en only) stay as they are side by side. The new bilingual input UI was
--      dropped.
--   2. Create a new Storage bucket `post-images` (same RLS pattern as avatars)
--   3. Add title text, image_path text to the return values of fetch_mixed_feed_random /
--      fetch_following_feed / fetch_tag_feed (appended at the end, keeping all columns from 012)
--      - both are NULL on the official quotes side
--      - the UGC user_posts side returns p.title / p.image_path as is
--
-- How to apply:
--   In this project, either paste and run it in the SQL Editor of the Supabase Dashboard,
--   or `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/019_post_v2.sql`.
--   Not applied yet (as of 2026-07-05).
--
-- Run order: after 018 is done. Safe to run any number of times (idempotent with IF NOT EXISTS /
-- DROP IF EXISTS)
-- ============================================================

-- ============================================
-- 1. Add title / image_path / overlays to user_posts
-- ============================================
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS title      text,
    ADD COLUMN IF NOT EXISTS image_path text,
    ADD COLUMN IF NOT EXISTS overlays   jsonb;

ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_title_length;

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_title_length CHECK (
        title IS NULL OR char_length(title) <= 60
    );

COMMENT ON COLUMN public.user_posts.title      IS '投稿v2: タイトル (# タグを含みうる、任意、60文字以内)';
COMMENT ON COLUMN public.user_posts.image_path IS '投稿v2: Storage post-images バケット内のパス ({uid}/{post_id}.jpg)。旧投稿は NULL';
COMMENT ON COLUMN public.user_posts.overlays   IS '投稿v2: 焼き込み前の生テキスト+配置情報 (jsonb 配列)。検索/モデレ/将来の再編集用、表示には使わない';

-- ============================================
-- 2. One of text_jp / text_en / image_path is required (replaces the old constraint)
-- ============================================
ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_text_required;

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_text_required CHECK (
        text_jp IS NOT NULL OR text_en IS NOT NULL OR image_path IS NOT NULL
    );

-- ============================================
-- 3. Create the Storage bucket `post-images` (public, 10MB limit, jpeg only)
-- ============================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'post-images',
    'post-images',
    true,
    10485760,                                               -- 10 MB (assumes a baked 1080x1920 JPEG)
    ARRAY['image/jpeg']
)
ON CONFLICT (id) DO UPDATE SET
    public              = EXCLUDED.public,
    file_size_limit     = EXCLUDED.file_size_limit,
    allowed_mime_types  = EXCLUDED.allowed_mime_types;

-- ============================================
-- 4. Storage RLS policies (follows the avatars pattern in 013)
-- ============================================
DROP POLICY IF EXISTS "post_images_public_read"  ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_insert" ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_update" ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_delete" ON storage.objects;

-- 4-1. Anyone can read (public bucket, for showing the feed)
CREATE POLICY "post_images_public_read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'post-images');

-- 4-2. INSERT allowed only under your own uid folder
-- Path example: "{uid}/{post_id}.jpg" → (storage.foldername(name))[1] is the uid
CREATE POLICY "post_images_owner_insert"
    ON storage.objects
    FOR INSERT
    WITH CHECK (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 4-3. UPDATE allowed only under your own uid folder (for upsert overwrite)
CREATE POLICY "post_images_owner_update"
    ON storage.objects
    FOR UPDATE
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 4-4. DELETE allowed only under your own uid folder (for post deletion / rollback when insert fails)
CREATE POLICY "post_images_owner_delete"
    ON storage.objects
    FOR DELETE
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================
-- 5. Feed RPC v3: append title / image_path at the end
-- ============================================
-- Adding columns to RETURNS TABLE is not possible with CREATE OR REPLACE, so DROP → CREATE (same as 012)

-- ---- 5-1. fetch_mixed_feed_random ----
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
    image_path          text
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
            NULL::text    AS image_path
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
            p.image_path
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

-- ---- 5-2. fetch_following_feed ----
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
    image_path          text
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
            NULL::text    AS image_path
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE a.id IN (
            SELECT author_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND author_id IS NOT NULL
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
            p.image_path
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

-- ---- 5-3. fetch_tag_feed ----
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
    image_path          text
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
            NULL::text    AS image_path
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
            p.image_path
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
