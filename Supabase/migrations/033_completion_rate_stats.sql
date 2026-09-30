-- ============================================================
-- 033_completion_rate_stats.sql
-- Stats pack: completion rate + profile stats gathered into 1 RPC
-- ============================================================
-- Finalized definition (approved by the user 2026-07-16, do not change):
--   Completion rate = share of completed among "timer mode" sessions in the last 30 days (by count,
--   shown as %)
--     - Only timer mode (schedule/location are not in the denominator,
--       because by structure they never record aborted)
--     - Window = last 30 days (based on started_at)
--     - Anti-gaming: sessions with planned time under 10 minutes are excluded from both numerator
--       and denominator
--     - Visibility: public on other users' profiles too (both MyProfileView + UserProfileView)
--
-- Why planned_seconds is needed:
--   If "exclude under 10 minutes" filtered by actual duration, a session where a 60-minute timer
--   was stopped after 2 minutes (duration=2 min) would be excluded, so exactly the failures we want
--   to count would disappear. Exclusion is decided by the planned time, so a planned seconds column
--   is added to block_sessions.
--   - New column planned_seconds (nullable). Set only for timers
--   - Past data is NULL. Eligibility is:
--       COALESCE(planned_seconds, CASE WHEN status='completed' THEN duration_seconds END) >= 600
--     - Past completed rows ran the timer to the end, so actual ≈ planned → duration can be used
--       instead
--     - Past aborted rows have an unknown plan → excluded (resolves itself with the 30-day window,
--       and it is not released yet so there is no real harm)
--
-- The existing RPCs from 016 (get_block_percentile / get_streak_days / get_total_block_seconds) are
-- unchanged. get_user_stats is a combined function so the profile screen = 1 RPC, and it
-- returns the 3 above + completion rate together as jsonb.
--
-- Run order: after 032. Safe to run any number of times (IF NOT EXISTS / CREATE OR REPLACE)
-- ============================================================

-- ============================================
-- 1. block_sessions.planned_seconds column
-- ============================================
ALTER TABLE public.block_sessions
    ADD COLUMN IF NOT EXISTS planned_seconds integer;

ALTER TABLE public.block_sessions
    DROP CONSTRAINT IF EXISTS block_sessions_planned_seconds_range;

ALTER TABLE public.block_sessions
    ADD CONSTRAINT block_sessions_planned_seconds_range CHECK (
        planned_seconds IS NULL
        OR (planned_seconds > 0 AND planned_seconds <= 604800)
    );

COMMENT ON COLUMN public.block_sessions.planned_seconds IS
    '予定ロック秒数 (タイマーのみ)。完遂率の10分フィルタは実測 (duration_seconds) でなくこれで判定する';

-- ============================================
-- 2. Partial index for the completion rate aggregation
-- ============================================
CREATE INDEX IF NOT EXISTS idx_block_sessions_timer_completion
    ON public.block_sessions (user_id, started_at DESC)
    WHERE mode = 'timer';

-- ============================================
-- 3. get_user_stats RPC (combined endpoint for profile stats)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_user_stats(
    target_user_id uuid,
    tz text DEFAULT 'Asia/Tokyo'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    total_seconds    bigint;
    streak           integer;
    percentile_json  jsonb;
    completed_count  integer;
    eligible_count   integer;
    completion_json  jsonb;
BEGIN
    SELECT total_block_seconds INTO total_seconds
    FROM public.users WHERE id = target_user_id;

    -- Call the existing RPCs as is (no duplicate implementation)
    streak          := public.get_streak_days(target_user_id, tz);
    percentile_json := public.get_block_percentile(target_user_id);

    SELECT
        count(*) FILTER (WHERE status = 'completed'),
        count(*)
    INTO completed_count, eligible_count
    FROM public.block_sessions
    WHERE user_id = target_user_id
      AND mode = 'timer'
      AND status IN ('completed', 'aborted')
      AND started_at >= now() - interval '30 days'
      AND COALESCE(planned_seconds,
            CASE WHEN status = 'completed' THEN duration_seconds END) >= 600;

    IF eligible_count > 0 THEN
        completion_json := jsonb_build_object(
            'has_data',       true,
            'rate_percent',   ROUND(completed_count * 100.0 / eligible_count)::int,
            'completed_count', completed_count,
            'eligible_count',  eligible_count
        );
    ELSE
        completion_json := jsonb_build_object('has_data', false);
    END IF;

    RETURN jsonb_build_object(
        'total_block_seconds', COALESCE(total_seconds, 0),
        'streak_days',         streak,
        'percentile',          percentile_json,
        'completion',          completion_json
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_user_stats(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_user_stats(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.get_user_stats(uuid, text) IS
    'プロフィール統計の統合RPC (累計ロック秒 / 連続日数 / 上位% / 完遂率)。他人の user_id で呼べるのは仕様 (公開統計)';

-- ============================================
-- 4. Queries for checking behavior (no need to run, comments)
-- ============================================
-- SELECT get_user_stats(auth.uid());
-- SELECT get_user_stats(auth.uid(), 'Asia/Tokyo');
-- Another user's stats (check the visibility):
--   SELECT get_user_stats('<other_user_id>'::uuid);
