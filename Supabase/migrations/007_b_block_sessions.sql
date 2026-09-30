-- ============================================================
-- Phase B-5: block_sessions table (total lock time)
-- ============================================================
-- Purpose:
--   Record lock sessions of the 3 modes (timer / schedule / location)
--   on the server → show the total time on MyProfile
--
-- Design decisions:
--   - The total is SUM(duration_seconds) regardless of status (includes sessions stopped midway)
--   - status keeps "active / completed / aborted" for future analysis
--
-- When to record (work for the implementation):
--   - timer:    insert in TimerManager.timerCompleted / stopTimerBlocking
--   - schedule: insert in DeviceActivityMonitorExtension.intervalDidStart/End
--   - location: insert in LocationManager.didEnterRegion/didExitRegion
--
-- Execution order:
--   After Phase A is done (because it references users). Any order within phase B
-- ============================================================

-- ============================================
-- 1. block_sessions table
-- ============================================
CREATE TABLE IF NOT EXISTS public.block_sessions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    mode             text NOT NULL CHECK (mode IN ('timer', 'schedule', 'location')),
    started_at       timestamptz NOT NULL,
    ended_at         timestamptz,
    duration_seconds integer,
    status           text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'completed', 'aborted')),
    created_at       timestamptz NOT NULL DEFAULT now(),

    -- If active, ended_at / duration_seconds are NULL
    -- If completed/aborted, both are NOT NULL
    CONSTRAINT block_sessions_ended_consistency CHECK (
        (status = 'active'  AND ended_at IS NULL AND duration_seconds IS NULL)
        OR
        (status <> 'active' AND ended_at IS NOT NULL AND duration_seconds IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_block_sessions_user_created
    ON public.block_sessions(user_id, created_at DESC);

-- For the total (speeds up SUM(duration_seconds) on MyProfile)
CREATE INDEX IF NOT EXISTS idx_block_sessions_user_duration
    ON public.block_sessions(user_id) WHERE duration_seconds IS NOT NULL;

COMMENT ON TABLE public.block_sessions IS '3 モードのロックセッション履歴。累計時間集計用';
COMMENT ON COLUMN public.block_sessions.duration_seconds IS 'status 関係なく合算するので途中停止 (aborted) もカウントする';

-- ============================================
-- 2. RLS
-- ============================================
ALTER TABLE public.block_sessions ENABLE ROW LEVEL SECURITY;

-- SELECT: only your own sessions
CREATE POLICY "block_sessions_select_own"
    ON public.block_sessions FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT: with your own user_id
CREATE POLICY "block_sessions_insert_own"
    ON public.block_sessions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- UPDATE: you can change your own active session when it completes/aborts
CREATE POLICY "block_sessions_update_own"
    ON public.block_sessions FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- DELETE: only your own sessions (ON DELETE CASCADE on account deletion)
CREATE POLICY "block_sessions_delete_own"
    ON public.block_sessions FOR DELETE
    USING (auth.uid() = user_id);
