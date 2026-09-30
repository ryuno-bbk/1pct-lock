-- ============================================================
-- 081_weekly_report_notification.sql
-- Weekly report delivery (user_notifications → existing Webhook → send-push → APNs)
-- ============================================================
-- Design decisions (2026-09-05):
--
--   1. 🔴 Do not build a new delivery path. Ride on the
--      "INSERT into user_notifications → Webhook → send-push" path made in 079 as is.
--      cron only "inserts one row" and knows nothing about push.
--
--   2. 🔴 Only send to "people who have locked at least once in the past".
--      Send even if that week is 0 seconds (user decision 2026-09-05).
--      But people who have never locked are excluded, because every item is zero and the report
--      screen does not work.
--
--   3. Put "the number of seconds that week" in preview_text.
--      The body text is built on the send-push side (it switches Japanese/English by users.lang, so
--      the wording is not fixed on the SQL side).
--
--   4. Idempotent. At most one notification per person per week. It does not grow even if cron runs
--      twice.
--
--   5. 🔴 pg_cron is not installed in this production project (confirmed 2026-09-05).
--      Enabling it is dashboard work = a task for the user.
--      Even without the extension, calling this function manually sends it (see usage at the
--      bottom).
--
-- Execution order: after 080. Safe to run any number of times
-- To revert:
--   select cron.unschedule('weekly-report');           -- if using pg_cron
--   drop function if exists public.dispatch_weekly_reports(date, text);
-- ============================================================

-- ============================================
-- 1. Add weekly_report to the allowed list of kind
-- ============================================
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN (
            'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post',
            'content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
            'appeal_unsure',
            'weekly_report'
        )
    );

-- Also add it to the allowed list for self-reference (recipient = actor).
-- The weekly report is not "sent by the operator" but a system notification addressed to the user,
-- so use the same self-reference approach as the moderation notifications in 039
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_no_self;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_no_self CHECK (
        recipient_user_id <> actor_user_id
        OR kind IN (
            'content_rejected', 'content_flagged',
            'appeal_approved', 'appeal_rejected', 'appeal_unsure',
            'weekly_report'
        )
    );

-- ============================================
-- 2. Partial index to avoid sending twice in the same week
-- ============================================
CREATE INDEX IF NOT EXISTS idx_user_notifications_weekly_report
    ON public.user_notifications (recipient_user_id, created_at DESC)
    WHERE kind = 'weekly_report';

-- ============================================
-- 3. Dispatcher
-- ============================================
-- If p_week_start is omitted, target "the most recent completed week (last week)".
-- Return value = number of rows actually inserted.
CREATE OR REPLACE FUNCTION public.dispatch_weekly_reports(
    p_week_start date DEFAULT NULL,
    p_tz         text DEFAULT 'Asia/Tokyo'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_week_start date;
    v_from       timestamptz;
    v_to         timestamptz;
    v_inserted   integer := 0;
BEGIN
    v_week_start := COALESCE(p_week_start, public.weekly_report_week_start(1, p_tz));
    v_from := (v_week_start::timestamp)       AT TIME ZONE p_tz;
    v_to   := ((v_week_start + 7)::timestamp) AT TIME ZONE p_tz;

    -- 🔴 Do not send a week in progress. Only completed weeks are targeted
    IF v_week_start >= public.weekly_report_week_start(0, p_tz) THEN
        RAISE NOTICE 'dispatch_weekly_reports: 進行中の週は送らない (%)', v_week_start;
        RETURN 0;
    END IF;

    WITH target AS (
        SELECT u.id AS user_id,
               COALESCE((
                   SELECT SUM(s.duration_seconds)
                     FROM public.block_sessions s
                    WHERE s.user_id = u.id
                      AND s.duration_seconds IS NOT NULL
                      AND s.started_at >= v_from
                      AND s.started_at <  v_to
               ), 0)::bigint AS secs
          FROM public.users u
         WHERE
           -- Only people who have locked at least once in the past (send even if that week is 0 seconds)
           EXISTS (
               SELECT 1 FROM public.block_sessions s2
                WHERE s2.user_id = u.id
                  AND s2.duration_seconds IS NOT NULL
                  AND s2.started_at < v_to
           )
           -- Sending to people with no device token is pointless, but we want to keep it in the in-app bell,
           -- so they are not excluded (they can read it the next time they open the app)
           --
           -- Idempotent: skip people who already received this week's notification
           AND NOT EXISTS (
               SELECT 1 FROM public.user_notifications n
                WHERE n.recipient_user_id = u.id
                  AND n.kind = 'weekly_report'
                  AND n.created_at >= v_to
           )
    )
    INSERT INTO public.user_notifications
        (recipient_user_id, actor_user_id, kind, preview_text)
    SELECT t.user_id, t.user_id, 'weekly_report', t.secs::text
      FROM target t;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
END;
$$;

-- 🔴 Make it absolutely impossible to call from the client (a call would send a notification to everyone)
REVOKE EXECUTE ON FUNCTION public.dispatch_weekly_reports(date, text)
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.dispatch_weekly_reports(date, text) IS
    '週次レポート通知を配る (先週分)。冪等。cron かサービスロールからのみ呼ぶ';

-- ============================================
-- 4. Scheduled run (pg_cron)
-- ============================================
-- 🔴 pg_cron is not installed in this project (confirmed 2026-09-05).
--    Enable pg_cron in Dashboard → Database → Extensions, then
--    uncomment the lines below and run them = a task for the user.
--
--    Monday 09:00 JST = Sunday 00:00 UTC
--
-- select cron.schedule(
--     'weekly-report',
--     '0 0 * * 0',
--     $$ select public.dispatch_weekly_reports(); $$
-- );
--
-- To stop: select cron.unschedule('weekly-report');

-- ============================================
-- 5. Sending manually (for checking before installing pg_cron)
-- ============================================
-- ⚠️ Running this sends real pushes to real users. Always check the count first:
--
--   -- only count how many people it would go to (does not send)
--   select count(*) from public.users u
--    where exists (select 1 from public.block_sessions s
--                   where s.user_id = u.id and s.duration_seconds is not null);
--
--   -- actually send
--   select public.dispatch_weekly_reports();
