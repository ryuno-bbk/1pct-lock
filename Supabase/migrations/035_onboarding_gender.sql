-- ============================================================
-- 035_onboarding_gender.sql
-- オンボ診断に性別質問を追加 (2026-07-17 ユーザー指示、生年月日の直後のステップ)
-- ============================================================
-- 選択肢は LGBTQ+ 配慮で二択にしない: male / female / nonbinary / prefer_not。
-- 「回答しない」を選んだ場合も prefer_not として保存する (NULL は未回答=旧バージョンからの
-- アップグレードや既存アカウント導線でこの質問を踏んでいないケースと区別するため)。
--
-- 実行順序: 026 の後ならいつでも (033/034 とは独立)。何度実行しても安全
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
