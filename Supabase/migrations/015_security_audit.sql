-- ============================================================
-- 015_security_audit.sql
-- 実装順序2: セキュリティ監査 (2026-07-04) で発見した問題の修正
-- ============================================================
-- 発見と修正内容:
--   1. 【致命】user_reports の重複防止制約が UNIQUE NULLS NOT DISTINCT のため
--      NULL 同士が衝突し、1 ユーザーが実質生涯 2 件しか通報できない
--      (2 件目の投稿通報すら target_quote_id NULL 同士で弾かれる)
--      → 002 の user_likes と同じ部分ユニークインデックス方式に置換
--   2. 【高】users_update_own ポリシーが行全体の UPDATE を許すため、
--      認証ユーザーが自分の is_pro を直接 true にできる (Pro バッジ自己付与)
--      → rolbypassrls 判定の protect trigger で is_pro を読み取り専用化
--   3. 【高】block_sessions が完全クライアント申告制で、任意の
--      duration_seconds を insert できる (上位%機能のデータ源改ざん)
--      → 妥当性 trigger で明らかな異常値を拒否 (根本対策は上位%実装時に検討)
--   4. 【中】REVOKE FROM anon は関数の暗黙 PUBLIC grant を消さないため
--      意図した「anon から呼べない」が保証されない → REVOKE FROM PUBLIC に統一
--   5. 【低】protect_user_posts_like_count が comment_count を守っていない
--      (投稿者が自分の投稿の comment_count を任意値に更新可能)
--      → like_count と同じ扱いで保護
--   6. 【低】user_comment_likes の直 INSERT/DELETE ポリシーが like_count と
--      不整合を作れる (アプリは toggle_comment_like RPC のみ使用、直接続なし)
--      → ポリシーを閉じて RPC 専用化
--
-- 実行順序: 014 完了後。何度実行しても安全 (DROP IF EXISTS パターン)
-- ============================================================

-- ============================================
-- 1. user_reports 重複防止制約の修正
-- ============================================
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_unique_per_post;

ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_unique_per_quote;

-- 同じ人が同じ対象を 2 回通報できない (NULL 行は対象外 = 部分インデックス)
CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_post_unique
    ON public.user_reports(reporter_id, target_post_id)
    WHERE target_post_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_quote_unique
    ON public.user_reports(reporter_id, target_quote_id)
    WHERE target_quote_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS user_reports_reporter_user_unique
    ON public.user_reports(reporter_id, target_user_id)
    WHERE target_user_id IS NOT NULL;

-- ============================================
-- 2. users.is_pro の自己付与防止 trigger
-- ============================================
-- users_update_own ポリシーは display_name / avatar_url 編集用だが
-- 列単位の制限ができないため、is_pro は trigger で保護する。
-- 課金実装 (StoreKit 検証) 後は service_role / SECURITY DEFINER RPC のみが変更できる
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
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_protect_is_pro ON public.users;
CREATE TRIGGER users_protect_is_pro
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_users_is_pro();

-- ============================================
-- 3. block_sessions 妥当性 trigger
-- ============================================
-- クライアント申告制自体は維持しつつ、明らかな異常値を拒否する:
--   - 未来の started_at / ended_at (時計ずれ許容 5 分)
--   - started_at より前の ended_at
--   - started_at/ended_at と矛盾する duration_seconds (丸め許容 2 秒)
--   - 7 日超の単一セッション (最長は location モードの連続滞在を想定)
-- 注: started_at/ended_at ごと偽装する改ざんは防げない。
--     上位%機能の実装時に RPC でのサーバー側タイムスタンプ化を検討する
CREATE OR REPLACE FUNCTION public.validate_block_session()
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

    IF NEW.started_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'block_sessions: started_at is in the future';
    END IF;

    IF NEW.ended_at IS NOT NULL THEN
        IF NEW.ended_at > now() + interval '5 minutes' THEN
            RAISE EXCEPTION 'block_sessions: ended_at is in the future';
        END IF;
        IF NEW.ended_at < NEW.started_at THEN
            RAISE EXCEPTION 'block_sessions: ended_at before started_at';
        END IF;
        IF NEW.duration_seconds IS NULL
           OR abs(NEW.duration_seconds - EXTRACT(EPOCH FROM (NEW.ended_at - NEW.started_at))) > 2
        THEN
            RAISE EXCEPTION 'block_sessions: duration_seconds does not match timestamps';
        END IF;
        IF NEW.duration_seconds > 604800 THEN
            RAISE EXCEPTION 'block_sessions: session longer than 7 days rejected';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS block_sessions_validate ON public.block_sessions;
CREATE TRIGGER block_sessions_validate
    BEFORE INSERT OR UPDATE ON public.block_sessions
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_block_session();

-- ============================================
-- 4. RPC の実行権限を PUBLIC からも剥奪
-- ============================================
-- CREATE FUNCTION は暗黙で PUBLIC に EXECUTE を与える。
-- 既存の REVOKE FROM anon は anon への直接 grant がない場合は効果がなく、
-- anon は PUBLIC 経由で実行できてしまう。PUBLIC ごと剥奪して
-- authenticated だけに明示 grant し直す
REVOKE EXECUTE ON FUNCTION public.toggle_quote_like(uuid)                    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.toggle_post_like(uuid)                     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.toggle_comment_like(uuid)                  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_my_account()                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_total_block_seconds(uuid)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid)          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_notifications(integer)               FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fetch_unread_notification_count()          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.mark_all_notifications_read()              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_notification(uuid, uuid, text, uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.toggle_quote_like(uuid)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_post_like(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_comment_like(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_following_feed(integer)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account()                    TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_total_block_seconds(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_notifications(integer)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_unread_notification_count()      TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read()          TO authenticated;
-- create_notification は SECURITY DEFINER RPC / trigger 内部からのみ呼ぶ (grant なし)

-- ============================================
-- 5. protect_user_posts_like_count を comment_count も保護するよう拡張
-- ============================================
-- comment_count は sync_post_comment_count trigger (SECURITY DEFINER) だけが
-- 変更できる denormalize 列。user_posts_update_own ポリシーは行全体を許すので
-- trigger 側で読み取り専用化する
CREATE OR REPLACE FUNCTION public.protect_user_posts_like_count()
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
    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only for users (use toggle_post_like)';
    END IF;
    IF NEW.comment_count <> OLD.comment_count THEN
        RAISE EXCEPTION 'comment_count is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================
-- 6. user_comment_likes を RPC 専用化
-- ============================================
-- アプリは toggle_comment_like RPC のみ使用 (直 INSERT/DELETE は Swift 側に存在しない)。
-- 直操作を許すと like_count と実レコードの不整合を作れるため閉じる。
-- SELECT own は将来の is_liked 確認用に残す
DROP POLICY IF EXISTS "user_comment_likes_insert_own" ON public.user_comment_likes;
DROP POLICY IF EXISTS "user_comment_likes_delete_own" ON public.user_comment_likes;

-- ============================================
-- 7. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- 通報が複数回できることの確認 (別々の post を 2 回通報 → 両方成功すること):
--   INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (auth.uid(), '<post1>', 'spam');
--   INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (auth.uid(), '<post2>', 'spam');
-- is_pro 自己付与が拒否されることの確認 (authenticated で実行 → エラーになること):
--   UPDATE users SET is_pro = true WHERE id = auth.uid();
-- 異常な block_session が拒否されることの確認 (authenticated で実行 → エラーになること):
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status)
--   VALUES (auth.uid(), 'timer', now() - interval '1 hour', now(), 999999, 'completed');
