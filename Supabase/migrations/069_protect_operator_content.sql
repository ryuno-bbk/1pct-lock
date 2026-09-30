-- ============================================================================
-- 069_protect_operator_content.sql
-- Exclude the operator account's posts from automatic hiding by reports (2026-08-01)
-- ============================================================================
-- ⚠️ Run this after applying 067_moderation_hardening.sql (depends on the report_flagged column).
--
-- [What is the problem] (pointed out by the user during real device testing on 2026-08-01)
-- 067 introduced automatic hiding at 5 reports (report_flagged), but
-- flag_content_on_report_threshold targets user_posts / user_comments unconditionally and
-- does not look at who the poster is.
--
-- Official quotes (the 1% account in authors, 020) are quotes, so they were never subject to
-- automatic handling (per the design of 042, target_quote_id / target_user_id are not handled
-- automatically).
-- But **when the operator posts an announcement in user_posts from their own personal account**,
-- it is ordinary UGC, so 5 reports make it disappear.
-- Example: if 5 people who object to a "we are introducing ads" announcement report it, the
-- announcement itself disappears.
-- A state where the operator's channel can be taken down by a majority vote of regular users is
-- unhealthy, so this closes it.
--
-- [Policy]
-- Posts/comments by moderation_config.operator_user_id (already added in 054) are
-- excluded from automatic flagging. The reports themselves are still recorded and stay in the
-- operator queue (review room), so "the operator is fully invincible" does not happen (there is
-- still room for a human to look and decide).
--
-- If operator_user_id is NULL, the exclusion condition has no effect at all = the same behavior as
-- before (fail-soft).
-- ⚠️ One user task after applying:
--     UPDATE public.moderation_config SET operator_user_id = '<your user_id>';
--   If left unset, this file effectively does nothing.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- 067: 3 → 5 (user decision)
    report_threshold constant integer := 5;
    v_count    integer;
    v_operator uuid;
BEGIN
    -- 069: posts by the operator account (moderation_config.operator_user_id) are not hidden
    -- automatically. If NULL, the IS DISTINCT FROM below is always true, so everyone is covered as
    -- before.
    SELECT operator_user_id INTO v_operator FROM public.moderation_config LIMIT 1;

    IF NEW.target_post_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_post_id = NEW.target_post_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_posts
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_post_id
              AND moderation_status <> 'rejected'
              -- 069: exclude the operator's posts
              AND (v_operator IS NULL OR user_id IS DISTINCT FROM v_operator);
        END IF;

    ELSIF NEW.target_comment_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_comment_id = NEW.target_comment_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_comments
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_comment_id
              AND moderation_status <> 'rejected'
              -- 069: exclude the operator's comments
              AND (v_operator IS NULL OR author_user_id IS DISTINCT FROM v_operator);
        END IF;
    END IF;
    -- No automatic handling for quote / user reports (unchanged from 042, manual by the operator)

    RETURN NEW;
END;
$$;

-- The trigger itself (AFTER INSERT ON user_reports) is unchanged from 042.
-- The function RETURNS trigger, so it cannot be called directly = no REVOKE/GRANT needed (same as
-- 066/067).

COMMIT;

-- ============================================================================
-- What the user does after applying
-- ============================================================================
-- 1. Look up your own user_id (replace the handle with your own)
--    SELECT id, handle, display_name FROM public.users WHERE handle = '<your handle>';
--
-- 2. Register it as the operator account
--    UPDATE public.moderation_config SET operator_user_id = '<the id from above>';
--
-- 3. Check (returns 1 row, and operator_user_id is your id)
--    SELECT operator_user_id FROM public.moderation_config;
