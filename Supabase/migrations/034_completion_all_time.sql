-- ============================================================
-- 034_completion_all_time.sql
-- 統計セルの詳細シート用: get_user_stats に「全期間の完遂率」を追加
-- ============================================================
-- 経緯 (2026-07-17 ユーザー要望):
--   統計セルをタップすると詳細説明シートが出る UI を追加。完遂率セルの詳細には
--   ヘッドラインの直近30日に加えて全期間の完遂率も表示する (30日=今の自分、
--   全期間=通算の対比。ヘッドラインは30日のまま変えない)。
--
-- 定義は 033 と同一 (タイマーのみ / 予定10分以上 / 件数ベース)。窓だけ無し。
-- 注意: 過去の aborted は planned_seconds が NULL のため除外される (033 と同じ規則)。
--   つまり 033 適用前の中断履歴は全期間値に含まれず、やや甘めに出る。
--   リリース後の新規データは planned_seconds が常に入るので正確。
--
-- 実行順序: 033 の後 (planned_seconds カラムが前提)。何度実行しても安全
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

    -- 既存 RPC をそのまま呼び出す (二重実装しない)
    streak          := public.get_streak_days(target_user_id, tz);
    percentile_json := public.get_block_percentile(target_user_id);

    -- 適格セッション (033 の定義) を1回のスキャンで 30日窓 / 全期間の両方に集計
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

-- 動作確認 (実行不要、コメント):
--   SELECT get_user_stats(auth.uid());
