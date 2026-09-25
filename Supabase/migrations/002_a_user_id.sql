-- ============================================================
-- Phase A-2: user_likes / user_follows を user_id ベースに置換
-- ============================================================
-- 目的:
--   device_id (クライアント生成 UUID = 改ざん自由) を廃止し、
--   auth.uid() 由来の user_id ベースに完全置換
--
-- 戦略: DROP & CREATE
--   - リリース前のため実ユーザーゼロ前提、既存 device_id データは捨てる
--   - ALTER でカラム変換するより構造変更が大きいので作り直しが安全
--
-- 拡張点:
--   - user_likes: quote (公式) と post (UGC) 両方にいいね可能
--   - user_follows: author (偉人) と user (一般) 両方フォロー可能
--
-- 実行順序:
--   001 (users テーブル作成済み) → このファイル → 003
-- ============================================================

-- ============================================
-- 1. 既存テーブル削除（device_id ベースを廃棄）
-- ============================================
DROP TABLE IF EXISTS public.user_likes CASCADE;
DROP TABLE IF EXISTS public.user_follows CASCADE;

-- ============================================
-- 2. user_likes 新規作成（quote + post 両対応）
-- ============================================
CREATE TABLE public.user_likes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    quote_id   uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
    -- post_id は user_posts テーブル作成後 (005) に FK 追加する
    post_id    uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    -- quote か post のどちらか片方だけが必須（両方 NULL も両方 NOT NULL も不可）
    CONSTRAINT user_likes_target_xor CHECK (
        (quote_id IS NOT NULL AND post_id IS NULL) OR
        (quote_id IS NULL AND post_id IS NOT NULL)
    )
);

-- 同じ user が同じ quote に重複いいね不可
CREATE UNIQUE INDEX user_likes_user_quote_unique
    ON public.user_likes(user_id, quote_id)
    WHERE quote_id IS NOT NULL;

-- 同じ user が同じ post に重複いいね不可
CREATE UNIQUE INDEX user_likes_user_post_unique
    ON public.user_likes(user_id, post_id)
    WHERE post_id IS NOT NULL;

-- 集計クエリ高速化
CREATE INDEX idx_user_likes_user_id ON public.user_likes(user_id);
CREATE INDEX idx_user_likes_quote_id ON public.user_likes(quote_id) WHERE quote_id IS NOT NULL;
CREATE INDEX idx_user_likes_post_id  ON public.user_likes(post_id)  WHERE post_id IS NOT NULL;

COMMENT ON TABLE public.user_likes IS '公式名言 (quote_id) または UGC 投稿 (post_id) へのいいね';

-- ============================================
-- 3. user_follows 新規作成（author + user 両対応）
-- ============================================
CREATE TABLE public.user_follows (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    follower_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    author_id        uuid REFERENCES public.authors(id) ON DELETE CASCADE,
    followed_user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),

    -- author か user のどちらか片方だけ
    CONSTRAINT user_follows_target_xor CHECK (
        (author_id IS NOT NULL AND followed_user_id IS NULL) OR
        (author_id IS NULL AND followed_user_id IS NOT NULL)
    ),

    -- 自分自身をフォローできない
    CONSTRAINT user_follows_no_self CHECK (
        follower_id IS DISTINCT FROM followed_user_id
    )
);

CREATE UNIQUE INDEX user_follows_follower_author_unique
    ON public.user_follows(follower_id, author_id)
    WHERE author_id IS NOT NULL;

CREATE UNIQUE INDEX user_follows_follower_user_unique
    ON public.user_follows(follower_id, followed_user_id)
    WHERE followed_user_id IS NOT NULL;

CREATE INDEX idx_user_follows_follower_id      ON public.user_follows(follower_id);
CREATE INDEX idx_user_follows_author_id        ON public.user_follows(author_id) WHERE author_id IS NOT NULL;
CREATE INDEX idx_user_follows_followed_user_id ON public.user_follows(followed_user_id) WHERE followed_user_id IS NOT NULL;

COMMENT ON TABLE public.user_follows IS '偉人 (author_id) または 一般ユーザー (followed_user_id) のフォロー関係';
