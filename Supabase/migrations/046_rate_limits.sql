-- ============================================================
-- 046_rate_limits.sql
-- 投稿/コメントのレート制限 (2026-07-25、モデレーションコスト防衛)
-- ============================================================
-- 背景: モデレーションは投稿1件 1.5〜3円 (画像枚数依存)、コメント1件 ~0.1円。
-- 上限が無いと1アカウントの暴走/荒らしでコストが青天井になる。
-- 上限は純粋な荒らし/bot対策であり、実ユーザーの体感には掛からない値にする
-- (ユーザー決定 2026-07-25: 「投稿上限は基本作りたくない。作っても100くらい」)。
--
-- 仕様:
--   - 投稿: 直近24時間で 100 件まで (固定日付切替でなくローリング24h。タイムゾーン問題を回避)
--   - コメント: 直近24時間で 300 件まで (返信含む。テキストのみでコスト軽微なため緩め)
--   - 上限変更は本ファイルの定数を書き換えて CREATE OR REPLACE を再実行するだけ
--   - ロール免除なし: コメントは create_comment RPC (SECURITY DEFINER, postgres 所有) 経由の
--     INSERT なので、rolbypassrls 免除を入れると制限が丸ごと素通りになる。純粋に
--     NEW.user_id の行数だけで判定する。運営が SQL Editor で大量シードする場合は
--     一時的に ALTER TABLE ... DISABLE TRIGGER で外す運用
--   - クライアントは RAISE EXCEPTION の文言 ('daily post limit reached' /
--     'daily comment limit reached') を含むかで上限到達を判定する
--     (AppealService の 'already appealed' と同じ文言判定パターン。変更時は
--     UserPostService.swift / CommentService.swift も要更新)
-- ============================================================

-- 1. 投稿: 100件 / 24h
CREATE OR REPLACE FUNCTION public.enforce_post_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    SELECT count(*) INTO recent_count
    FROM public.user_posts
    WHERE user_id = NEW.user_id
      AND created_at > now() - interval '24 hours';
    IF recent_count >= 100 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- 2. コメント: 300件 / 24h
CREATE OR REPLACE FUNCTION public.enforce_comment_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- user_comments の著者列は author_user_id (014 SQL。user_id ではない — 2026-07-25 修正)
    SELECT count(*) INTO recent_count
    FROM public.user_comments
    WHERE author_user_id = NEW.author_user_id
      AND created_at > now() - interval '24 hours';
    IF recent_count >= 300 THEN
        RAISE EXCEPTION 'daily comment limit reached';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_rate_limit ON public.user_comments;
CREATE TRIGGER user_comments_rate_limit
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_comment_rate_limit();
