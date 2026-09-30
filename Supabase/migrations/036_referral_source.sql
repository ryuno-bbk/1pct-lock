-- ============================================================
-- 036_referral_source.sql
-- Add a referral source question to the onboarding diagnosis (2026-07-17 user decision, the step
-- right after the feed preview)
-- ============================================================
-- Purpose: to understand the share of inflow per marketing channel, such as TikTok ads.
-- Options: tiktok / instagram / youtube / friend (friends/acquaintances) / app_store (found on the
-- App Store) / other
--
-- Execution order: any time after 026 (independent of 033/034/035). Safe to run any number of times
-- ============================================================

ALTER TABLE public.user_onboarding_profiles
    ADD COLUMN IF NOT EXISTS referral_source text;

ALTER TABLE public.user_onboarding_profiles
    DROP CONSTRAINT IF EXISTS user_onboarding_profiles_referral_source_check;

ALTER TABLE public.user_onboarding_profiles
    ADD CONSTRAINT user_onboarding_profiles_referral_source_check CHECK (
        referral_source IS NULL
        OR referral_source IN ('tiktok', 'instagram', 'youtube', 'friend', 'app_store', 'other')
    );

COMMENT ON COLUMN public.user_onboarding_profiles.referral_source IS
    '1%をどこで知ったか (tiktok/instagram/youtube/friend/app_store/other)。NULL = この質問を踏んでいない (旧バージョン/既存アカウント導線)';
