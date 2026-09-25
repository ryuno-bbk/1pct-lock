-- ============================================================
-- 023_user_bio.sql
-- プロフィールに自己紹介 (bio) を追加
-- ============================================================
-- 目的:
--   users.bio 列を追加。プロフィール画面 (自分/他人) に表示、ProfileEditView で編集。
--   160文字以内、任意 (NULL 可)。検索対象にはしない (search_users は handle/display_name のみ)。
--
-- 適用方法:
--   019〜022 適用済みの環境に対し、Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/023_user_bio.sql`
--
-- 実行順序: 022 完了後。冪等 (IF NOT EXISTS / DROP CONSTRAINT IF EXISTS)
-- ============================================================

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS bio text;

ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_bio_length;

ALTER TABLE public.users
    ADD CONSTRAINT users_bio_length CHECK (
        bio IS NULL OR char_length(bio) <= 160
    );

COMMENT ON COLUMN public.users.bio IS 'プロフィールの自己紹介。160文字以内、任意。プロフィール画面に表示、検索対象外';

-- RLS: users の SELECT/UPDATE ポリシーは既存 (001/013) のまま。bio は列追加のみで
-- 新規ポリシー不要 (自分の行のみ UPDATE 可、SELECT は全員可の既存設定が bio にもそのまま効く)。
