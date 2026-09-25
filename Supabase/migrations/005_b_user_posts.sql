-- ============================================================
-- Phase B-2 (S9): user_posts + RLS + 関連 RPC
-- ============================================================
-- 目的:
--   ユーザー投稿 (UGC) を保存する user_posts テーブル + そのいいね機能
--   + 公式 quotes と UGC user_posts を混在してフィードに出す RPC 3 種
--
-- 設計判断 (S9 確定):
--   - body 単一 (jp/en 分離なし、500 文字制限)。表示は AppLanguage で切替不要 (投稿そのまま表示)
--   - tags text[] 0-3 個、既存 16 種から選択
--   - status / モデレ列なし (Phase B-3 = S10 で user_reports / user_blocks を別テーブルで実装)
--   - 投稿者は自分の投稿を削除可
--   - 「おすすめ」フィード = quotes + user_posts ランダム混在
--   - 「フォロー中」フィード = フォロー対象の quotes + user_posts (新着順)
--   - ハッシュタグタップ = 同タグの quotes + user_posts 混在 (ランダム)
--
-- RPC 返却型:
--   既存 Quote モデルとの整合性のため body_jp / body_en の 2 カラムを返す
--   - 公式 quote: body_jp = quotes.text_jp, body_en = quotes.text_en
--   - UGC post:  body_jp = user_posts.body, body_en = NULL (Quote.displayPrimary がフォールバック)
--
-- 前提:
--   001 (users) / 002 (user_likes/user_follows) / 003 (RLS+RPC) / 004 (is_official) 実行済み
--   user_likes.post_id は 002 で予約済み、FK のみ未追加
--
-- 実行順序:
--   004 完了後 → このファイル (S9)
-- ============================================================

-- ============================================
-- 1. user_posts テーブル
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_posts (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    body       text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 500),
    tags       text[] NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(tags) <= 3),
    like_count integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_posts IS 'UGC: ユーザー投稿。body 単一、tags は既存 16 種から 0-3 個';
COMMENT ON COLUMN public.user_posts.tags IS '既存 quotes.category と同じプール (mindset / action / ... / life)';

-- updated_at 自動更新
DROP TRIGGER IF EXISTS user_posts_set_updated_at ON public.user_posts;
CREATE TRIGGER user_posts_set_updated_at
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ============================================
-- 2. インデックス
-- ============================================
CREATE INDEX IF NOT EXISTS idx_user_posts_created_at
    ON public.user_posts (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_posts_user_id_created_at
    ON public.user_posts (user_id, created_at DESC);

-- ハッシュタグ検索高速化
CREATE INDEX IF NOT EXISTS idx_user_posts_tags
    ON public.user_posts USING GIN (tags);

-- ============================================
-- 3. user_likes.post_id FK 追加 (002 で予約済み列)
-- ============================================
ALTER TABLE public.user_likes
    DROP CONSTRAINT IF EXISTS user_likes_post_id_fkey;

ALTER TABLE public.user_likes
    ADD CONSTRAINT user_likes_post_id_fkey
    FOREIGN KEY (post_id) REFERENCES public.user_posts(id) ON DELETE CASCADE;

-- ============================================
-- 4. RLS
-- ============================================
ALTER TABLE public.user_posts ENABLE ROW LEVEL SECURITY;

-- 冪等性のため既存ポリシーを drop (S1 草案の古いポリシー名もカバー)
DROP POLICY IF EXISTS "user_posts_select_approved" ON public.user_posts;
DROP POLICY IF EXISTS "user_posts_select_own"      ON public.user_posts;
DROP POLICY IF EXISTS "user_posts_select_all"      ON public.user_posts;
DROP POLICY IF EXISTS "user_posts_insert_own"      ON public.user_posts;
DROP POLICY IF EXISTS "user_posts_update_own"      ON public.user_posts;
DROP POLICY IF EXISTS "user_posts_delete_own"      ON public.user_posts;

-- SELECT: 全員可
CREATE POLICY "user_posts_select_all"
    ON public.user_posts FOR SELECT
    USING (true);

-- INSERT: 自分の user_id でのみ
CREATE POLICY "user_posts_insert_own"
    ON public.user_posts FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- UPDATE: 自分の投稿のみ (like_count は後述 trigger で保護)
CREATE POLICY "user_posts_update_own"
    ON public.user_posts FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- DELETE: 自分の投稿のみ
CREATE POLICY "user_posts_delete_own"
    ON public.user_posts FOR DELETE
    USING (auth.uid() = user_id);

-- ============================================
-- 5. like_count 改ざん防止 trigger
-- ============================================
CREATE OR REPLACE FUNCTION public.protect_user_posts_like_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('role') = 'service_role' THEN
        RETURN NEW;
    END IF;

    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only for users (use toggle_post_like)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_protect_columns   ON public.user_posts; -- 旧トリガー名 (S1 草案)
DROP TRIGGER IF EXISTS user_posts_protect_like_count ON public.user_posts;
CREATE TRIGGER user_posts_protect_like_count
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_like_count();

-- 旧 S1 草案の protect_user_posts_columns 関数は status カラムを参照しているため削除
DROP FUNCTION IF EXISTS public.protect_user_posts_columns() CASCADE;

-- ============================================
-- 6. toggle_post_like RPC (UGC いいね)
-- ============================================
CREATE OR REPLACE FUNCTION public.toggle_post_like(target_post_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id  uuid := auth.uid();
    existing_like_id uuid;
    new_count        integer;
    result_is_liked  boolean;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.user_posts WHERE id = target_post_id) THEN
        RAISE EXCEPTION 'Post not found: %', target_post_id;
    END IF;

    SELECT id INTO existing_like_id
    FROM public.user_likes
    WHERE user_id = current_user_id AND post_id = target_post_id;

    IF existing_like_id IS NOT NULL THEN
        DELETE FROM public.user_likes WHERE id = existing_like_id;
        UPDATE public.user_posts
            SET like_count = GREATEST(like_count - 1, 0)
            WHERE id = target_post_id
            RETURNING like_count INTO new_count;
        result_is_liked := false;
    ELSE
        INSERT INTO public.user_likes (user_id, post_id)
            VALUES (current_user_id, target_post_id);
        UPDATE public.user_posts
            SET like_count = like_count + 1
            WHERE id = target_post_id
            RETURNING like_count INTO new_count;
        result_is_liked := true;
    END IF;

    RETURN jsonb_build_object(
        'is_liked',   result_is_liked,
        'like_count', new_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.toggle_post_like(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.toggle_post_like(uuid) TO authenticated;

-- ============================================
-- 7. fetch_mixed_feed_random RPC (おすすめフィード)
-- ============================================
-- 公式 quotes + UGC user_posts を完全ランダム混在で返す
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,         -- 'quote' or 'post'
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
            p.body         AS body_jp,
            NULL::text     AS body_en,
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
-- 8. fetch_following_feed RPC (フォロー中フィード)
-- ============================================
-- 自分がフォローしている author + user の投稿のみ (新着順)
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
            p.body         AS body_jp,
            NULL::text     AS body_en,
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
-- 9. fetch_tag_feed RPC (ハッシュタグタップ用)
-- ============================================
-- 指定タグを含む quotes + user_posts を混在 (ランダム)
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
            p.body         AS body_jp,
            NULL::text     AS body_en,
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
