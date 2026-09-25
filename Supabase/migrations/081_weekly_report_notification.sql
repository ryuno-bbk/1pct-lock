-- ============================================================
-- 081_weekly_report_notification.sql
-- 週次レポートの配信 (user_notifications → 既存 Webhook → send-push → APNs)
-- ============================================================
-- 設計判断 (2026-09-05):
--
--   1. 🔴 新しい配信経路は作らない。079 で作った
--      「user_notifications へ INSERT → Webhook → send-push」にそのまま乗せる。
--      cron は「行を1つ入れる」だけで、プッシュのことを何も知らない。
--
--   2. 🔴 送信対象は「過去に1度でもロックしたことがある人」だけ。
--      その週が 0 秒でも送る (ユーザー判断 2026-09-05)。
--      ただし一度もロックしたことがない人は全項目ゼロでレポート画面が成立しないため除外する。
--
--   3. preview_text に「その週の秒数」を入れる。
--      本文の組み立ては send-push 側でやる (users.lang で日英を出し分けるため、
--      文面を SQL 側で確定させない)。
--
--   4. 冪等。同じ週の通知は1人1通まで。cron が二重に走っても増えない。
--
--   5. 🔴 pg_cron はこの本番プロジェクトに入っていない (2026-09-05 確認済み)。
--      有効化はダッシュボード作業 = ユーザー作業。
--      拡張が無い間も、この関数を手動で呼べば送れる (下部の使い方を参照)。
--
-- 実行順序: 080 の後。何度実行しても安全
-- 戻すとき:
--   select cron.unschedule('weekly-report');           -- pg_cron を使っている場合
--   drop function if exists public.dispatch_weekly_reports(date, text);
-- ============================================================

-- ============================================
-- 1. kind の許可リストに weekly_report を追加
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

-- 自己参照 (recipient = actor) の許可リストにも追加。
-- 週次レポートは「運営が送る」のではなく本人宛のシステム通知なので、
-- 039 のモデレーション通知と同じ自己参照方式にする
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
-- 2. 同じ週に二重で送らないための部分インデックス
-- ============================================
CREATE INDEX IF NOT EXISTS idx_user_notifications_weekly_report
    ON public.user_notifications (recipient_user_id, created_at DESC)
    WHERE kind = 'weekly_report';

-- ============================================
-- 3. ディスパッチャ
-- ============================================
-- p_week_start を省略すると「直近の完了週 (先週)」を対象にする。
-- 返り値 = 実際に入れた行数。
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

    -- 🔴 進行中の週を送らない。完了した週だけが対象
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
           -- 過去に1度でもロックしたことがある人だけ (その週が0秒でも送る)
           EXISTS (
               SELECT 1 FROM public.block_sessions s2
                WHERE s2.user_id = u.id
                  AND s2.duration_seconds IS NOT NULL
                  AND s2.started_at < v_to
           )
           -- 端末トークンが1つも無い人には送っても意味がないが、アプリ内ベルには
           -- 残したいので除外しない (次に開いた時に読める)
           --
           -- 冪等: この週の通知を既に受け取っている人は飛ばす
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

-- 🔴 クライアントからは絶対に呼べないようにする (呼ばれると全員に通知が飛ぶ)
REVOKE EXECUTE ON FUNCTION public.dispatch_weekly_reports(date, text)
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.dispatch_weekly_reports(date, text) IS
    '週次レポート通知を配る (先週分)。冪等。cron かサービスロールからのみ呼ぶ';

-- ============================================
-- 4. 定期実行 (pg_cron)
-- ============================================
-- 🔴 pg_cron はこのプロジェクトに入っていない (2026-09-05 確認)。
--    Dashboard → Database → Extensions で pg_cron を有効化してから、
--    下記のコメントを外して実行すること = ユーザー作業。
--
--    月曜 09:00 JST = 日曜 00:00 UTC
--
-- select cron.schedule(
--     'weekly-report',
--     '0 0 * * 0',
--     $$ select public.dispatch_weekly_reports(); $$
-- );
--
-- 止めるとき: select cron.unschedule('weekly-report');

-- ============================================
-- 5. 手動で送る場合 (pg_cron を入れる前の確認用)
-- ============================================
-- ⚠️ 実行すると実ユーザーに本物のプッシュが飛ぶ。必ず件数を先に確認すること:
--
--   -- 何人に飛ぶかだけ数える (送らない)
--   select count(*) from public.users u
--    where exists (select 1 from public.block_sessions s
--                   where s.user_id = u.id and s.duration_seconds is not null);
--
--   -- 実際に送る
--   select public.dispatch_weekly_reports();
