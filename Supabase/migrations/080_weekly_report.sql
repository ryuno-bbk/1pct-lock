-- ============================================================
-- 080_weekly_report.sql
-- Aggregation RPC for the weekly report (equivalent to Opal's Focus Report)
-- ============================================================
-- Design decisions (2026-08-30):
--
--   1. 🔴 No table stores the reports. They are recalculated from block_sessions every time.
--      Reasons:
--        - "Looking back at past reports" is just calling the same function with a different week
--          start date
--        - If stored, fixing the aggregation definition would leave only the past reports with old
--          numbers
--        - At the current row count of block_sessions, even a full scan is negligible
--      If it gets heavy at scale, idx_block_sessions_week (below) helps.
--      Only if that is still not enough, consider a materialized view.
--
--   2. 🔴 The top percentile is the rank for "that week only", not "all time".
--      get_block_percentile in 016 is an all-time rank, so putting it in the weekly report would
--      show almost the same number every week without moving (it would not work as a report).
--      The population is everyone who locked for even 1 second that week.
--      ⚠️ With a small population, "top 50%" appears and looks bad (016's design memo already
--         warns about this).
--         → For weeks below MIN_RANK_POOL, top_percent / rank are returned as null and hidden in the UI.
--         The threshold of 20 means that while the user base is small, only some weeks show it.
--         As the population grows, it will naturally always show.
--
--   3. 🔴 A session that crosses weeks is counted entirely in "the week it started".
--      Same convention as get_streak_days in 016 (no split aggregation).
--      Schedule locks really do have sessions over 100 hours (measured max 7999 minutes), so
--      crossing weeks happens routinely. Even if the display shows "133 hours this week", it is not
--      broken.
--
--   4. ❌ A per-app breakdown cannot be built. The Screen Time API does not pass measured values to
--      the app itself (by design, it stays inside UsageReportExtension).
--      Instead, it returns "per mode (timer/schedule/location)" and "per weekday".
--      Both can be built from block_sessions alone, and they work as report content.
--
--   5. Users can only read their own report.
--      The RPCs in 016/033 take target_user_id and return other people's stats too (by design, the
--      stats are public), but the weekly report is granular enough to reveal "which weeks someone
--      was active", so it is not opened up.
--      → The public RPC is fixed to auth.uid(). The aggregation itself is split into an internal
--        function so that the cron dispatcher (081) can also call it without a second implementation.
--
-- Run order: after 079. Safe to run any number of times (CREATE OR REPLACE / IF NOT EXISTS)
-- Apply: supabase db push (or ./apply_sql.sh)
-- To revert:
--   drop function if exists public.get_weekly_report_list(integer, text);
--   drop function if exists public.get_weekly_report(integer, text);
--   drop function if exists public.weekly_report_json(uuid, date, text);
--   drop function if exists public.weekly_report_week_start(integer, text);
--   drop index if exists public.idx_block_sessions_week;
-- ============================================================

-- ============================================
-- 1. Index for weekly aggregation
-- ============================================
-- It reads all users for the week (rank calculation), so a user_id-first index does not help.
-- Partial index with started_at first, only for rows that have duration_seconds.
CREATE INDEX IF NOT EXISTS idx_block_sessions_week
    ON public.block_sessions (started_at)
    WHERE duration_seconds IS NOT NULL;

-- ============================================
-- 2. Helper that finds the start date of the week (Monday)
-- ============================================
-- p_week_offset: how many weeks ago. 0 = the current week in progress, 1 = last week (= the most
-- recent completed week).
-- 🔴 What is shown as a report is always 1 or more. 0 is partial progress, so it is not normally used.
CREATE OR REPLACE FUNCTION public.weekly_report_week_start(
    p_week_offset integer DEFAULT 1,
    p_tz          text    DEFAULT 'Asia/Tokyo'
)
RETURNS date
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
    v_tz    text := p_tz;
    v_today date;
BEGIN
    -- Same as 016, an invalid time zone name falls back to UTC
    BEGIN
        PERFORM now() AT TIME ZONE v_tz;
    EXCEPTION WHEN OTHERS THEN
        v_tz := 'UTC';
    END;

    v_today := (now() AT TIME ZONE v_tz)::date;

    -- date_trunc('week', ...) is the ISO week = starts on Monday
    RETURN date_trunc('week', v_today::timestamp)::date
           - (GREATEST(p_week_offset, 0) * 7);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.weekly_report_week_start(integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.weekly_report_week_start(integer, text) TO authenticated;

-- ============================================
-- 3. The aggregation itself (internal)
-- ============================================
-- 🔴 This is not public. Both the cron dispatcher in 081 (runs with postgres privileges) and
--    the public RPC call this. Split out to avoid a second implementation.
CREATE OR REPLACE FUNCTION public.weekly_report_json(
    p_user_id    uuid,
    p_week_start date,
    p_tz         text DEFAULT 'Asia/Tokyo'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- Minimum population to show the top percentile. For weeks below this, rank / top_percent are not
    -- returned
    MIN_RANK_POOL constant integer := 20;

    v_tz           text := p_tz;
    v_from         timestamptz;
    v_to           timestamptz;
    v_prev_from    timestamptz;

    v_seconds      bigint  := 0;
    v_sessions     integer := 0;
    v_prev_seconds bigint  := 0;

    v_active_users integer := 0;
    v_higher       integer := 0;
    v_rank         integer;
    v_top_percent  numeric;

    v_total        bigint  := 0;
    v_ever         boolean := false;
    v_first_week   date;

    v_avg4         bigint  := 0;
    v_by_mode      jsonb;
    v_days         jsonb;
    v_delta        numeric;
BEGIN
    BEGIN
        PERFORM now() AT TIME ZONE v_tz;
    EXCEPTION WHEN OTHERS THEN
        v_tz := 'UTC';
    END;

    -- Convert local Monday 00:00 to the next Monday 00:00 into timestamptz
    v_from      := (p_week_start::timestamp)           AT TIME ZONE v_tz;
    v_to        := ((p_week_start + 7)::timestamp)     AT TIME ZONE v_tz;
    v_prev_from := ((p_week_start - 7)::timestamp)     AT TIME ZONE v_tz;

    -- ---- This week ----
    SELECT COALESCE(SUM(duration_seconds), 0), count(*)
      INTO v_seconds, v_sessions
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at >= v_from
       AND started_at <  v_to;

    -- ---- Last week ----
    SELECT COALESCE(SUM(duration_seconds), 0)
      INTO v_prev_seconds
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at >= v_prev_from
       AND started_at <  v_from;

    -- ---- Whether the user has ever locked + the week of the first session ----
    -- 🔴 For users where this is false, every item in the report is zero and the screen does not work.
    --    They are also excluded from the send targets in 081 ("0 minutes this week" is only sent to
    --    people who have a track record).
    SELECT (count(*) > 0),
           date_trunc('week', (MIN(started_at) AT TIME ZONE v_tz))::date
      INTO v_ever, v_first_week
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at < v_to;

    -- ---- Running total as of the end of that week ----
    -- users.total_block_seconds is the "current" total, so it cannot be used for past week reports
    SELECT COALESCE(SUM(duration_seconds), 0)
      INTO v_total
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at < v_to;

    -- ---- Rank for that week (population = people who locked for even 1 second that week) ----
    -- People with 0 seconds are in neither the population nor the ranking
    IF v_seconds > 0 THEN
        WITH wk AS (
            SELECT user_id, SUM(duration_seconds)::bigint AS secs
              FROM public.block_sessions
             WHERE duration_seconds IS NOT NULL
               AND started_at >= v_from
               AND started_at <  v_to
             GROUP BY user_id
            HAVING SUM(duration_seconds) > 0
        )
        SELECT count(*)::int,
               count(*) FILTER (WHERE secs > v_seconds)::int
          INTO v_active_users, v_higher
          FROM wk;

        IF v_active_users >= MIN_RANK_POOL THEN
            v_rank        := v_higher + 1;
            v_top_percent := ROUND((v_higher + 1)::numeric / v_active_users * 100, 1);
        END IF;
    ELSE
        SELECT count(DISTINCT user_id)::int
          INTO v_active_users
          FROM public.block_sessions
         WHERE duration_seconds IS NOT NULL
           AND started_at >= v_from
           AND started_at <  v_to;
    END IF;

    -- ---- Average of the last 4 weeks (including this week) → input for the yearly projection ----
    -- 🔴 Weeks before the first session are not included in the denominator.
    --    If they were, the average of "someone who started last week" would be diluted by 3 weeks of zeros
    --    that did not exist, and the yearly projection would be 1/4 of the real pace (confirmed with
    --    real data on 2026-08-30).
    SELECT COALESCE(ROUND(AVG(wsum))::bigint, 0)
      INTO v_avg4
      FROM (
          SELECT COALESCE((
                     SELECT SUM(s.duration_seconds)
                       FROM public.block_sessions s
                      WHERE s.user_id = p_user_id
                        AND s.duration_seconds IS NOT NULL
                        AND s.started_at >= ((p_week_start - g.n * 7)::timestamp) AT TIME ZONE v_tz
                        AND s.started_at <  ((p_week_start - g.n * 7 + 7)::timestamp) AT TIME ZONE v_tz
                 ), 0) AS wsum
            FROM generate_series(0, 3) AS g(n)
           WHERE v_first_week IS NOT NULL
             AND (p_week_start - g.n * 7) >= v_first_week
      ) q;

    -- ---- Breakdown per mode (in place of a per-app breakdown, which cannot be built) ----
    SELECT COALESCE(jsonb_object_agg(mode, secs), '{}'::jsonb)
      INTO v_by_mode
      FROM (
          SELECT mode, SUM(duration_seconds)::bigint AS secs
            FROM public.block_sessions
           WHERE user_id = p_user_id
             AND duration_seconds IS NOT NULL
             AND started_at >= v_from
             AND started_at <  v_to
           GROUP BY mode
      ) m;

    -- ---- Per weekday (Mon=0 to Sun=6). Always returns 7 elements for the UI bar chart ----
    SELECT COALESCE(jsonb_agg(secs ORDER BY idx), '[]'::jsonb)
      INTO v_days
      FROM (
          SELECT d.idx,
                 COALESCE((
                     SELECT SUM(s.duration_seconds)
                       FROM public.block_sessions s
                      WHERE s.user_id = p_user_id
                        AND s.duration_seconds IS NOT NULL
                        AND s.started_at >= ((p_week_start + d.idx)::timestamp)     AT TIME ZONE v_tz
                        AND s.started_at <  ((p_week_start + d.idx + 1)::timestamp) AT TIME ZONE v_tz
                 ), 0)::bigint AS secs
            FROM generate_series(0, 6) AS d(idx)
      ) dd;

    -- ---- Change vs last week ----
    -- For a week where last week was 0, "X% increase" cannot be defined (division by 0). Return null and
    -- do not show it in the UI
    IF v_prev_seconds > 0 THEN
        v_delta := ROUND((v_seconds - v_prev_seconds)::numeric / v_prev_seconds * 100, 1);
    END IF;

    RETURN jsonb_build_object(
        'has_history',      v_ever,
        'week_start',       p_week_start,
        'week_end',         p_week_start + 6,
        'is_current_week',  (p_week_start = public.weekly_report_week_start(0, v_tz)),
        'first_week_start', v_first_week,
        'seconds',          v_seconds,
        'sessions',         v_sessions,
        'prev_seconds',     v_prev_seconds,
        'delta_percent',    v_delta,
        'rank',             v_rank,
        'top_percent',      v_top_percent,
        'active_users',     v_active_users,
        'total_seconds',    v_total,
        'avg4_seconds',     v_avg4,
        -- Yearly projection. A simple multiplication: what if the average pace of the last 4 weeks continued
        -- for a year
        'projection_year_seconds', v_avg4 * 52,
        'by_mode',          v_by_mode,
        'days',             v_days
    );
END;
$$;

-- 🔴 internal. EXECUTE is granted to no one (called only from the public RPC and cron)
REVOKE EXECUTE ON FUNCTION public.weekly_report_json(uuid, date, text)
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.weekly_report_json(uuid, date, text) IS
    '週次レポートの集計本体 (internal)。公開 RPC get_weekly_report と 081 の cron ディスパッチャが呼ぶ。直接 GRANT しないこと';

-- ============================================
-- 4. Public RPC: your own weekly report
-- ============================================
CREATE OR REPLACE FUNCTION public.get_weekly_report(
    p_week_offset integer DEFAULT 1,
    p_tz          text    DEFAULT 'Asia/Tokyo'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;

    -- Future weeks are not returned (offset < 0 is rounded to 0)
    RETURN public.weekly_report_json(
        v_uid,
        public.weekly_report_week_start(p_week_offset, p_tz),
        p_tz
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_weekly_report(integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_weekly_report(integer, text) TO authenticated;

COMMENT ON FUNCTION public.get_weekly_report(integer, text) IS
    '自分の週次レポート。p_week_offset: 0=進行中の今週 / 1=先週(既定)。他人のは読めない';

-- ============================================
-- 5. Public RPC: list of past reports (Settings → Weekly report)
-- ============================================
-- The list has many rows, so it does not call the aggregation itself (it runs a dozen or so queries per
-- week).
-- All that is needed is "how much the user locked that week", so a single aggregation is enough.
-- 🔴 Weeks before the first session are not returned (listing empty reports is pointless).
CREATE OR REPLACE FUNCTION public.get_weekly_report_list(
    p_limit integer DEFAULT 12,
    p_tz    text    DEFAULT 'Asia/Tokyo'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid        uuid := auth.uid();
    v_tz         text := p_tz;
    v_limit      integer := LEAST(GREATEST(COALESCE(p_limit, 12), 1), 52);
    v_this_week  date;
    v_first_week date;
    v_result     jsonb;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;

    BEGIN
        PERFORM now() AT TIME ZONE v_tz;
    EXCEPTION WHEN OTHERS THEN
        v_tz := 'UTC';
    END;

    v_this_week := public.weekly_report_week_start(0, v_tz);

    SELECT date_trunc('week', (MIN(started_at) AT TIME ZONE v_tz))::date
      INTO v_first_week
      FROM public.block_sessions
     WHERE user_id = v_uid
       AND duration_seconds IS NOT NULL;

    IF v_first_week IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT COALESCE(jsonb_agg(row_json ORDER BY week_start DESC), '[]'::jsonb)
      INTO v_result
      FROM (
          SELECT ws.week_start,
                 jsonb_build_object(
                     'week_offset', (v_this_week - ws.week_start) / 7,
                     'week_start',  ws.week_start,
                     'week_end',    ws.week_start + 6,
                     'seconds',     COALESCE(agg.secs, 0),
                     'sessions',    COALESCE(agg.n, 0)
                 ) AS row_json
            FROM (
                SELECT (v_this_week - (g.n * 7))::date AS week_start
                  FROM generate_series(1, v_limit) AS g(n)
            ) ws
            LEFT JOIN LATERAL (
                SELECT SUM(s.duration_seconds)::bigint AS secs, count(*)::int AS n
                  FROM public.block_sessions s
                 WHERE s.user_id = v_uid
                   AND s.duration_seconds IS NOT NULL
                   AND s.started_at >= (ws.week_start::timestamp)       AT TIME ZONE v_tz
                   AND s.started_at <  ((ws.week_start + 7)::timestamp) AT TIME ZONE v_tz
            ) agg ON true
           WHERE ws.week_start >= v_first_week
      ) q;

    RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_weekly_report_list(integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_weekly_report_list(integer, text) TO authenticated;

COMMENT ON FUNCTION public.get_weekly_report_list(integer, text) IS
    '自分の過去レポート一覧 (完了週のみ・新しい順)。初回セッションの週より前は返さない';

-- ============================================
-- 6. Queries for checking behavior (no need to run, comments only)
-- ============================================
-- -- Last week's report (reading real users is allowed. Writing is forbidden)
-- select public.weekly_report_json(
--          (select id from public.users order by total_block_seconds desc limit 1),
--          public.weekly_report_week_start(1, 'Asia/Tokyo'),
--          'Asia/Tokyo');
--
-- -- Active users per week (check whether the top percentile population reaches the threshold)
-- select date_trunc('week', started_at at time zone 'Asia/Tokyo')::date as wk,
--        count(distinct user_id)
--   from public.block_sessions
--  where duration_seconds is not null
--  group by 1 order by 1 desc;
