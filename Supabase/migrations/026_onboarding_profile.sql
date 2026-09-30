-- ============================================================
-- 026_onboarding_profile.sql
-- Saves the diagnostic onboarding answers (user_onboarding_profiles)
-- ============================================================
-- Background:
--   2026-07 onboarding redesign (diagnostic quiz). The answers to the 6 questions are saved in a
--   private table visible only to the user. Uses: future paywall copy personalization /
--   cohort analysis / record of passing the age-13 gate.
--   Nothing is added to the public users table (same policy as user_dreams).
--
-- How to apply:
--   On an environment with 019 to 025 applied, paste and run it in the SQL Editor of the Supabase
--   Dashboard, or `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/026_onboarding_profile.sql`
--
-- Run order: after 025. Idempotent (IF NOT EXISTS / DROP ... IF EXISTS)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_onboarding_profiles (
    user_id         uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    birth_date      date,        -- Q1 (under-13s are rejected in onboarding, so they never get here)
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
-- RLS: owner only (fully private, same type as user_dreams)
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

-- No DELETE policy on purpose (on account deletion it is removed by the CASCADE from users)
