-- ============================================================
-- 013_b_profile_edit.sql
-- S15 プロフィール編集: Storage avatars バケット + RLS
-- ============================================================
-- 目的:
--   1. Supabase Storage に public バケット `avatars` を作成
--   2. オブジェクトレベル RLS:
--      - SELECT: 誰でも (public バケット相当)
--      - INSERT/UPDATE/DELETE: 自分の {uid}/ フォルダ配下のみ
--   3. ファイル命名規則は Swift 側で `{uid}/avatar.jpg` 固定
--      (キャッシュ無効化は Swift 側で URL に ?v=timestamp 付与)
--
-- users テーブル側は変更なし:
--   - display_name / avatar_url 列は 001_a_auth.sql で既に作成済
--   - is_pro 列は 010_b_pro_badge.sql で追加済
--   - 3 フィード RPC は author_avatar_url を 010 から既に返している
--
-- 実行順序: 012 完了後。再実行可能 (ON CONFLICT + DROP POLICY IF EXISTS)
-- ============================================================

-- ============================================
-- 1. avatars バケット作成 (public, 5MB 上限, jpeg/png/webp)
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
-- 2. RLS ポリシー
-- ============================================
-- storage.objects は Supabase が RLS 有効化済み (前提)
-- ポリシー名衝突を防ぐため DROP IF EXISTS から

DROP POLICY IF EXISTS "avatars_public_read"    ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_insert"   ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_update"   ON storage.objects;
DROP POLICY IF EXISTS "avatars_owner_delete"   ON storage.objects;

-- 2-1. 誰でも read 可 (public バケットなので Supabase publicURL でも参照可)
CREATE POLICY "avatars_public_read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'avatars');

-- 2-2. 自分の uid フォルダ配下のみ INSERT 可
-- パス例: "{uid}/avatar.jpg" → (storage.foldername(name))[1] が uid
CREATE POLICY "avatars_owner_insert"
    ON storage.objects
    FOR INSERT
    WITH CHECK (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 2-3. 自分の uid フォルダ配下のみ UPDATE 可 (上書きアップロード用)
CREATE POLICY "avatars_owner_update"
    ON storage.objects
    FOR UPDATE
    USING (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- 2-4. 自分の uid フォルダ配下のみ DELETE 可 (アバター削除用)
CREATE POLICY "avatars_owner_delete"
    ON storage.objects
    FOR DELETE
    USING (
        bucket_id = 'avatars'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================
-- 3. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- バケット確認:
--   SELECT id, public, file_size_limit FROM storage.buckets WHERE id = 'avatars';
-- ポリシー確認:
--   SELECT policyname, cmd FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
--   AND policyname LIKE 'avatars%';
