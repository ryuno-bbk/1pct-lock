-- ============================================================
-- 036_referral_source.sql
-- オンボ診断に流入元質問を追加 (2026-07-17 ユーザー確定、フィードプレビューの直後のステップ)
-- ============================================================
-- 目的: TikTok 広告等マーケ施策ごとの流入比率を把握するため。
-- 選択肢: tiktok / instagram / youtube / friend (友達・知人) / app_store (App Storeで見つけた) / other
--
-- 実行順序: 026 の後ならいつでも (033/034/035 とは独立)。何度実行しても安全
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
