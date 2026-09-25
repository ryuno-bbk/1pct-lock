-- ============================================================
-- 042_comment_reports_threshold_flag.sql
-- コメント通報 (H9) + 通報閾値の自動非表示 (L21) — Bバケット UI パス
-- ============================================================
-- 背景:
--   H9: コメントを通報する手段が皆無 (Guideline 1.2 ②がコメント経路で不成立)。
--       user_reports は post / user / quote の3種のみで、コメントを対象にできない。
--   L21: 通報は溜まるだけで、閾値による自動非表示が無い。
--
-- 設計判断:
--   - target_comment_id 列を追加し、006 の「対象は少なくとも1つ必須」CHECK を
--     4対象へ拡張する (DROP → 再作成。既存行は3対象のいずれかが必ず非NULLなので
--     新CHECKでも全行有効)。
--   - 重複通報防止は 015 で確立した部分ユニークインデックス方式
--     (user_reports_reporter_{post,quote,user}_unique) に揃える。UNIQUE 制約でなく
--     インデックスなのは 015 の教訓 (UNIQUE NULLS NOT DISTINCT が NULL 組を1行に
--     制限してしまい通報が生涯2件で詰まった) の踏襲。
--   - Swift 側 (ReportService.reportComment) は SQLSTATE 23505 で重複を判定するため
--     (M14)、インデックス名は自由だが命名は既存3本と対で揃える。
--   - L21 閾値: user_reports INSERT 時、対象 (post / comment) への通報行数が
--     3 以上なら moderation_status を 'flagged' に落とす。
--       * 部分ユニークインデックスにより「行数 = distinct reporter 数」が保証される
--       * 上書きは approved / pending からのみ ('flagged' 方向のみ = 安全側)。
--         rejected (層1安全NG) はそのまま、既に flagged なら no-op
--       * quote / user 通報は対象外 (公式名言に moderation_status は無く、
--         ユーザー本体の自動制裁は誤爆リスクが高いため運営手動のまま)
--   - トリガー関数は SECURITY DEFINER (SQL Editor 実行 = postgres 所有)。
--     027 の protect_user_{posts,comments}_moderation は current_user の
--     rolbypassrls を見るため、postgres 実行なら素通りする (039 resolve_user_appeal
--     と同じ仕組み)。037 の H13 protect (本文イミュータブル化) は moderation 列に
--     触れないため干渉しない。
--   - flagged への遷移は 039 の user_{posts,comments}_notify_moderation トリガーを
--     自然に発火させ、本人へ content_flagged 通知が飛ぶ (preview_text は
--     moderation_verdict->>'ethos_reason' 由来。閾値フラグでは verdict が無いことが
--     多く NULL になるが、通知本文だけで意味が通るため許容)。
--   - moderate-post Edge Function の handleUserReport は reason / detail /
--     ai_severity しか読まないため、コメント通報でも変更不要 (AI トリアージは
--     対象の種類に依存しない)。deno 側デプロイなし。
--
-- 実行順序: 006 / 015 / 017 (user_comments) / 027 / 037 / 039 適用済みの環境が前提。
--   何度実行しても安全 (IF NOT EXISTS / DROP IF EXISTS → 再作成パターン)。
--   適用はユーザー側 (Supabase Dashboard → SQL Editor)。
-- ============================================================

-- ============================================================
-- 1. target_comment_id 列 + FK
-- ============================================================
ALTER TABLE public.user_reports
    ADD COLUMN IF NOT EXISTS target_comment_id uuid
        REFERENCES public.user_comments(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.user_reports.target_comment_id IS
    'コメント通報の対象 (042)。post/user/quote/comment のいずれか1つ以上が必須';

-- FK の CASCADE 削除 (コメント削除は日常操作) がセルフスキャンにならないよう
-- 対象列の部分インデックスを張る
CREATE INDEX IF NOT EXISTS idx_user_reports_target_comment
    ON public.user_reports(target_comment_id)
    WHERE target_comment_id IS NOT NULL;

-- ============================================================
-- 2. 「対象は少なくとも1つ必須」CHECK を 4 対象へ拡張
-- ============================================================
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_target_required;

ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_target_required CHECK (
        target_post_id IS NOT NULL
        OR target_user_id IS NOT NULL
        OR target_quote_id IS NOT NULL
        OR target_comment_id IS NOT NULL
    );

-- ============================================================
-- 3. 同一コメントの重複通報防止 (015 の部分ユニークインデックス方式)
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_comment_unique
    ON public.user_reports(reporter_id, target_comment_id)
    WHERE target_comment_id IS NOT NULL;

-- ============================================================
-- 4. L21: 通報閾値 (distinct reporter >= 3) で自動 flagged 化
-- ============================================================
CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    report_threshold constant integer := 3;
    v_count integer;
BEGIN
    IF NEW.target_post_id IS NOT NULL THEN
        -- 部分ユニークインデックスにより行数 = distinct reporter 数
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_post_id = NEW.target_post_id;

        IF v_count >= report_threshold THEN
            -- 上書きは flagged 方向のみ (approved/pending → flagged)。
            -- rejected は AI 層1判定を尊重してそのまま、flagged は no-op
            UPDATE public.user_posts
            SET moderation_status = 'flagged', moderated_at = now()
            WHERE id = NEW.target_post_id
              AND moderation_status IN ('approved', 'pending');
        END IF;

    ELSIF NEW.target_comment_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_comment_id = NEW.target_comment_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_comments
            SET moderation_status = 'flagged', moderated_at = now()
            WHERE id = NEW.target_comment_id
              AND moderation_status IN ('approved', 'pending');
        END IF;
    END IF;
    -- quote / user 通報は自動処理なし (運営手動)

    RETURN NEW;
END;
$$;

-- AFTER INSERT: 当該 INSERT 行を含んだ件数で判定される。
-- 同時 INSERT の競合でも UPDATE は冪等 (条件付き flagged 化) なので問題ない
DROP TRIGGER IF EXISTS user_reports_flag_threshold ON public.user_reports;
CREATE TRIGGER user_reports_flag_threshold
    AFTER INSERT ON public.user_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.flag_content_on_report_threshold();

-- ============================================================
-- 5. 動作確認用クエリ (実行不要、コメント)
-- ============================================================
-- コメント通報 (アプリの通報UIから、または):
--   INSERT INTO user_reports (reporter_id, target_comment_id, reason)
--   VALUES (auth.uid(), '<comment_id>', 'spam');
-- 同一コメントに 3 アカウントから通報後:
--   SELECT moderation_status FROM user_comments WHERE id = '<comment_id>';  -- → flagged
-- 本人に content_flagged 通知が届いていること:
--   SELECT * FROM fetch_notifications(20) WHERE kind = 'content_flagged';
