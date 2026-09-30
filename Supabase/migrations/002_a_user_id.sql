-- ============================================================
-- Phase A-2: replace user_likes / user_follows with user_id-based versions
-- ============================================================
-- Purpose:
--   remove device_id (a client-generated UUID = freely tamperable) and
--   fully replace it with user_id derived from auth.uid()
--
-- Strategy: DROP & CREATE
--   - This is before release, so zero real users is assumed; existing device_id data is thrown away
--   - The structural change is bigger than converting columns with ALTER, so rebuilding is safer
--
-- Extensions:
--   - user_likes: can like both quotes (official) and posts (UGC)
--   - user_follows: can follow both authors (historical figures) and users (regular)
--
-- Execution order:
--   001 (users table already created) → this file → 003
-- ============================================================

-- ============================================
-- 1. Drop the existing tables (discard the device_id-based ones)
-- ============================================
DROP TABLE IF EXISTS public.user_likes CASCADE;
DROP TABLE IF EXISTS public.user_follows CASCADE;

-- ============================================
-- 2. Create user_likes (supports both quote + post)
-- ============================================
CREATE TABLE public.user_likes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    quote_id   uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
    -- The FK for post_id is added after the user_posts table is created (005)
    post_id    uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    -- Exactly one of quote or post is required (both NULL and both NOT NULL are not allowed)
    CONSTRAINT user_likes_target_xor CHECK (
        (quote_id IS NOT NULL AND post_id IS NULL) OR
        (quote_id IS NULL AND post_id IS NOT NULL)
    )
);

-- The same user cannot like the same quote twice
CREATE UNIQUE INDEX user_likes_user_quote_unique
    ON public.user_likes(user_id, quote_id)
    WHERE quote_id IS NOT NULL;

-- The same user cannot like the same post twice
CREATE UNIQUE INDEX user_likes_user_post_unique
    ON public.user_likes(user_id, post_id)
    WHERE post_id IS NOT NULL;

-- Speed up aggregate queries
CREATE INDEX idx_user_likes_user_id ON public.user_likes(user_id);
CREATE INDEX idx_user_likes_quote_id ON public.user_likes(quote_id) WHERE quote_id IS NOT NULL;
CREATE INDEX idx_user_likes_post_id  ON public.user_likes(post_id)  WHERE post_id IS NOT NULL;

COMMENT ON TABLE public.user_likes IS '公式名言 (quote_id) または UGC 投稿 (post_id) へのいいね';

-- ============================================
-- 3. Create user_follows (supports both author + user)
-- ============================================
CREATE TABLE public.user_follows (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    follower_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    author_id        uuid REFERENCES public.authors(id) ON DELETE CASCADE,
    followed_user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),

    -- Only one of author or user
    CONSTRAINT user_follows_target_xor CHECK (
        (author_id IS NOT NULL AND followed_user_id IS NULL) OR
        (author_id IS NULL AND followed_user_id IS NOT NULL)
    ),

    -- Cannot follow yourself
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
