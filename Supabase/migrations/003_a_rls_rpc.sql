-- ============================================================
-- Phase A-3: RLS ポリシー全面書き直し + 新 RPC
-- ============================================================
-- 目的:
--   1. 旧 RPC (認可チェック皆無の脆弱版) を削除
--   2. 全テーブルの RLS を厳格化（anon 攻撃を完全遮断）
--   3. toggle 方式の新 RPC を実装（trans + auth.uid() + 冪等）
--
-- このファイルが対象とするテーブル:
--   users / authors / quotes / user_likes / user_follows
--   (user_posts / user_reports / user_blocks / block_sessions は
--    Phase B の各ファイルで自テーブル CREATE と同時に RLS 設定)
--
-- 実行順序:
--   001 + 002 完了後 → このファイル → Phase B
-- ============================================================

-- ============================================
-- 1. 旧 RPC 削除（致命的: 認可チェック皆無の脆弱版）
-- ============================================
DROP FUNCTION IF EXISTS public.increment_like_count(uuid);
DROP FUNCTION IF EXISTS public.decrement_like_count(uuid);

-- ============================================
-- 2. 既存ポリシー全削除（冪等性のため旧名 + 新名 両方カバー）
-- ============================================
-- 旧名（リネーム前 or Supabase 自動生成）
DROP POLICY IF EXISTS "authors_select"     ON public.authors;
DROP POLICY IF EXISTS "quotes_select"      ON public.quotes;
DROP POLICY IF EXISTS "user_likes_select"  ON public.user_likes;
DROP POLICY IF EXISTS "user_likes_insert"  ON public.user_likes;
DROP POLICY IF EXISTS "user_likes_delete"  ON public.user_likes;
DROP POLICY IF EXISTS "user_follows_select" ON public.user_follows;
DROP POLICY IF EXISTS "user_follows_insert" ON public.user_follows;
DROP POLICY IF EXISTS "user_follows_delete" ON public.user_follows;

-- 新名（このファイル自身が作る名前、再実行に備えて drop）
DROP POLICY IF EXISTS "users_select_all"        ON public.users;
DROP POLICY IF EXISTS "users_update_own"        ON public.users;
DROP POLICY IF EXISTS "users_delete_own"        ON public.users;
DROP POLICY IF EXISTS "authors_select_all"      ON public.authors;
DROP POLICY IF EXISTS "quotes_select_all"       ON public.quotes;
DROP POLICY IF EXISTS "user_likes_select_all"   ON public.user_likes;
DROP POLICY IF EXISTS "user_follows_select_all" ON public.user_follows;
DROP POLICY IF EXISTS "user_follows_insert_own" ON public.user_follows;
DROP POLICY IF EXISTS "user_follows_delete_own" ON public.user_follows;

-- ============================================
-- 3. RLS 有効化（既存テーブルは元から ON、念のため）
-- ============================================
ALTER TABLE public.users        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.authors      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_likes   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;

-- ============================================
-- 4. users テーブル RLS
-- ============================================
-- SELECT: 全員可（プロフィール公開、TikTok/Twitter と同じ）
CREATE POLICY "users_select_all"
    ON public.users FOR SELECT
    USING (true);

-- INSERT: クライアントから直接不可（trigger 経由のみ）
-- (handle_new_user trigger が SECURITY DEFINER で挿入するため、
--  RLS バイパス可、クライアント側は INSERT 不可)

-- UPDATE: 自分の行のみ（display_name / avatar_url 編集用）
CREATE POLICY "users_update_own"
    ON public.users FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- DELETE: 自分の行のみ（アカウント削除）
CREATE POLICY "users_delete_own"
    ON public.users FOR DELETE
    USING (auth.uid() = id);

-- ============================================
-- 5. authors テーブル RLS（公式コンテンツ）
-- ============================================
-- SELECT: 全員可
CREATE POLICY "authors_select_all"
    ON public.authors FOR SELECT
    USING (true);

-- INSERT/UPDATE/DELETE: anon/authenticated 全部不可
-- → service_role (Dashboard 経由) のみ操作可（RLS バイパス）
-- 明示ポリシー無しなら DENY 扱い

-- ============================================
-- 6. quotes テーブル RLS（公式名言）
-- ============================================
CREATE POLICY "quotes_select_all"
    ON public.quotes FOR SELECT
    USING (true);

-- INSERT/UPDATE/DELETE は service_role のみ（明示ポリシー無し = DENY）

-- ============================================
-- 7. user_likes テーブル RLS
-- ============================================
-- SELECT: 全員可（いいね数表示・自分のいいね一覧表示）
CREATE POLICY "user_likes_select_all"
    ON public.user_likes FOR SELECT
    USING (true);

-- INSERT/UPDATE/DELETE: クライアントから直接不可
-- → toggle_quote_like / toggle_post_like RPC 経由のみ
-- (RPC が SECURITY DEFINER で操作するため RLS バイパス)

-- ============================================
-- 8. user_follows テーブル RLS
-- ============================================
-- SELECT: 全員可（フォロワー数表示）
CREATE POLICY "user_follows_select_all"
    ON public.user_follows FOR SELECT
    USING (true);

-- INSERT: 自分の follower_id でのみ
CREATE POLICY "user_follows_insert_own"
    ON public.user_follows FOR INSERT
    WITH CHECK (auth.uid() = follower_id);

-- DELETE: 自分の follower_id でのみ
CREATE POLICY "user_follows_delete_own"
    ON public.user_follows FOR DELETE
    USING (auth.uid() = follower_id);

-- UPDATE: 不可（フォロー関係は変更しない、追加/削除のみ）

-- ============================================
-- 9. 新 RPC: 公式名言 toggle_quote_like
-- ============================================
-- 致命的問題 1,3 の根本解決:
--   - auth.uid() で認証必須
--   - user_likes 操作と quotes.like_count 更新を 1 トランザクション
--   - 冪等性: 既にいいね済みなら解除、未いいねなら追加
CREATE OR REPLACE FUNCTION public.toggle_quote_like(target_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id  uuid := auth.uid();
    existing_like_id uuid;
    new_count        integer;
    result_is_liked  boolean;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.quotes WHERE id = target_quote_id) THEN
        RAISE EXCEPTION 'Quote not found: %', target_quote_id;
    END IF;

    SELECT id INTO existing_like_id
    FROM public.user_likes
    WHERE user_id = current_user_id AND quote_id = target_quote_id;

    IF existing_like_id IS NOT NULL THEN
        DELETE FROM public.user_likes WHERE id = existing_like_id;
        UPDATE public.quotes
            SET like_count = GREATEST(like_count - 1, 0)
            WHERE id = target_quote_id
            RETURNING like_count INTO new_count;
        result_is_liked := false;
    ELSE
        INSERT INTO public.user_likes (user_id, quote_id)
            VALUES (current_user_id, target_quote_id);
        UPDATE public.quotes
            SET like_count = like_count + 1
            WHERE id = target_quote_id
            RETURNING like_count INTO new_count;
        result_is_liked := true;
    END IF;

    RETURN jsonb_build_object(
        'is_liked',   result_is_liked,
        'like_count', new_count
    );
END;
$$;

-- ============================================
-- 10. 実行権限の絞り込み
-- ============================================
-- anon (未ログイン) からは呼べないようにする
REVOKE EXECUTE ON FUNCTION public.toggle_quote_like(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.toggle_quote_like(uuid) TO authenticated;

-- 注: toggle_post_like は user_posts テーブル作成後 (005 ファイル) で実装
