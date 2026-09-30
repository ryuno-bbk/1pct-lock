-- ============================================================
-- 046_rate_limits.sql
-- Rate limits for posts/comments (2026-07-25, moderation cost defense)
-- ============================================================
-- Background: moderation costs ¥1.5-3 per post (depends on the number of images) and ~¥0.1 per
-- comment. Without a limit, one account running wild/trolling makes the cost unlimited.
-- The limit is purely against trolls/bots and set to a value real users never feel
-- (user decision 2026-07-25: "I basically don't want a post limit. If there is one, about 100").
--
-- Spec:
--   - Posts: up to 100 in the last 24 hours (rolling 24h, not a fixed date switch. Avoids time zone
--     issues)
--   - Comments: up to 300 in the last 24 hours (including replies. Loose because they are text only
--     and cost little)
--   - To change a limit, just rewrite the constant in this file and rerun CREATE OR REPLACE
--   - No role exemption: comments are INSERTed through the create_comment RPC (SECURITY DEFINER,
--     owned by postgres), so adding a rolbypassrls exemption would let the limit be bypassed
--     completely. The check is purely the row count for NEW.user_id. When the operator seeds in
--     bulk from SQL Editor, the procedure is to temporarily remove it with ALTER TABLE ... DISABLE
--     TRIGGER
--   - The client detects hitting the limit by whether the RAISE EXCEPTION message contains
--     ('daily post limit reached' / 'daily comment limit reached')
--     (same message matching pattern as AppealService's 'already appealed'. When changing it,
--     UserPostService.swift / CommentService.swift must also be updated)
-- ============================================================

-- 1. Posts: 100 / 24h
CREATE OR REPLACE FUNCTION public.enforce_post_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    SELECT count(*) INTO recent_count
    FROM public.user_posts
    WHERE user_id = NEW.user_id
      AND created_at > now() - interval '24 hours';
    IF recent_count >= 100 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- 2. Comments: 300 / 24h
CREATE OR REPLACE FUNCTION public.enforce_comment_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- The author column of user_comments is author_user_id (014 SQL. Not user_id: fixed 2026-07-25)
    SELECT count(*) INTO recent_count
    FROM public.user_comments
    WHERE author_user_id = NEW.author_user_id
      AND created_at > now() - interval '24 hours';
    IF recent_count >= 300 THEN
        RAISE EXCEPTION 'daily comment limit reached';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_rate_limit ON public.user_comments;
CREATE TRIGGER user_comments_rate_limit
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_comment_rate_limit();
