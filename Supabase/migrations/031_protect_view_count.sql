-- ============================================================
-- 031_protect_view_count.sql
-- [Severity: medium] Prevent authors from tampering with user_posts.view_count on their own posts
-- ============================================================
-- How it was found:
--   028_bereal_ui.sql added user_posts.view_count as a plain int column.
--   The user_posts_update_own policy (005_b_user_posts.sql:100-103)
--   allows the author to UPDATE the whole row. like_count / comment_count are
--   made read-only by the protect_user_posts_like_count trigger in 015_security_audit.sql,
--   and moderation_status / moderation_verdict by the
--   protect_user_posts_moderation trigger in 027_ai_moderation.sql,
--   but view_count has no such guard at all.
--   → If the author, through PostgREST, calls
--       PATCH /user_posts?id=eq.<own_post> { "view_count": 999999 }
--     it succeeds. view_count is shown to all users, and it is also
--     an input to the fetch_mixed_feed_random scoring in 029_recommend_feed.sql,
--     so inflating view counts directly inflates feed exposure.
--
-- Fix policy (reuses exactly the same mechanism as 015's protect_user_posts_like_count):
--   - CREATE OR REPLACE the protect_user_posts_like_count trigger function and
--     add a guard condition for view_count in addition to like_count / comment_count.
--     The existing DROP TRIGGER IF EXISTS + CREATE TRIGGER pair (created in 005/015,
--     function name protect_user_posts_like_count / trigger name
--     user_posts_protect_like_count) is reused as is. No new trigger is created.
--   - The check logic is the same rolbypassrls pattern as 015/027:
--       SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolbypassrls
--     Roles that satisfy this (service_role, postgres as the owner of SECURITY DEFINER functions)
--     pass through; only direct UPDATEs by other regular authenticated roles are rejected.
--
-- Confirming that record_post_view (028) keeps working (code trace):
--   - toggle_post_like (005/015) is a SECURITY DEFINER function whose owner is
--     postgres. The postgres role has rolbypassrls = true, so the
--     `UPDATE user_posts SET like_count = ...` executed inside the function goes into the protect
--     trigger's "RETURN NEW if rolbypassrls" branch and passes the guard.
--     The key point is that current_user is not "the role of the session that called the function"
--     but "the execution role of the SECURITY DEFINER function = its owner"
--     (this is why, as the 015 comment says, the check uses rolbypassrls and not
--     current_setting('role')).
--   - record_post_view (028_bereal_ui.sql:56-94) is likewise
--     `LANGUAGE plpgsql SECURITY DEFINER` and owned by postgres.
--     The `UPDATE public.user_posts SET view_count = view_count + 1
--     WHERE id = target_post_id;` inside it (028 lines 90-92) goes through exactly the same path as
--     the like_count update in toggle_post_like (SECURITY DEFINER → postgres →
--     rolbypassrls=true → trigger passes), so even after this migration is applied,
--     the view_count increment by record_post_view succeeds unchanged.
--   - On the other hand, when the author calls directly through PostgREST
--     `UPDATE user_posts SET view_count = ... WHERE id = own_post`,
--     current_user stays the authenticated role (rolbypassrls=false), so
--     it hits the trigger's guard and is rejected.
--
-- Run order: after 015, 027 and 028 are applied. Safe to run any number of times (CREATE OR REPLACE only,
-- no new objects created)
-- ============================================================

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
    IF NEW.view_count <> OLD.view_count THEN
        RAISE EXCEPTION 'view_count is read-only for users (use record_post_view)';
    END IF;
    RETURN NEW;
END;
$$;

-- The existing trigger (created in 005/015) stays as is. Only the function body is replaced.
-- Just in case, check that it exists and recreate it if missing (insurance for the case where only
-- this migration is run without 015 applied. Normally it already exists, so no NOTICE is emitted either)
DROP TRIGGER IF EXISTS user_posts_protect_columns   ON public.user_posts; -- old trigger name (S1 draft)
DROP TRIGGER IF EXISTS user_posts_protect_like_count ON public.user_posts;
CREATE TRIGGER user_posts_protect_like_count
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_like_count();

-- ============================================
-- Queries for checking behavior (no need to run; same paste format as the comments / verify_026_028.sql)
-- ============================================
-- (a) Confirm that trying to overwrite the view_count of your own post directly is rejected
--     (run as authenticated → it should error: "view_count is read-only for users")
--   UPDATE user_posts SET view_count = 999999
--     WHERE id = '<id of a post you own>' AND user_id = auth.uid();
--
-- (b) Confirm that record_post_view can still increment view_count
--     (run as authenticated, on a post owned by someone else)
--   SELECT view_count FROM user_posts WHERE id = '<id of another user's post>'; -- check the value before running
--   SELECT record_post_view('<id of another user's post>');
--   SELECT view_count FROM user_posts WHERE id = '<id of another user's post>'; -- it should be +1
--
-- (c) Check that it is applied (verify_026_028.sql style, paste into the SQL Editor and check ok=true)
--   SELECT * FROM (
--       SELECT '031' AS mig, 'trigger user_posts_protect_like_count guards view_count' AS object,
--              EXISTS(
--                  SELECT 1 FROM pg_proc
--                  WHERE proname = 'protect_user_posts_like_count'
--                    AND prosrc LIKE '%view_count%'
--              ) AS ok
--   ) t;
