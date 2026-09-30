-- ============================================================
-- 022_sns_minimum.sql
-- SNS minimum pack: handle (@handle) + user search + new post notifications
-- ============================================================
-- Purpose:
--   1. Introduce users.handle (@handle). Format/reserved word checks + unique constraint
--      + automatic backfill for existing users
--   2. is_handle_available(h) RPC: for the real-time availability check on the handle edit screen
--   3. search_users(query, limit_count) RPC: for the user search screen
--   4. Add 'new_post' to user_notifications.kind, and add a trigger that notifies all followers
--      of a new post by a user they follow
--
-- Target: environments where 019 / 020 / 021 are applied.
-- How to apply:
--   Paste and run in the SQL Editor of the Supabase Dashboard, or
--   `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/022_sns_minimum.sql`
--
-- Execution order: after 021 is done. Safe to run any number of times
--   (idempotent with the IF NOT EXISTS / DROP ... IF EXISTS / ON CONFLICT patterns)
-- ============================================================

-- ============================================
-- 1. Add the users.handle column
-- ============================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS handle text;

COMMENT ON COLUMN public.users.handle IS
    '@handle。小文字英数字+ドット+アンダースコア、3〜20文字、一意。予約語は使用不可';

-- Format constraint (lowercase letters/digits/dots/underscores only, 3 to 20 chars)
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_handle_format;

ALTER TABLE public.users
    ADD CONSTRAINT users_handle_format CHECK (
        handle IS NULL OR handle ~ '^[a-z0-9._]{3,20}$'
    );

-- Reserved word constraint (prevents impersonating official account / operator handles)
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_handle_not_reserved;

ALTER TABLE public.users
    ADD CONSTRAINT users_handle_not_reserved CHECK (
        handle IS NULL OR lower(handle) NOT IN (
            'onepercent', 'one_percent', '1percent',
            'official', 'admin', 'arete', 'support', 'moderator', 'system'
        )
    );

-- Unique index (multiple NULLs allowed, unique only when there is a value)
CREATE UNIQUE INDEX IF NOT EXISTS users_handle_unique
    ON public.users (handle)
    WHERE handle IS NOT NULL;

-- ============================================
-- 2. Backfill for existing users
-- ============================================
-- Generated mechanically from the first 8 digits (hex) of the uuid. The theoretical collision
-- probability is negligible, but for idempotent reruns + just in case of a collision, duplicates are
-- avoided by extending the number of digits.
-- (The format constraint allows up to {3,20} chars, so with the 'user_' prefix the max is 20 chars =
-- up to 15 digits)
DO $$
DECLARE
    r         RECORD;
    candidate text;
    hex_id    text;
BEGIN
    FOR r IN SELECT id FROM public.users WHERE handle IS NULL LOOP
        hex_id    := replace(r.id::text, '-', '');
        candidate := 'user_' || substr(hex_id, 1, 8);

        IF EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) THEN
            candidate := 'user_' || substr(hex_id, 1, 12);
        END IF;

        IF EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) THEN
            candidate := 'user_' || substr(hex_id, 1, 15);
        END IF;

        -- Final fallback (astronomically unlikely): regenerate with random values until the collision is gone
        WHILE EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) LOOP
            candidate := 'user_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
        END LOOP;

        UPDATE public.users SET handle = candidate WHERE id = r.id;
    END LOOP;
END $$;

-- ============================================
-- 3. is_handle_available RPC
-- ============================================
-- Matches the format AND is not a reserved word AND does not exist for another user (your own
-- current handle counts as available)
CREATE OR REPLACE FUNCTION public.is_handle_available(h text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    normalized text := lower(trim(h));
BEGIN
    IF normalized IS NULL OR normalized !~ '^[a-z0-9._]{3,20}$' THEN
        RETURN false;
    END IF;

    IF normalized IN (
        'onepercent', 'one_percent', '1percent',
        'official', 'admin', 'arete', 'support', 'moderator', 'system'
    ) THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.users
        WHERE handle = normalized
          AND id IS DISTINCT FROM auth.uid()
    ) THEN
        RETURN false;
    END IF;

    RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.is_handle_available(text) FROM PUBLIC;
-- Also granted to anon (on purpose):
-- Onboarding goes nameInput (@handle input) → appleSignIn, so
-- the availability check runs before sign-in = as anon. Blocking anon would stop
-- every new user from getting through onboarding. All this RPC leaks is
-- "whether that handle already exists", and profiles are public information anyway.
GRANT EXECUTE ON FUNCTION public.is_handle_available(text) TO anon;
GRANT EXECUTE ON FUNCTION public.is_handle_available(text) TO authenticated;

-- ============================================
-- 4. search_users RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.search_users(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        u.id,
        u.display_name,
        u.handle,
        u.avatar_url,
        COALESCE(u.is_pro, false) AS is_pro
    FROM public.users u
    WHERE query IS NOT NULL
      AND trim(query) <> ''
      AND (
        u.handle LIKE lower(query) || '%'
        OR u.display_name ILIKE '%' || query || '%'
      )
      AND u.id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY
        CASE WHEN u.handle LIKE lower(query) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;

-- ============================================
-- 5. Add 'new_post' to user_notifications.kind
-- ============================================
-- Replace the unnamed CHECK constraint defined in 014, which has the Postgres default name
-- (user_notifications_kind_check)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN ('like', 'follow', 'comment', 'reply', 'comment_like', 'new_post')
    );

-- ============================================
-- 6. notify_followers_on_post trigger (new post → notify all followers)
-- ============================================
-- The poster is excluded (because of the user_follows_no_self constraint, follower=poster never
-- exists anyway). Followers who have blocked the poster are excluded.
-- create_notification internally handles rejecting self-originated actions + duplicate prevention
-- (ON CONFLICT).
CREATE OR REPLACE FUNCTION public.notify_followers_on_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    follower RECORD;
BEGIN
    FOR follower IN
        SELECT uf.follower_id
        FROM public.user_follows uf
        WHERE uf.followed_user_id = NEW.user_id
          AND NOT EXISTS (
            SELECT 1 FROM public.user_blocks ub
            WHERE ub.blocker_id = uf.follower_id
              AND ub.blocked_user_id = NEW.user_id
          )
    LOOP
        PERFORM public.create_notification(
            p_recipient_user_id => follower.follower_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'new_post',
            p_target_post_id    => NEW.id
        );
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_notify_followers ON public.user_posts;
CREATE TRIGGER user_posts_notify_followers
    AFTER INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_followers_on_post();

-- ============================================
-- 7. Queries for checking behavior (no need to run, comments only)
-- ============================================
-- Handle availability check:
--   SELECT is_handle_available('taro123');
-- User search:
--   SELECT * FROM search_users('taro', 30);
-- Backfill check (no NULLs should remain):
--   SELECT count(*) FROM users WHERE handle IS NULL;
