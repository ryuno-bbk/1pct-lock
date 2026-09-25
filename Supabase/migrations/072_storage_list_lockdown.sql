-- ============================================================================
-- 072: Storage (post-images / avatars) の SELECT ポリシーを自分のフォルダのみに絞る
--
-- 背景: post-images / avatars バケットの SELECT ポリシー
--   (019_post_v2.sql の post_images_public_read、013_b_profile_edit.sql の
--    avatars_public_read) は、どちらもロール無指定 (既定 = PUBLIC、anon を
--    含む) かつ `USING (bucket_id = ...)` のみだった。そのため publishable
--    キーだけで `POST /storage/v1/object/list/{bucket}` を叩くと、
--    全ユーザーの UUID (= フォルダ名) と配下の全ファイル名を列挙できる状態
--    だった。
--
-- 一次情報で確認済みの前提 (Supabase 公式ドキュメント、Buckets Fundamentals):
--   "When a bucket is designated as 'Public,' it effectively bypasses access
--    controls for both retrieving and serving files within the bucket."
--   "Access control is still enforced for other types of operations including
--    uploading, deleting, moving, and copying."
--   → https://supabase.com/docs/guides/storage/buckets/fundamentals
--   → つまり public バケットの public URL 経由のダウンロード (画像表示) は
--     RLS を通らないため、SELECT ポリシーを絞ってもフィード等の画像表示は
--     壊れない。
--
--   list 操作 (フォルダ内一覧) は storage.objects の SELECT ポリシーを通る。
--   → https://supabase.com/docs/guides/storage/security/access-control
--
-- やること (採用方式 = 自分のフォルダのみ read 可):
--   post_images_public_read / avatars_public_read (SELECT, ロール無指定) を、
--   post_images_owner_read / avatars_owner_read (SELECT, TO authenticated,
--   自分の uid フォルダ配下のみ) へ差し替える。
--
-- 触らないもの:
--   - バケットの `public = true` は変更しない。変更すると getPublicURL() が
--     発行する公開URLそのものが失効する (署名URL方式への切り替えが別途
--     必要になり、既存のフィード画像表示が全滅する)。上記ドキュメントの通り、
--     public URL 経由のダウンロードは本ファイルの SELECT ポリシー変更と
--     無関係に動き続けるため、バケット設定側は変更不要。
--   - INSERT / UPDATE / DELETE ポリシーには一切触れない。特に
--     post_images_owner_update (019_post_v2.sql の元ポリシーに対して、
--     067_moderation_hardening.sql §4 が `AND NOT public.post_image_is_locked(name)`
--     ガードを追加したもの) を本ファイルで DROP/CREATE し直すと、067 の変更を
--     消してしまう致命的な事故になる。本ファイルが対象にするのは SELECT
--     ポリシー2本 (post-images 用・avatars 用) のみ。
--
-- クライアント影響の確認 (実測: grep で全 Swift ファイルを確認済み):
--   アプリ内で Storage の `.list()` を呼んでいる箇所は0件。実際に使っている
--   Storage API は以下の3種類のみで、いずれも自分の uid フォルダ配下のパスに
--   対してのみ呼ばれている:
--     - getPublicURL (ネットワーク不要のURL文字列生成、RLSと無関係に動く):
--       FeedItem.swift / UserPost.swift / UserAuthService.swift
--     - upload (投稿画像アップロード・アバターアップロード、パスは
--       "{uid}/..." 固定): UserPostService.swift / UserAuthService.swift
--     - remove (アップロード失敗時のロールバック・アバター削除、同じく
--       自分の uid フォルダ配下のパスのみ):
--       UserPostService.swift / UserAuthService.swift
--   したがって本ファイルの SELECT ポリシー変更によるクライアント側の
--   デグレードは無い想定。
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. post-images: SELECT ポリシーを自分のフォルダのみに差し替え
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "post_images_public_read" ON storage.objects;  -- 旧名 (019 が作成)
DROP POLICY IF EXISTS "post_images_owner_read"  ON storage.objects;  -- 新名 (再実行に備えて)

CREATE POLICY "post_images_owner_read"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ----------------------------------------------------------------------------
-- 2. avatars: SELECT ポリシーを自分のフォルダのみに差し替え
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "avatars_public_read" ON storage.objects;  -- 旧名 (013 が作成)
DROP POLICY IF EXISTS "avatars_owner_read"  ON storage.objects;  -- 新名 (再実行に備えて)

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
-- 検証クエリ (適用後にこれを流して結果を確認する)
-- ============================================================================

-- (A) storage.objects の全ポリシー一覧。
--     post_images_owner_read / avatars_owner_read の roles が {authenticated}
--     になっていること、かつ INSERT/UPDATE/DELETE の6本
--     (post_images_owner_insert/update/delete, avatars_owner_insert/update/delete)
--     が本ファイル適用前後で変化していないこと (特に post_images_owner_update の
--     qual に post_image_is_locked が含まれたままであること) を確認する。
SELECT policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects'
ORDER BY policyname;

-- (B) バケットの public 列が true のままであることを確認 (画像表示が生きているか)。
SELECT id, public, file_size_limit
FROM storage.buckets
WHERE id IN ('post-images', 'avatars');
-- 期待結果: 両方とも public = true
