-- ============================================================
-- 008_b_user_posts_v2.sql
-- user_posts: body 単一 → text_jp / text_en 2 カラムに変更
-- ============================================================
-- 目的:
--   ユーザー投稿を Quote と同じ二言語構造に揃える
--   - text_jp / text_en どちらか片方必須 (両方 NULL 不可)
--   - 文字数制限: jp <= 200, en <= 400
--   - 3 つの RPC (mixed / following / tag) も p.text_jp / p.text_en を返すように修正
--
-- 前提:
--   005 (実行済み = body 単一仕様) → このファイルで上書き
--
-- 注意:
--   既存 user_posts データがある場合、body の内容は text_jp に移行する
--   (新規アプリ・実データなしの想定なので実害なし)
-- ============================================================

-- ============================================
-- 1. text_jp / text_en カラム追加 + 既存 body から移行
-- ============================================
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS text_jp text,
    ADD COLUMN IF NOT EXISTS text_en text;

-- 既存 body の内容を text_jp に移行 (空ならスキップ)
UPDATE public.user_posts
    SET text_jp = body
    WHERE body IS NOT NULL AND text_jp IS NULL;

-- ============================================
-- 2. 旧 body カラムの制約を解除して削除
-- ============================================
ALTER TABLE public.user_posts
    DROP COLUMN IF EXISTS body;

-- ============================================
-- 3. 新 CHECK 制約
-- ============================================
ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_text_required;

ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_text_jp_length;

ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_text_en_length;

-- 少なくとも片方必須
ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_text_required CHECK (
        text_jp IS NOT NULL OR text_en IS NOT NULL
    );

-- 文字数: 日本語 200 / 英語 400 (S9 ユーザー指定)
ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_text_jp_length CHECK (
        text_jp IS NULL OR char_length(text_jp) <= 200
    );

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_text_en_length CHECK (
        text_en IS NULL OR char_length(text_en) <= 400
    );

COMMENT ON COLUMN public.user_posts.text_jp IS '日本語本文 (任意、最大 200 文字)';
COMMENT ON COLUMN public.user_posts.text_en IS '英語本文 (任意、最大 400 文字)';

-- ============================================
-- 4. RPC 書き直し: fetch_mixed_feed_random
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
    is_official_author  boolean
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
            COALESCE(a.is_official, true) AS is_official_author
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
            false          AS is_official_author
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ============================================
-- 5. RPC 書き直し: fetch_following_feed
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
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
    is_official_author  boolean
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
            COALESCE(a.is_official, true) AS is_official_author
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
            false          AS is_official_author
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE u.id IN (
            SELECT followed_user_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND followed_user_id IS NOT NULL
        )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ============================================
-- 6. RPC 書き直し: fetch_tag_feed
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_tag_feed(
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
    is_official_author  boolean
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
            COALESCE(a.is_official, true) AS is_official_author
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
            false          AS is_official_author
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE target_tag = ANY(p.tags)
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;
