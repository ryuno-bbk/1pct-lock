-- ============================================================
-- 038_account_deletion_storage_cleanup.sql
-- Audit M32: fix the problem where images in Storage (avatars / post-images) were not erased on
-- account deletion and stayed viewable forever through public URLs
-- ============================================================
-- Background:
--   delete_my_account() defined in 009_b_moderation_v2.sql
--   only DELETEd public.users / auth.users
--   and deleted nothing from storage.objects.
--   Both the avatars bucket and the post-images bucket are public = true, so
--   even after account deletion, avatar images and post images stayed viewable
--   by third parties through public URLs (a gap in personal data protection).
--
-- Fix:
--   CREATE OR REPLACE delete_my_account(), and before deleting
--   public.users / auth.users, add a step that deletes
--   the user's own objects from storage.objects.
--
--   The top directory of a Storage path is always the lowercase string of user_id
--   (Swift side: see UserAuthService.uploadAvatar / the upload logic in UserPostService.
--   The RLS policies in 013_b_profile_edit.sql / 019_post_v2.sql also use
--   the same convention (storage.foldername(name))[1] = auth.uid()::text):
--     - avatars:      "{uid}/avatar.jpg"
--     - post-images:  "{uid}/{post_id}.jpg", "{uid}/{post_id}_2.jpg" to "_4.jpg"
--   Postgres's uuid → text cast always produces lowercase, so
--   target_user_id::text naturally matches the paths generated on the Swift side.
--
--   By running the storage.objects DELETE before the public.users / auth.users DELETE,
--   even if the Storage-side deletion fails, the public.users /
--   auth.users rows still exist and a retry stays possible
--   (the whole function is a single transaction, so on an exception everything is
--   rolled back anyway, but the statement order follows the safe side).
--
-- Execution order: any time after 009_b_moderation_v2.sql is applied. Safe to run any number of times
--   (CREATE OR REPLACE FUNCTION). This file is meant to be applied manually by the user in Supabase
--   Dashboard → SQL Editor (no automatic deploy).
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

    -- M32: delete the user's own objects in the public Storage buckets (avatars / post-images)
    -- first. Both buckets are public = true, so if they are not deleted,
    -- images stay viewable through public URLs even after the account is deleted.
    DELETE FROM storage.objects
    WHERE bucket_id IN ('avatars', 'post-images')
      AND (storage.foldername(name))[1] = target_user_id::text;

    -- Delete public.users (related data is removed by CASCADE)
    DELETE FROM public.users WHERE id = target_user_id;

    -- Delete auth.users (allowed by SECURITY DEFINER + postgres owner)
    DELETE FROM auth.users WHERE id = target_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM anon;
GRANT  EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

COMMENT ON FUNCTION public.delete_my_account() IS 'アカウント削除。storage.objects (avatars/post-images) + auth.users + public.users CASCADE で関連データ全消去 (M32: Storage 削除を追加)';
