-- ============================================================
-- 080_weekly_report.sql
-- 週次レポート (Opal の Focus Report 相当) の集計 RPC
-- ============================================================
-- 設計判断 (2026-08-30):
--
--   1. 🔴 レポートを保存するテーブルは作らない。block_sessions から毎回再計算する。
--      理由:
--        - 「過去のレポートを見返す」は週の開始日を変えて同じ関数を呼ぶだけで済む
--        - 保存すると集計の定義を直したとき過去分だけ古い数字のまま残る
--        - 今の block_sessions の行数なら全走査しても無視できる
--      スケールして重くなったら idx_block_sessions_week (下記) が効く。
--      それでも足りなくなったら初めてマテビュー化を検討する。
--
--   2. 🔴 上位% は「累計」ではなく「その週だけ」の順位で出す。
--      016 の get_block_percentile は累計順位なので、週次レポートに載せると
--      毎週ほぼ同じ数字が出て動かない (レポートとして機能しない)。
--      母数はその週に1秒でもロックした人。
--      ⚠️ 母数が小さいと「上位50%」が出て格好悪い (016 の設計メモが既に警告済み)。
--         → MIN_RANK_POOL 未満の週は top_percent / rank を null で返し、UI 側で隠す。
--         閾値 20 は、規模が小さいうちは一部の週だけ出る線引きになる。
--         母数が増えれば自然に常時出る。
--
--   3. 🔴 週をまたぐセッションは「開始した週」に丸ごと計上する。
--      016 の get_streak_days と同じ慣習に揃える (分割集計はしない)。
--      スケジュールロックは 100 時間超のセッションが実在する (実測 max 7999分) ので、
--      またぎは日常的に起きる。表示側で「今週 133時間」が出ても壊れてはいない。
--
--   4. ❌ アプリ別の内訳は作れない。Screen Time API は実測値をアプリ本体に渡さない
--      (UsageReportExtension の中で完結する仕様)。
--      代わりに「モード別 (タイマー/スケジュール/位置)」と「曜日別」を返す。
--      どちらも block_sessions だけで作れて、レポートの中身として成立する。
--
--   5. 自分のレポートしか読めない。
--      016/033 の RPC は target_user_id を取って他人の統計も返す (公開統計という仕様)
--      が、週次レポートは「どの週に活動していたか」まで分かる粒度なので広げない。
--      → 公開 RPC は auth.uid() 固定。集計本体は internal 関数に分けて、
--        cron のディスパッチャ (081) からも二重実装なしで呼べるようにする。
--
-- 実行順序: 079 の後。何度実行しても安全 (CREATE OR REPLACE / IF NOT EXISTS)
-- 適用: supabase db push (または ./apply_sql.sh)
-- 戻すとき:
--   drop function if exists public.get_weekly_report_list(integer, text);
--   drop function if exists public.get_weekly_report(integer, text);
--   drop function if exists public.weekly_report_json(uuid, date, text);
--   drop function if exists public.weekly_report_week_start(integer, text);
--   drop index if exists public.idx_block_sessions_week;
-- ============================================================

-- ============================================
-- 1. 週次集計用インデックス
-- ============================================
-- 週の全ユーザー分を引く (順位計算) ので user_id 先頭では効かない。
-- started_at 先頭 + duration_seconds が入っている行だけの部分インデックス。
CREATE INDEX IF NOT EXISTS idx_block_sessions_week
    ON public.block_sessions (started_at)
    WHERE duration_seconds IS NOT NULL;

-- ============================================
-- 2. 週の開始日 (月曜) を求めるヘルパー
-- ============================================
-- p_week_offset: 何週前か。0 = 進行中の今週、1 = 先週 (= 直近の完了週)。
-- 🔴 レポートとして見せるのは常に 1 以上。0 は途中経過なので通常使わない。
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
    -- 016 と同じく、不正なタイムゾーン名は UTC にフォールバックする
    BEGIN
        PERFORM now() AT TIME ZONE v_tz;
    EXCEPTION WHEN OTHERS THEN
        v_tz := 'UTC';
    END;

    v_today := (now() AT TIME ZONE v_tz)::date;

    -- date_trunc('week', ...) は ISO 週 = 月曜始まり
    RETURN date_trunc('week', v_today::timestamp)::date
           - (GREATEST(p_week_offset, 0) * 7);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.weekly_report_week_start(integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.weekly_report_week_start(integer, text) TO authenticated;

-- ============================================
-- 3. 集計本体 (internal)
-- ============================================
-- 🔴 これは公開しない。081 の cron ディスパッチャ (postgres 権限で走る) と
--    公開 RPC の両方がここを呼ぶ。二重実装を避けるための分離。
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
    -- 上位% を出す最低母数。これ未満の週は rank / top_percent を返さない
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

    -- 現地時間の 月曜00:00 〜 翌月曜00:00 を timestamptz に変換する
    v_from      := (p_week_start::timestamp)           AT TIME ZONE v_tz;
    v_to        := ((p_week_start + 7)::timestamp)     AT TIME ZONE v_tz;
    v_prev_from := ((p_week_start - 7)::timestamp)     AT TIME ZONE v_tz;

    -- ---- 今週 ----
    SELECT COALESCE(SUM(duration_seconds), 0), count(*)
      INTO v_seconds, v_sessions
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at >= v_from
       AND started_at <  v_to;

    -- ---- 先週 ----
    SELECT COALESCE(SUM(duration_seconds), 0)
      INTO v_prev_seconds
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at >= v_prev_from
       AND started_at <  v_from;

    -- ---- 過去に一度でもロックしたか + 初回の週 ----
    -- 🔴 これが false のユーザーはレポートの全項目がゼロで画面が成立しない。
    --    081 の送信対象からも外す (「今週は0分」を送るのは実績がある人だけ)。
    SELECT (count(*) > 0),
           date_trunc('week', (MIN(started_at) AT TIME ZONE v_tz))::date
      INTO v_ever, v_first_week
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at < v_to;

    -- ---- その週末時点の累計 ----
    -- users.total_block_seconds は「現在」の累計なので過去週のレポートには使えない
    SELECT COALESCE(SUM(duration_seconds), 0)
      INTO v_total
      FROM public.block_sessions
     WHERE user_id = p_user_id
       AND duration_seconds IS NOT NULL
       AND started_at < v_to;

    -- ---- その週の順位 (母数 = その週に1秒でもロックした人) ----
    -- 0秒の人は母数にもランキングにも入らない
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

    -- ---- 直近4週 (この週を含む) の平均 → 年間予測の材料 ----
    -- 🔴 初回セッションより前の週は分母に入れない。
    --    入れると「先週から使い始めた人」の平均が存在しない3週分のゼロで薄まり、
    --    年間予測が実ペースの 1/4 になる (2026-08-30 の実データで確認)。
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

    -- ---- モード別内訳 (アプリ別が作れない代わり) ----
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

    -- ---- 曜日別 (月=0 〜 日=6)。UI の棒グラフ用に必ず7要素返す ----
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

    -- ---- 先週比 ----
    -- 先週が0の週は「何%増」が定義できない (0除算)。null を返して UI 側で出さない
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
        -- 年間予測。直近4週の平均ペースが1年続いたら、という単純な掛け算
        'projection_year_seconds', v_avg4 * 52,
        'by_mode',          v_by_mode,
        'days',             v_days
    );
END;
$$;

-- 🔴 internal。誰にも EXECUTE を渡さない (公開 RPC と cron からだけ呼ぶ)
REVOKE EXECUTE ON FUNCTION public.weekly_report_json(uuid, date, text)
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.weekly_report_json(uuid, date, text) IS
    '週次レポートの集計本体 (internal)。公開 RPC get_weekly_report と 081 の cron ディスパッチャが呼ぶ。直接 GRANT しないこと';

-- ============================================
-- 4. 公開 RPC: 自分の週次レポート
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

    -- 未来の週は返さない (offset < 0 は 0 に丸められる)
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
-- 5. 公開 RPC: 過去レポートの一覧 (設定 → 週次レポート)
-- ============================================
-- 一覧は行数が出るので集計本体は呼ばない (1週あたり十数クエリ走るため)。
-- 必要なのは「その週にどれだけロックしたか」だけなので単一の集計で済ませる。
-- 🔴 初回セッションより前の週は返さない (空のレポートを並べても意味がない)。
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
-- 6. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- -- 先週のレポート (実ユーザーの読み取りは可。書き込みは禁止)
-- select public.weekly_report_json(
--          (select id from public.users order by total_block_seconds desc limit 1),
--          public.weekly_report_week_start(1, 'Asia/Tokyo'),
--          'Asia/Tokyo');
--
-- -- 週別のアクティブ人数 (上位% の母数が閾値に届くか確認する)
-- select date_trunc('week', started_at at time zone 'Asia/Tokyo')::date as wk,
--        count(distinct user_id)
--   from public.block_sessions
--  where duration_seconds is not null
--  group by 1 order by 1 desc;
