-- ============================================================
-- Phase A-1: Apple Sign-In + create the users table
-- ============================================================
-- Purpose:
--   1. public.users table (app-side profile linked to Supabase Auth)
--   2. trigger that creates a public.users row automatically on auth.users INSERT
--
-- Assumptions:
--   - The Apple Provider is enabled in the Supabase Dashboard (already done)
--   - The client goes through Apple Sign-In → Supabase Auth signInWithIdToken
--
-- Run order:
--   this file → 002 → 003
-- ============================================================

-- ============================================
-- 1. users table
-- ============================================
CREATE TABLE IF NOT EXISTS public.users (
    id           uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name text,
    avatar_url   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.users IS 'アプリ側のユーザープロフィール。id は auth.users(id) と同じ';
COMMENT ON COLUMN public.users.display_name IS 'Apple Sign-In 初回ログイン時のみ取得、後で編集可';
COMMENT ON COLUMN public.users.avatar_url IS '将来 MyProfile からアップロード予定';

-- ============================================
-- 2. Function for the trigger that updates updated_at automatically
-- ============================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_set_updated_at ON public.users;
CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ============================================
-- 3. Create public.users automatically on auth.users INSERT
-- ============================================
-- Why: keeps data consistent even if the client misses an insert
-- SECURITY DEFINER: required to reference the auth schema
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.users (id, display_name)
    VALUES (
        NEW.id,
        -- Apple Sign-In puts full_name into raw_user_meta_data only the first time
        COALESCE(
            NEW.raw_user_meta_data->>'full_name',
            NEW.raw_user_meta_data->>'name',
            NULL
        )
    )
    ON CONFLICT (id) DO NOTHING;  -- ignore a duplicate, just in case
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();
