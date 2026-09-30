-- ============================================================================
-- 072: restrict the SELECT policies of Storage (post-images / avatars) to your own folder only
--
-- Background: the SELECT policies of the post-images / avatars buckets
--   (post_images_public_read in 019_post_v2.sql and
--    avatars_public_read in 013_b_profile_edit.sql) both had no role specified (default = PUBLIC,
--    including anon) and only `USING (bucket_id = ...)`. So with only the publishable
--    key, calling `POST /storage/v1/object/list/{bucket}` could
--    list the UUIDs (= folder names) of all users and every file name under them.
--
-- Premises confirmed with primary sources (Supabase official docs, Buckets Fundamentals):
--   "When a bucket is designated as 'Public,' it effectively bypasses access
--    controls for both retrieving and serving files within the bucket."
--   "Access control is still enforced for other types of operations including
--    uploading, deleting, moving, and copying."
--   → https://supabase.com/docs/guides/storage/buckets/fundamentals
--   → In other words, downloads through the public URL of a public bucket (showing images) do not
--     go through RLS, so restricting the SELECT policy does not break image display in the feed
--     etc.
--
--   The list operation (listing a folder) goes through the SELECT policy of storage.objects.
--   → https://supabase.com/docs/guides/storage/security/access-control
--
-- What to do (chosen approach = read only your own folder):
--   post_images_public_read / avatars_public_read (SELECT, no role specified) are replaced with
--   post_images_owner_read / avatars_owner_read (SELECT, TO authenticated,
--   only under your own uid folder).
--
-- Not touched:
--   - The bucket's `public = true` is not changed. Changing it would invalidate the public URLs
--     issued by getPublicURL() themselves (a separate switch to signed URLs would be
--     needed, and all existing feed image display would break). As the docs above say,
--     downloads through the public URL keep working regardless of the SELECT policy change
--     in this file, so the bucket settings do not need to change.
--   - INSERT / UPDATE / DELETE policies are not touched at all. In particular, if
--     post_images_owner_update (the original policy in 019_post_v2.sql, to which
--     067_moderation_hardening.sql §4 added the `AND NOT public.post_image_is_locked(name)`
--     guard) were DROPped/CREATEd again in this file, it would erase the change from 067,
--     a critical accident. This file only targets the 2 SELECT
--     policies (one for post-images, one for avatars).
--
-- Checking the client impact (measured: all Swift files checked with grep):
--   There are 0 places in the app that call Storage `.list()`. The Storage APIs actually used
--   are only the 3 kinds below, and all of them are called only on paths under your own uid
--   folder:
--     - getPublicURL (builds a URL string without the network, works regardless of RLS):
--       FeedItem.swift / UserPost.swift / UserAuthService.swift
--     - upload (post image upload, avatar upload, the path is fixed to
--       "{uid}/..."): UserPostService.swift / UserAuthService.swift
--     - remove (rollback on upload failure, avatar deletion, likewise
--       only paths under your own uid folder):
--       UserPostService.swift / UserAuthService.swift
--   So no client-side regression is expected from the SELECT policy change
--   in this file.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. post-images: replace the SELECT policy with own-folder-only
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "post_images_public_read" ON storage.objects;  -- Old name (created by 019)
DROP POLICY IF EXISTS "post_images_owner_read"  ON storage.objects;  -- New name (in case of a rerun)

CREATE POLICY "post_images_owner_read"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ----------------------------------------------------------------------------
-- 2. avatars: replace the SELECT policy with own-folder-only
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "avatars_public_read" ON storage.objects;  -- Old name (created by 013)
DROP POLICY IF EXISTS "avatars_owner_read"  ON storage.objects;  -- New name (in case of a rerun)

CREATE POLICY "avatars_owner_read"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

COMMIT;

-- ============================================================================
-- Verification queries (run these after applying and check the results)
-- ============================================================================

-- (A) List of all policies on storage.objects.
--     Check that the roles of post_images_owner_read / avatars_owner_read are {authenticated},
--     and that the 6 INSERT/UPDATE/DELETE policies
--     (post_images_owner_insert/update/delete, avatars_owner_insert/update/delete)
--     did not change before and after applying this file (in particular, that the qual of
--     post_images_owner_update still contains post_image_is_locked).
SELECT policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects'
ORDER BY policyname;

-- (B) Check that the bucket's public column is still true (is image display still working).
SELECT id, public, file_size_limit
FROM storage.buckets
WHERE id IN ('post-images', 'avatars');
-- Expected: both public = true
