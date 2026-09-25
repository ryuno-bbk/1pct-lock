-- ============================================================
-- 019_post_v2.sql
-- 投稿v2: 背景 + 自由配置テキストを1枚のJPEGに焼き込む方式
-- ============================================================
-- 目的:
--   1. user_posts に title / image_path / overlays を追加
--      - title:      任意のタイトル文字列 (# タグを含みうる、60文字以内)
--      - image_path: Storage `post-images` バケット内のパス (焼き込み済みJPEG)
--      - overlays:   再編集/検索/モデレ用の生テキスト+配置情報 (jsonb 配列)
--      旧投稿 (text_jp/text_en のみ) はそのまま共存。2言語入力の新規UIは廃止。
--   2. Storage バケット `post-images` を新設 (avatars と同じ RLS パターン)
--   3. fetch_mixed_feed_random / fetch_following_feed / fetch_tag_feed の戻り値に
--      title text, image_path text を追加 (012 の全カラムを維持したまま末尾に追加)
--      - 公式 quotes 側は両方 NULL
--      - UGC user_posts 側は p.title / p.image_path をそのまま返す
--
-- 適用方法:
--   このプロジェクトは Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/019_post_v2.sql`
--   のいずれか。まだ未適用 (2026-07-05 時点)。
--
-- 実行順序: 018 完了後。何度実行しても安全 (IF NOT EXISTS / DROP IF EXISTS で冪等)
-- ============================================================

-- ============================================
-- 1. user_posts へ title / image_path / overlays 追加
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
-- 2. text_jp / text_en / image_path のいずれか必須 (旧制約を差し替え)
-- ============================================
ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_text_required;

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_text_required CHECK (
        text_jp IS NOT NULL OR text_en IS NOT NULL OR image_path IS NOT NULL
    );

-- ============================================
-- 3. Storage バケット `post-images` 作成 (public, 10MB 上限, jpeg固定)
-- ============================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'post-images',
    'post-images',
    true,
    10485760,                                               -- 10 MB (焼き込み済み1080x1920 JPEG 想定)
    ARRAY['image/jpeg']
)
ON CONFLICT (id) DO UPDATE SET
    public              = EXCLUDED.public,
    file_size_limit     = EXCLUDED.file_size_limit,
    allowed_mime_types  = EXCLUDED.allowed_mime_types;

-- ============================================
-- 4. Storage RLS ポリシー (013 の avatars パターンを踏襲)
-- ============================================
DROP POLICY IF EXISTS "post_images_public_read"  ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_insert" ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_update" ON storage.objects;
DROP POLICY IF EXISTS "post_images_owner_delete" ON storage.objects;

-- 4-1. 誰でも read 可 (public バケット、フィード表示用)
CREATE POLICY "post_images_public_read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'post-images');

-- 4-2. 自分の uid フォルダ配下のみ INSERT 可
-- パス例: "{uid}/{post_id}.jpg" → (storage.foldername(name))[1] が uid
CREATE POLICY "post_images_owner_insert"
    ON storage.objects
    FOR INSERT
    WITH CHECK (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 4-3. 自分の uid フォルダ配下のみ UPDATE 可 (upsert 上書き用)
CREATE POLICY "post_images_owner_update"
    ON storage.objects
    FOR UPDATE
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 4-4. 自分の uid フォルダ配下のみ DELETE 可 (投稿削除 / insert失敗時のロールバック用)
CREATE POLICY "post_images_owner_delete"
    ON storage.objects
    FOR DELETE
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================
-- 5. フィード RPC v3: title / image_path を末尾に追加
-- ============================================
-- RETURNS TABLE 列追加は CREATE OR REPLACE 不可なので DROP → CREATE (012 に倣う)

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
