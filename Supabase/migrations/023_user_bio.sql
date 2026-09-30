-- ============================================================
-- 023_user_bio.sql
-- Add a self-introduction (bio) to the profile
-- ============================================================
-- Purpose:
--   Add a users.bio column. Shown on the profile screen (own/others), edited in ProfileEditView.
--   Up to 160 characters, optional (NULL allowed). Not searchable (search_users only uses
--   handle/display_name).
--
-- How to apply:
--   On an environment with 019-022 applied, paste and run it in the SQL Editor of the Supabase
--   Dashboard, or `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/023_user_bio.sql`
--
-- Execution order: after 022. Idempotent (IF NOT EXISTS / DROP CONSTRAINT IF EXISTS)
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

-- RLS: the SELECT/UPDATE policies of users stay as they are (001/013). bio is only a column addition
-- and needs no new policy (the existing setup, UPDATE only on your own row and SELECT for everyone,
-- applies to bio as is).
