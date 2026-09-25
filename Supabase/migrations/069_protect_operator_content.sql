-- ============================================================================
-- 069_protect_operator_content.sql
-- 運営アカウントの投稿を通報の自動非表示から除外する (2026-08-01)
-- ============================================================================
-- ⚠️ 067_moderation_hardening.sql を適用した後に流すこと (report_flagged 列に依存)。
--
-- 【何が問題か】(2026-08-01 ユーザーが実機テスト中に指摘)
-- 067 で通報5件による自動非表示 (report_flagged) を導入したが、
-- flag_content_on_report_threshold は user_posts / user_comments を無条件に対象にしており、
-- 投稿者が誰かを見ていない。
--
-- 公式名言 (authors の 1% アカウント、020) は quote なので元から自動処理の対象外
-- (042 の設計どおり target_quote_id / target_user_id は自動処理しない)。
-- しかし **運営が自分の個人アカウントから user_posts で告知を出した場合**、
-- それは普通のUGCなので5件の通報で消える。
-- 例: 「広告を導入します」の告知に反発した5人が通報すれば、告知自体が消える。
-- 運営の発信手段が一般ユーザーの多数決で潰せる状態は不健全なので塞ぐ。
--
-- 【方針】
-- moderation_config.operator_user_id (054 で追加済み) の投稿/コメントは
-- 自動 flag の対象外にする。通報自体は記録され、運営キュー (審査室) には残るため
-- 「運営が完全に無敵」にはならない (人間が見て自分で判断する余地は残る)。
--
-- operator_user_id が NULL の場合は除外条件が一切効かない = 従来どおりの挙動 (fail-soft)。
-- ⚠️適用後にユーザー作業が1つ:
--     UPDATE public.moderation_config SET operator_user_id = '<自分のuser_id>';
--   未設定のままだと本ファイルは何もしないのと同じになる。
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- 067: 3 → 5 (ユーザー判断)
    report_threshold constant integer := 5;
    v_count    integer;
    v_operator uuid;
BEGIN
    -- 069: 運営アカウント (moderation_config.operator_user_id) の投稿は自動非表示にしない。
    -- NULL の場合は下の IS DISTINCT FROM が常に真になるため、従来どおり全員が対象になる。
    SELECT operator_user_id INTO v_operator FROM public.moderation_config LIMIT 1;

    IF NEW.target_post_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_post_id = NEW.target_post_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_posts
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_post_id
              AND moderation_status <> 'rejected'
              -- 069: 運営の投稿は除外
              AND (v_operator IS NULL OR user_id IS DISTINCT FROM v_operator);
        END IF;

    ELSIF NEW.target_comment_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_comment_id = NEW.target_comment_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_comments
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_comment_id
              AND moderation_status <> 'rejected'
              -- 069: 運営のコメントは除外
              AND (v_operator IS NULL OR author_user_id IS DISTINCT FROM v_operator);
        END IF;
    END IF;
    -- quote / user 通報は自動処理なし (042 のまま、運営手動)

    RETURN NEW;
END;
$$;

-- トリガー本体 (AFTER INSERT ON user_reports) は 042 のまま変更なし。
-- 関数は RETURNS trigger のため直接呼び出し不可 = REVOKE/GRANT 不要 (066/067 と同じ)。

COMMIT;

-- ============================================================================
-- 適用後にユーザーがやること
-- ============================================================================
-- 1. 自分の user_id を調べる (handle は自分のものに置き換える)
--    SELECT id, handle, display_name FROM public.users WHERE handle = '<自分のhandle>';
--
-- 2. 運営アカウントとして登録する
--    UPDATE public.moderation_config SET operator_user_id = '<上で出た id>';
--
-- 3. 確認 (1行返り、operator_user_id が自分の id になっていること)
--    SELECT operator_user_id FROM public.moderation_config;
