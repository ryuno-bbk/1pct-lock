-- ============================================================
-- 034_completion_all_time.sql
-- For the stats cell detail sheet: add the "all-time completion rate" to get_user_stats
-- ============================================================
-- History (2026-07-17 user request):
--   Added a UI where tapping a stats cell shows a detail sheet. The completion rate cell's detail
--   shows the all-time completion rate in addition to the headline last-30-days one (30 days = you
--   now, all time = contrast with your whole record. The headline stays at 30 days).
--
-- The definition is the same as 033 (timer only / planned 10 minutes or more / count-based). Only
-- the window is removed.
-- Note: past aborted sessions have a NULL planned_seconds, so they are excluded (same rule as 033).
--   So the abort history from before 033 was applied is not in the all-time value, which comes
--   out somewhat generous. New data after release always has planned_seconds, so it is accurate.
--
-- Execution order: after 033 (requires the planned_seconds column). Safe to run any number of times
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_user_stats(
    target_user_id uuid,
    tz text DEFAULT 'Asia/Tokyo'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    total_seconds        bigint;
    streak               integer;
    percentile_json      jsonb;
    completed_30d        integer;
    eligible_30d         integer;
    completed_all        integer;
    eligible_all         integer;
    completion_json      jsonb;
    completion_all_json  jsonb;
BEGIN
    SELECT total_block_seconds INTO total_seconds
    FROM public.users WHERE id = target_user_id;

    -- Call the existing RPC as-is (no duplicate implementation)
    streak          := public.get_streak_days(target_user_id, tz);
    percentile_json := public.get_block_percentile(target_user_id);

    -- Aggregate eligible sessions (033's definition) for both the 30-day window and all time in 1 scan
    SELECT
        count(*) FILTER (WHERE status = 'completed'
                           AND started_at >= now() - interval '30 days'),
        count(*) FILTER (WHERE started_at >= now() - interval '30 days'),
        count(*) FILTER (WHERE status = 'completed'),
        count(*)
    INTO completed_30d, eligible_30d, completed_all, eligible_all
    FROM public.block_sessions
    WHERE user_id = target_user_id
      AND mode = 'timer'
      AND status IN ('completed', 'aborted')
      AND COALESCE(planned_seconds,
            CASE WHEN status = 'completed' THEN duration_seconds END) >= 600;

    IF eligible_30d > 0 THEN
        completion_json := jsonb_build_object(
            'has_data',        true,
            'rate_percent',    ROUND(completed_30d * 100.0 / eligible_30d)::int,
            'completed_count', completed_30d,
            'eligible_count',  eligible_30d
        );
    ELSE
        completion_json := jsonb_build_object('has_data', false);
    END IF;

    IF eligible_all > 0 THEN
        completion_all_json := jsonb_build_object(
            'has_data',        true,
            'rate_percent',    ROUND(completed_all * 100.0 / eligible_all)::int,
            'completed_count', completed_all,
            'eligible_count',  eligible_all
        );
    ELSE
        completion_all_json := jsonb_build_object('has_data', false);
    END IF;

    RETURN jsonb_build_object(
        'total_block_seconds', COALESCE(total_seconds, 0),
        'streak_days',         streak,
        'percentile',          percentile_json,
        'completion',          completion_json,
        'completion_all_time', completion_all_json
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_user_stats(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_user_stats(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.get_user_stats(uuid, text) IS
    'プロフィール統計の統合RPC (累計/連続/上位%/完遂率30日+全期間)。他人の user_id で呼べるのは仕様 (公開統計)';

-- Behavior check (no need to run, comments only):
--   SELECT get_user_stats(auth.uid());
