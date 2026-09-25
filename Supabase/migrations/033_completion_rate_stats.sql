-- ============================================================
-- 033_completion_rate_stats.sql
-- 統計パック: 完遂率 (completion rate) + プロフィール統計の 1 RPC 集約
-- ============================================================
-- 確定した定義 (2026-07-16 ユーザー承認済み・変更禁止):
--   完遂率 = 直近30日の「タイマーモード」セッションのうち completed の割合 (件数ベース、%表示)
--     - 対象モードはタイマーのみ (schedule/location は分母に入れない。
--       それらは aborted が記録されない構造のため)
--     - 集計窓 = 直近30日 (started_at 基準)
--     - ガーミング対策: 予定時間 (planned) 10分未満のセッションは分子分母から除外
--     - 公開範囲: 他人のプロフィールにも公開 (MyProfileView + UserProfileView 両方)
--
-- planned_seconds が必要な理由:
--   「10分未満除外」を実測 duration でフィルタすると、60分タイマーを2分で中断した
--   セッション (duration=2分) が除外されてしまい、数えたい失敗ほど消える。
--   除外判定は予定時間で行うため、block_sessions に予定秒数のカラムを追加する。
--   - 新カラム planned_seconds (nullable)。タイマーのみ値を入れる
--   - 過去データは NULL。適格判定は:
--       COALESCE(planned_seconds, CASE WHEN status='completed' THEN duration_seconds END) >= 600
--     - 過去の completed はタイマー満了なので実測≒予定 → duration で代用可
--     - 過去の aborted は予定不明 → 除外 (30日窓で自然に解消、未リリースなので実害なし)
--
-- 既存 016 の RPC (get_block_percentile / get_streak_days / get_total_block_seconds) は変更しない。
-- get_user_stats はプロフィール1画面 = 1 RPC に集約するための統合関数で、
-- 上記3つ + 完遂率をまとめて jsonb で返す。
--
-- 実行順序: 032 の後。何度実行しても安全 (IF NOT EXISTS / CREATE OR REPLACE)
-- ============================================================

-- ============================================
-- 1. block_sessions.planned_seconds カラム
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
-- 2. 完遂率集計用の部分インデックス
-- ============================================
CREATE INDEX IF NOT EXISTS idx_block_sessions_timer_completion
    ON public.block_sessions (user_id, started_at DESC)
    WHERE mode = 'timer';

-- ============================================
-- 3. get_user_stats RPC (プロフィール統計の統合エンドポイント)
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

    -- 既存 RPC をそのまま呼び出す (二重実装しない)
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
-- 4. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- SELECT get_user_stats(auth.uid());
-- SELECT get_user_stats(auth.uid(), 'Asia/Tokyo');
-- 他人の統計 (公開範囲の確認):
--   SELECT get_user_stats('<他人の user_id>'::uuid);
