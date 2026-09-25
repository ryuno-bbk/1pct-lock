-- ============================================================
-- 038_account_deletion_storage_cleanup.sql
-- 監査 M32: アカウント削除時に Storage (avatars / post-images) の
-- 画像が消去されず公開URLで永久に閲覧可能なまま残る問題を修正
-- ============================================================
-- 背景:
--   009_b_moderation_v2.sql で定義した delete_my_account() は
--   public.users / auth.users の DELETE のみを行い、
--   storage.objects は一切削除していなかった。
--   avatars バケット・post-images バケットはどちらも public = true のため、
--   アカウント削除後もアバター画像・投稿画像が公開URLで
--   第三者から閲覧可能なまま残ってしまう (個人情報保護上の不備)。
--
-- 修正方針:
--   delete_my_account() を CREATE OR REPLACE し、
--   public.users / auth.users を削除する前に
--   storage.objects から本人所有のオブジェクトを削除する処理を追加する。
--
--   Storage パスの先頭ディレクトリは常に user_id の lowercase 文字列
--   (Swift 側: UserAuthService.uploadAvatar / UserPostService のアップロード
--   処理を参照。013_b_profile_edit.sql / 019_post_v2.sql の RLS ポリシーでも
--   同じ規約 (storage.foldername(name))[1] = auth.uid()::text を使用している):
--     - avatars:      "{uid}/avatar.jpg"
--     - post-images:  "{uid}/{post_id}.jpg", "{uid}/{post_id}_2.jpg" 〜 "_4.jpg"
--   Postgres の uuid → text キャストは常に lowercase 表記になるため、
--   target_user_id::text は Swift 側が生成するパスと自然に一致する。
--
--   storage.objects の DELETE を public.users / auth.users の DELETE より前に
--   行うことで、万一 Storage 側の削除に失敗した場合でも public.users /
--   auth.users の行がまだ残っておりリトライ可能な状態を保つ
--   (関数全体は単一トランザクションなので例外発生時はどのみち全体
--   ロールバックされるが、記述順序としての安全側に倣う)。
--
-- 実行順序: 009_b_moderation_v2.sql 適用後ならいつでも。何度実行しても安全
--   (CREATE OR REPLACE FUNCTION)。本ファイルはユーザーが Supabase Dashboard
--   → SQL Editor で手動適用する想定 (自動デプロイはしない)。
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, storage
AS $$
DECLARE
    target_user_id uuid := auth.uid();
BEGIN
    IF target_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- M32: 公開Storageバケット (avatars / post-images) の本人所有オブジェクトを
    -- 先に削除する。両バケットとも public = true のため、消し忘れると
    -- アカウント削除後も画像が公開URLで閲覧可能なまま残ってしまう。
    DELETE FROM storage.objects
    WHERE bucket_id IN ('avatars', 'post-images')
      AND (storage.foldername(name))[1] = target_user_id::text;

    -- public.users 削除 (CASCADE で関連データ消える)
    DELETE FROM public.users WHERE id = target_user_id;

    -- auth.users 削除 (SECURITY DEFINER + postgres owner で許可される)
    DELETE FROM auth.users WHERE id = target_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM anon;
GRANT  EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

COMMENT ON FUNCTION public.delete_my_account() IS 'アカウント削除。storage.objects (avatars/post-images) + auth.users + public.users CASCADE で関連データ全消去 (M32: Storage 削除を追加)';
