-- ============================================================
-- 035_onboarding_gender.sql
-- Add a gender question to the onboarding diagnosis (2026-07-17 user instruction, the step right
-- after date of birth)
-- ============================================================
-- The options are not binary, out of consideration for LGBTQ+: male / female / nonbinary /
-- prefer_not. Choosing "prefer not to answer" is also saved as prefer_not (to distinguish it from
-- NULL = no answer, the case where the user never saw this question, such as an upgrade from an old
-- version or the existing account path).
--
-- Execution order: any time after 026 (independent of 033/034). Safe to run any number of times
-- ============================================================

ALTER TABLE public.user_onboarding_profiles
    ADD COLUMN IF NOT EXISTS gender text;

ALTER TABLE public.user_onboarding_profiles
    DROP CONSTRAINT IF EXISTS user_onboarding_profiles_gender_check;

ALTER TABLE public.user_onboarding_profiles
    ADD CONSTRAINT user_onboarding_profiles_gender_check CHECK (
        gender IS NULL
        OR gender IN ('male', 'female', 'nonbinary', 'prefer_not')
    );

COMMENT ON COLUMN public.user_onboarding_profiles.gender IS
    '性別 (male/female/nonbinary/prefer_not)。NULL = この質問を踏んでいない (旧バージョン/既存アカウント導線)';
