-- ============================================================
-- 016_b_percentile_streak.sql
-- 順序3: 「上位◯%」表示 + ストリーク (連続ロック日数) の DB 基盤
-- ============================================================
-- 設計判断 (2026-07-04 Fable5):
--   1. 改ざん根本対策 (RPC でのサーバー側タイムスタンプ化) は【不採用】
--      理由: S8 確定の「active セッションを DB に持たない・App Group キューに
--      溜めて次回起動時に一括 flush」というオフラインファースト設計と非互換。
--      schedule モードは Extension がオフラインで記録するためサーバー打刻不可能。
--      v1 は 015 の妥当性 trigger (未来時刻拒否 / duration 整合 / 7日上限) で
--      露骨な不正だけ弾き、スケール後に再検討する
--   2. users.total_block_seconds を trigger で非正規化
--      パーセンタイル計算が block_sessions 全走査ではなく users 1 テーブルの
--      インデックススキャンで済む。get_total_block_seconds もこれを読む形に置換
--   3. 上位% の定義: 母数 = ロック実績のあるユーザー (total > 0)、
--      上位X% = (自分より合計が多い人数 + 1) / 母数 × 100。
--      ロック実績ゼロのユーザーは has_data=false を返しアプリ側で非表示
--   4. ストリーク = 「その日に 1 秒でもロックした日」の連続数。
--      タイムゾーンは引数 (デフォルト Asia/Tokyo、クライアントは
--      TimeZone.current.identifier を渡す)。今日まだロックしていなくても
--      昨日までの連続が生きていれば継続扱い (一般的なストリーク UX)
--
-- 実行順序: 015 完了後。何度実行しても安全
-- ============================================

-- ============================================
-- 1. users.total_block_seconds 非正規化列
-- ============================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS total_block_seconds bigint NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_total_block_seconds
    ON public.users (total_block_seconds DESC)
    WHERE total_block_seconds > 0;

COMMENT ON COLUMN public.users.total_block_seconds
    IS '累計ロック秒数 (block_sessions から trigger で同期。直接更新禁止)';

-- ============================================
-- 2. block_sessions → users.total_block_seconds 同期 trigger
-- ============================================
CREATE OR REPLACE FUNCTION public.sync_user_total_block_seconds()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.users
            SET total_block_seconds = total_block_seconds + COALESCE(NEW.duration_seconds, 0)
            WHERE id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.users
            SET total_block_seconds = GREATEST(
                total_block_seconds
                - COALESCE(OLD.duration_seconds, 0)
                + COALESCE(NEW.duration_seconds, 0), 0)
            WHERE id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.users
            SET total_block_seconds = GREATEST(total_block_seconds - COALESCE(OLD.duration_seconds, 0), 0)
            WHERE id = OLD.user_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS block_sessions_sync_total ON public.block_sessions;
CREATE TRIGGER block_sessions_sync_total
    AFTER INSERT OR UPDATE OR DELETE ON public.block_sessions
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_total_block_seconds();

-- 既存データからバックフィル
UPDATE public.users u
    SET total_block_seconds = COALESCE((
        SELECT SUM(s.duration_seconds)
        FROM public.block_sessions s
        WHERE s.user_id = u.id AND s.duration_seconds IS NOT NULL
    ), 0);

-- ============================================
-- 3. users の読み取り専用列保護を total_block_seconds にも拡張
-- ============================================
-- 015 の protect_users_is_pro を上書き (trigger 配線はそのまま流用)。
-- is_pro に加えて total_block_seconds もユーザー直 UPDATE を拒否する
CREATE OR REPLACE FUNCTION public.protect_users_is_pro()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.is_pro IS DISTINCT FROM OLD.is_pro THEN
        RAISE EXCEPTION 'is_pro is read-only for users';
    END IF;
    IF NEW.total_block_seconds IS DISTINCT FROM OLD.total_block_seconds THEN
        RAISE EXCEPTION 'total_block_seconds is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================
-- 4. get_total_block_seconds を非正規化列読みに置換 (シグネチャ不変)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_total_block_seconds(target_user_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT LEAST(COALESCE(
        (SELECT total_block_seconds FROM public.users WHERE id = target_user_id),
        0), 2147483647)::integer;
$$;

REVOKE EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) TO authenticated;

-- ============================================
-- 5. get_block_percentile RPC (目玉機能「あなたは上位◯%」)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_block_percentile(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    my_total     bigint;
    higher_count integer;
    active_count integer;
BEGIN
    SELECT total_block_seconds INTO my_total
    FROM public.users WHERE id = target_user_id;

    IF my_total IS NULL OR my_total = 0 THEN
        RETURN jsonb_build_object('has_data', false);
    END IF;

    SELECT count(*) INTO active_count
    FROM public.users WHERE total_block_seconds > 0;

    SELECT count(*) INTO higher_count
    FROM public.users WHERE total_block_seconds > my_total;

    RETURN jsonb_build_object(
        'has_data',    true,
        'top_percent', ROUND((higher_count + 1)::numeric / active_count * 100, 1),
        'rank',        higher_count + 1,
        'total_users', active_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_block_percentile(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_block_percentile(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_block_percentile(uuid)
    IS '累計ロック時間の全ユーザー内順位。top_percent は「上位X%」表示にそのまま使う (アプリ側で max(1, round) 推奨)';

-- ============================================
-- 6. get_streak_days RPC (連続ロック日数)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_streak_days(
    target_user_id uuid,
    tz             text DEFAULT 'Asia/Tokyo'
)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    today    date;
    expected date;
    streak   integer := 0;
    d        record;
BEGIN
    -- 不正なタイムゾーン名は UTC にフォールバック
    BEGIN
        PERFORM now() AT TIME ZONE tz;
    EXCEPTION WHEN OTHERS THEN
        tz := 'UTC';
    END;

    today := (now() AT TIME ZONE tz)::date;
    expected := today;

    FOR d IN
        SELECT DISTINCT (started_at AT TIME ZONE tz)::date AS day
        FROM public.block_sessions
        WHERE user_id = target_user_id
          AND duration_seconds IS NOT NULL
        ORDER BY day DESC
        LIMIT 400
    LOOP
        IF d.day = expected THEN
            streak := streak + 1;
            expected := expected - 1;
        ELSIF streak = 0 AND d.day = today - 1 THEN
            -- 今日まだロックしていないが昨日までの連続が生きているケース
            streak := 1;
            expected := d.day - 1;
        ELSE
            EXIT;
        END IF;
    END LOOP;

    RETURN streak;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_streak_days(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_streak_days(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.get_streak_days(uuid, text)
    IS '連続ロック日数。今日未ロックでも昨日までの連続は継続扱い。tz はクライアントの TimeZone.current.identifier';

-- ============================================
-- 7. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- SELECT get_block_percentile(auth.uid());
-- SELECT get_streak_days(auth.uid(), 'Asia/Tokyo');
-- SELECT get_total_block_seconds(auth.uid());
-- 直接更新が拒否されることの確認 (authenticated で実行 → エラー):
--   UPDATE users SET total_block_seconds = 99999999 WHERE id = auth.uid();
