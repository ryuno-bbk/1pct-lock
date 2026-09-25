-- ============================================================
-- Phase B-5: block_sessions テーブル（累計ロック時間）
-- ============================================================
-- 目的:
--   3 モード（timer / schedule / location）のロックセッションを
--   サーバー側に記録 → MyProfile で累計時間表示
--
-- 設計判断:
--   - 累計は status 関係なく duration_seconds を SUM（途中停止も含む）
--   - status は「active / completed / aborted」を将来分析用に保持
--
-- 記録タイミング（実装時の作業）:
--   - timer:    TimerManager.timerCompleted / stopTimerBlocking で insert
--   - schedule: DeviceActivityMonitorExtension.intervalDidStart/End で insert
--   - location: LocationManager.didEnterRegion/didExitRegion で insert
--
-- 実行順序:
--   Phase A 完了後（users 参照のため）。B フェーズ内では任意順
-- ============================================================

-- ============================================
-- 1. block_sessions テーブル
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

    -- active なら ended_at / duration_seconds NULL
    -- 完了/中断なら両方 NOT NULL
    CONSTRAINT block_sessions_ended_consistency CHECK (
        (status = 'active'  AND ended_at IS NULL AND duration_seconds IS NULL)
        OR
        (status <> 'active' AND ended_at IS NOT NULL AND duration_seconds IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_block_sessions_user_created
    ON public.block_sessions(user_id, created_at DESC);

-- 累計集計用（MyProfile で SUM(duration_seconds) を高速化）
CREATE INDEX IF NOT EXISTS idx_block_sessions_user_duration
    ON public.block_sessions(user_id) WHERE duration_seconds IS NOT NULL;

COMMENT ON TABLE public.block_sessions IS '3 モードのロックセッション履歴。累計時間集計用';
COMMENT ON COLUMN public.block_sessions.duration_seconds IS 'status 関係なく合算するので途中停止 (aborted) もカウントする';

-- ============================================
-- 2. RLS
-- ============================================
ALTER TABLE public.block_sessions ENABLE ROW LEVEL SECURITY;

-- SELECT: 自分のセッションのみ
CREATE POLICY "block_sessions_select_own"
    ON public.block_sessions FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT: 自分の user_id で
CREATE POLICY "block_sessions_insert_own"
    ON public.block_sessions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- UPDATE: 自分の active セッションを完了/中断時に変更可
CREATE POLICY "block_sessions_update_own"
    ON public.block_sessions FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- DELETE: 自分のセッションのみ（アカウント削除時 ON DELETE CASCADE）
CREATE POLICY "block_sessions_delete_own"
    ON public.block_sessions FOR DELETE
    USING (auth.uid() = user_id);
