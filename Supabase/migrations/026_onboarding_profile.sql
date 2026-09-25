-- ============================================================
-- 026_onboarding_profile.sql
-- 診断オンボーディングの回答保存 (user_onboarding_profiles)
-- ============================================================
-- 背景:
--   2026-07 オンボ再設計 (診断クイズ型)。質問6問の回答を本人専用の
--   非公開テーブルに保存する。用途: 将来のペイウォール文言パーソナライズ /
--   コホート分析 / 13歳ゲート通過記録。
--   公開 users テーブルには一切足さない (user_dreams と同じ方針)。
--
-- 適用方法:
--   019〜025 適用済みの環境に対し、Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/026_onboarding_profile.sql`
--
-- 実行順序: 025 の後。冪等 (IF NOT EXISTS / DROP ... IF EXISTS)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_onboarding_profiles (
    user_id         uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    birth_date      date,        -- Q1 (13歳未満はオンボで弾かれるためここには入らない)
    occupation      text,        -- Q2: student_hs / student_univ / employee / founder / other
    daily_hours     text,        -- Q3: lt2 / 2_4 / 4_6 / 6_8 / 8plus
    addiction_years text,        -- Q4: lt1 / 1_3 / 3_5 / 5_10 / 10plus
    wasted_apps     text[],      -- Q5: tiktok / instagram / youtube / x / games / streaming / other
    goal            text,        -- Q6: study / work / fitness / creation / reading / health
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_onboarding_profiles IS
    '診断オンボーディングの回答。本人のみ読み書き可 (完全非公開)。ペイウォール文言パーソナライズ/コホート分析用';

-- ============================================
-- RLS: 本人のみ (user_dreams と同じ完全非公開型)
-- ============================================
ALTER TABLE public.user_onboarding_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "onboarding_profiles_select_own" ON public.user_onboarding_profiles;
DROP POLICY IF EXISTS "onboarding_profiles_insert_own" ON public.user_onboarding_profiles;
DROP POLICY IF EXISTS "onboarding_profiles_update_own" ON public.user_onboarding_profiles;

CREATE POLICY "onboarding_profiles_select_own"
    ON public.user_onboarding_profiles FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "onboarding_profiles_insert_own"
    ON public.user_onboarding_profiles FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "onboarding_profiles_update_own"
    ON public.user_onboarding_profiles FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- DELETE ポリシーは意図的に無し (アカウント削除時は users の CASCADE で消える)
