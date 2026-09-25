-- ============================================================
-- Phase A-1: Apple Sign-In + users テーブル作成
-- ============================================================
-- 目的:
--   1. public.users テーブル（Supabase Auth と連動するアプリ側プロフィール）
--   2. auth.users INSERT 時に public.users 行を自動生成する trigger
--
-- 前提:
--   - Supabase Dashboard で Apple Provider が有効化済み（既に完了）
--   - クライアント側は Apple Sign-In → Supabase Auth signInWithIdToken 経由
--
-- 実行順序:
--   このファイル → 002 → 003 の順
-- ============================================================

-- ============================================
-- 1. users テーブル
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
-- 2. updated_at 自動更新 trigger 用関数
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
-- 3. auth.users INSERT 時に public.users 自動作成
-- ============================================
-- Why: クライアント側で insert 漏れがあっても整合性を担保する
-- SECURITY DEFINER: auth スキーマ参照のため必須
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
        -- Apple Sign-In は初回のみ raw_user_meta_data に full_name を入れる
        COALESCE(
            NEW.raw_user_meta_data->>'full_name',
            NEW.raw_user_meta_data->>'name',
            NULL
        )
    )
    ON CONFLICT (id) DO NOTHING;  -- 万一の重複は無視
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();
