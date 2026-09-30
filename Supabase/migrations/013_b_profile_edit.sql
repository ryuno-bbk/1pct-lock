-- ============================================================
-- 013_b_profile_edit.sql
-- S15 profile edit: Storage avatars bucket + RLS
-- ============================================================
-- Purpose:
--   1. Create a public bucket `avatars` in Supabase Storage
--   2. Object-level RLS:
--      - SELECT: anyone (equivalent to a public bucket)
--      - INSERT/UPDATE/DELETE: only under your own {uid}/ folder
--   3. The file naming rule is fixed to `{uid}/avatar.jpg` on the Swift side
--      (cache invalidation is done on the Swift side by adding ?v=timestamp to the URL)
--
-- No change on the users table side:
--   - the display_name / avatar_url columns already exist from 001_a_auth.sql
--   - the is_pro column was added in 010_b_pro_badge.sql
--   - the 3 feed RPCs already return author_avatar_url since 010
--
-- Run order: after 012. Can be re-run (ON CONFLICT + DROP POLICY IF EXISTS)
-- ============================================================

-- ============================================
-- 1. Create the avatars bucket (public, 5MB limit, jpeg/png/webp)
-- ============================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'avatars',
    'avatars',
    true,
    5242880,                                                -- 5 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
    public              = EXCLUDED.public,
    file_size_limit     = EXCLUDED.file_size_limit,
    allowed_mime_types  = EXCLUDED.allowed_mime_types;

-- ============================================
-- 2. RLS policies
-- ============================================
-- storage.objects already has RLS enabled by Supabase (assumption)
-- Start with DROP IF EXISTS to avoid policy name collisions

DROP POLICY IF EXISTS "avatars_public_read"    ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_insert"   ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_update"   ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_delete"   ON storage.objects;

-- 2-1. Anyone can read (it is a public bucket, so it can also be referenced via the Supabase publicURL)
CREATE POLICY "avatars_public_read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'avatars');

-- 2-2. INSERT allowed only under your own uid folder
-- Path example: "{uid}/avatar.jpg" → (storage.foldername(name))[1] is the uid
CREATE POLICY "avatars_owner_insert"
    ON storage.objects
    FOR INSERT
    WITH CHECK (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 2-3. UPDATE allowed only under your own uid folder (for overwrite uploads)
CREATE POLICY "avatars_owner_update"
    ON storage.objects
    FOR UPDATE
    USING (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 2-4. DELETE allowed only under your own uid folder (for deleting the avatar)
CREATE POLICY "avatars_owner_delete"
    ON storage.objects
    FOR DELETE
    USING (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================
-- 3. Queries for checking behavior (no need to run, comments)
-- ============================================
-- Check the bucket:
--   SELECT id, public, file_size_limit FROM storage.buckets WHERE id = 'avatars';
-- Check the policies:
--   SELECT policyname, cmd FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
--   AND policyname LIKE 'avatars%';
