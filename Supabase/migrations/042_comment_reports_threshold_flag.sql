-- ============================================================
-- 042_comment_reports_threshold_flag.sql
-- Comment reports (H9) + automatic hiding by report threshold (L21): B bucket UI pass
-- ============================================================
-- Background:
--   H9: there was no way at all to report a comment (Guideline 1.2 ② was not met for the comment
--       path). user_reports only has 3 types, post / user / quote, and cannot target a comment.
--   L21: reports only pile up; there is no automatic hiding by threshold.
--
-- Design decisions:
--   - Add a target_comment_id column and extend 006's "at least one target required" CHECK
--     to 4 targets (DROP → recreate. Every existing row has one of the 3 targets non-NULL, so
--     all rows are valid under the new CHECK too).
--   - Duplicate report prevention follows the partial unique index approach established in 015
--     (user_reports_reporter_{post,quote,user}_unique). It is an index and not a UNIQUE
--     constraint because of the lesson from 015 (UNIQUE NULLS NOT DISTINCT limited the NULL
--     combinations to 1 row, so each user got stuck at 2 reports for life).
--   - The Swift side (ReportService.reportComment) detects duplicates by SQLSTATE 23505
--     (M14), so the index name could be anything, but it is named to pair with the existing 3.
--   - L21 threshold: on user_reports INSERT, if the number of report rows for the target
--     (post / comment) is 3 or more, set moderation_status to 'flagged'.
--       * The partial unique index guarantees "row count = number of distinct reporters"
--       * Overwrites only from approved / pending (only toward 'flagged' = the safe side).
--         rejected (layer 1 safety NG) stays as is, and if already flagged it is a no-op
--       * quote / user reports are out of scope (official quotes have no moderation_status,
--         and automatic sanctions on the user account itself carry a high risk of false hits,
--         so they stay manual by the operator)
--   - The trigger function is SECURITY DEFINER (run in SQL Editor = owned by postgres).
--     027's protect_user_{posts,comments}_moderation checks the rolbypassrls of current_user,
--     so it passes straight through when run as postgres (same mechanism as 039
--     resolve_user_appeal). 037's H13 protect (making the body immutable) does not touch the
--     moderation columns, so it does not interfere.
--   - The transition to flagged naturally fires 039's user_{posts,comments}_notify_moderation
--     trigger, and a content_flagged notification goes to the author (preview_text comes from
--     moderation_verdict->>'ethos_reason'. For threshold flags there is often no verdict, so it
--     is NULL, but the notification body alone makes sense, so this is accepted).
--   - handleUserReport in the moderate-post Edge Function only reads reason / detail /
--     ai_severity, so no change is needed for comment reports (AI triage does not depend on the
--     target type). No deploy on the deno side.
--
-- Execution order: assumes an environment with 006 / 015 / 017 (user_comments) / 027 / 037 / 039
--   applied. Safe to run any number of times (IF NOT EXISTS / DROP IF EXISTS → recreate pattern).
--   Applied by the user (Supabase Dashboard → SQL Editor).
-- ============================================================

-- ============================================================
-- 1. target_comment_id column + FK
-- ============================================================
ALTER TABLE public.user_reports
    ADD COLUMN IF NOT EXISTS target_comment_id uuid
        REFERENCES public.user_comments(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.user_reports.target_comment_id IS
    'コメント通報の対象 (042)。post/user/quote/comment のいずれか1つ以上が必須';

-- Create a partial index on the target column so that the FK CASCADE delete (deleting comments is
-- a daily operation) does not turn into a full table scan
CREATE INDEX IF NOT EXISTS idx_user_reports_target_comment
    ON public.user_reports(target_comment_id)
    WHERE target_comment_id IS NOT NULL;

-- ============================================================
-- 2. Extend the "at least one target required" CHECK to 4 targets
-- ============================================================
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_target_required;

ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_target_required CHECK (
        target_post_id IS NOT NULL
        OR target_user_id IS NOT NULL
        OR target_quote_id IS NOT NULL
        OR target_comment_id IS NOT NULL
    );

-- ============================================================
-- 3. Prevent duplicate reports on the same comment (015's partial unique index approach)
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_comment_unique
    ON public.user_reports(reporter_id, target_comment_id)
    WHERE target_comment_id IS NOT NULL;

-- ============================================================
-- 4. L21: automatically set flagged at the report threshold (distinct reporters >= 3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    report_threshold constant integer := 3;
    v_count integer;
BEGIN
    IF NEW.target_post_id IS NOT NULL THEN
        -- Thanks to the partial unique index, row count = number of distinct reporters
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_post_id = NEW.target_post_id;

        IF v_count >= report_threshold THEN
            -- Overwrite only toward flagged (approved/pending → flagged).
            -- rejected stays as is out of respect for the AI layer 1 verdict; flagged is a no-op
            UPDATE public.user_posts
            SET moderation_status = 'flagged', moderated_at = now()
            WHERE id = NEW.target_post_id
              AND moderation_status IN ('approved', 'pending');
        END IF;

    ELSIF NEW.target_comment_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_comment_id = NEW.target_comment_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_comments
            SET moderation_status = 'flagged', moderated_at = now()
            WHERE id = NEW.target_comment_id
              AND moderation_status IN ('approved', 'pending');
        END IF;
    END IF;
    -- No automatic handling for quote / user reports (manual by the operator)

    RETURN NEW;
END;
$$;

-- AFTER INSERT: judged by the count that includes the inserted row.
-- Even with concurrent INSERT races, the UPDATE is idempotent (conditional flagging), so it is fine
DROP TRIGGER IF EXISTS user_reports_flag_threshold ON public.user_reports;
CREATE TRIGGER user_reports_flag_threshold
    AFTER INSERT ON public.user_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.flag_content_on_report_threshold();

-- ============================================================
-- 5. Queries for checking behavior (no need to run, comments only)
-- ============================================================
-- Comment report (from the app's report UI, or):
--   INSERT INTO user_reports (reporter_id, target_comment_id, reason)
--   VALUES (auth.uid(), '<comment_id>', 'spam');
-- After 3 accounts report the same comment:
--   SELECT moderation_status FROM user_comments WHERE id = '<comment_id>';  -- → flagged
-- The author should have received a content_flagged notification:
--   SELECT * FROM fetch_notifications(20) WHERE kind = 'content_flagged';
