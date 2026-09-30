-- ============================================================
-- 015_security_audit.sql
-- Implementation order 2: fixes for problems found in the security audit (2026-07-04)
-- ============================================================
-- Findings and fixes:
--   1. [Critical] The duplicate-prevention constraint of user_reports is UNIQUE NULLS NOT DISTINCT,
--      so NULLs collide with each other, and one user can in effect report only 2 times in a lifetime
--      (even a 2nd post report is rejected because of target_quote_id NULL vs NULL)
--      → replaced with a partial unique index, the same approach as user_likes in 002
--   2. [High] The users_update_own policy allows UPDATE of the whole row, so
--      an authenticated user can set their own is_pro to true directly (self-granting the Pro badge)
--      → make is_pro read-only with a protect trigger that uses the rolbypassrls check
--   3. [High] block_sessions is entirely self-reported by the client, and any
--      duration_seconds can be inserted (tampering with the data source of the top percentile feature)
--      → a validity trigger rejects obvious outliers (the root fix is to be considered when the top
--        percentile feature is implemented)
--   4. [Medium] REVOKE FROM anon does not remove the function's implicit PUBLIC grant, so
--      the intended "cannot be called by anon" is not guaranteed → unified to REVOKE FROM PUBLIC
--   5. [Low] protect_user_posts_like_count does not protect comment_count
--      (an author can update comment_count of their own post to any value)
--      → protected the same way as like_count
--   6. [Low] The direct INSERT/DELETE policies of user_comment_likes can create inconsistency with
--      like_count (the app only uses the toggle_comment_like RPC, no direct access)
--      → close the policies and make it RPC only
--
-- Execution order: after 014. Safe to run any number of times (DROP IF EXISTS pattern)
-- ============================================================

-- ============================================
-- 1. Fix the duplicate-prevention constraint of user_reports
-- ============================================
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_unique_per_post;

ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_unique_per_quote;

-- The same person cannot report the same target twice (NULL rows are excluded = partial index)
CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_post_unique
    ON public.user_reports(reporter_id, target_post_id)
    WHERE target_post_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_quote_unique
    ON public.user_reports(reporter_id, target_quote_id)
    WHERE target_quote_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_user_unique
    ON public.user_reports(reporter_id, target_user_id)
    WHERE target_user_id IS NOT NULL;

-- ============================================
-- 2. Trigger to prevent self-granting users.is_pro
-- ============================================
-- The users_update_own policy is for editing display_name / avatar_url, but
-- it cannot restrict by column, so is_pro is protected with a trigger.
-- After purchases are implemented (StoreKit verification), only service_role / SECURITY DEFINER RPCs
-- can change it
CREATE OR REPLACE FUNCTION public.protect_users_is_pro()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.is_pro IS DISTINCT FROM OLD.is_pro THEN
        RAISE EXCEPTION 'is_pro is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_protect_is_pro ON public.users;
CREATE TRIGGER users_protect_is_pro
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_users_is_pro();

-- ============================================
-- 3. block_sessions validity trigger
-- ============================================
-- Keep client self-reporting itself, but reject obvious outliers:
--   - started_at / ended_at in the future (5 minutes allowed for clock skew)
--   - ended_at before started_at
--   - duration_seconds that contradicts started_at/ended_at (2 seconds allowed for rounding)
--   - a single session over 7 days (the longest expected is a continuous stay in location mode)
-- Note: tampering that fakes started_at/ended_at as well cannot be prevented.
--     When implementing the top percentile feature, consider server-side timestamps via an RPC
CREATE OR REPLACE FUNCTION public.validate_block_session()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;

    IF NEW.started_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'block_sessions: started_at is in the future';
    END IF;

    IF NEW.ended_at IS NOT NULL THEN
        IF NEW.ended_at > now() + interval '5 minutes' THEN
            RAISE EXCEPTION 'block_sessions: ended_at is in the future';
        END IF;
        IF NEW.ended_at < NEW.started_at THEN
            RAISE EXCEPTION 'block_sessions: ended_at before started_at';
        END IF;
        IF NEW.duration_seconds IS NULL
           OR abs(NEW.duration_seconds - EXTRACT(EPOCH FROM (NEW.ended_at - NEW.started_at))) > 2
        THEN
            RAISE EXCEPTION 'block_sessions: duration_seconds does not match timestamps';
        END IF;
        IF NEW.duration_seconds > 604800 THEN
            RAISE EXCEPTION 'block_sessions: session longer than 7 days rejected';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS block_sessions_validate ON public.block_sessions;
CREATE TRIGGER block_sessions_validate
    BEFORE INSERT OR UPDATE ON public.block_sessions
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_block_session();

-- ============================================
-- 4. Revoke RPC execute permission from PUBLIC as well
-- ============================================
-- CREATE FUNCTION implicitly grants EXECUTE to PUBLIC.
-- The existing REVOKE FROM anon has no effect when there is no direct grant to anon,
-- and anon can still execute via PUBLIC. Revoke it from PUBLIC entirely and
-- grant it again explicitly only to authenticated
REVOKE EXECUTE ON FUNCTION public.toggle_quote_like(uuid)                    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.toggle_post_like(uuid)                     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.toggle_comment_like(uuid)                  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_my_account()                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_total_block_seconds(uuid)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid)          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_notifications(integer)               FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_unread_notification_count()          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.mark_all_notifications_read()              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_notification(uuid, uuid, text, uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.toggle_quote_like(uuid)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_post_like(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_comment_like(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_following_feed(integer)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account()                    TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_total_block_seconds(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_notifications(integer)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_unread_notification_count()      TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read()          TO authenticated;
-- create_notification is called only from inside SECURITY DEFINER RPCs / triggers (no grant)

-- ============================================
-- 5. Extend protect_user_posts_like_count to also protect comment_count
-- ============================================
-- comment_count is a denormalized column that only the sync_post_comment_count trigger (SECURITY
-- DEFINER) can change. The user_posts_update_own policy allows the whole row, so
-- make it read-only on the trigger side
CREATE OR REPLACE FUNCTION public.protect_user_posts_like_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only for users (use toggle_post_like)';
    END IF;
    IF NEW.comment_count <> OLD.comment_count THEN
        RAISE EXCEPTION 'comment_count is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================
-- 6. Make user_comment_likes RPC only
-- ============================================
-- The app only uses the toggle_comment_like RPC (no direct INSERT/DELETE exists on the Swift side).
-- Allowing direct operations could create inconsistency between like_count and the real records, so
-- they are closed.
-- SELECT own is kept for a future is_liked check
DROP POLICY IF EXISTS "user_comment_likes_insert_own" ON public.user_comment_likes;
DROP POLICY IF EXISTS "user_comment_likes_delete_own" ON public.user_comment_likes;

-- ============================================
-- 7. Queries for checking behavior (no need to run, comments only)
-- ============================================
-- Check that reporting works more than once (report 2 different posts → both must succeed):
--   INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (auth.uid(), '<post1>', 'spam');
--   INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (auth.uid(), '<post2>', 'spam');
-- Check that self-granting is_pro is rejected (run as authenticated → must be an error):
--   UPDATE users SET is_pro = true WHERE id = auth.uid();
-- Check that an abnormal block_session is rejected (run as authenticated → must be an error):
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status)
--   VALUES (auth.uid(), 'timer', now() - interval '1 hour', now(), 999999, 'completed');
