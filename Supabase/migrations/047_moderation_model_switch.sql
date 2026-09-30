-- ============================================================
-- 047_moderation_model_switch.sql
-- Make the moderation model switchable with one SQL statement (2026-07-25 cost measure)
-- ============================================================
-- The moderate-post Edge Function reads moderation_config on every review, so
-- just UPDATEing this column switches the model from the next review (no redeploy needed).
--
-- Cost estimate (one review after shrinking to 512px):
--   claude-sonnet-5            : ¥0.7-1.4 (current. Assumes the introductory price $2/$10 until
--                                ~2026-08-31)
--   claude-haiku-4-5-20251001  : ¥0.35-0.7 (about half)
--
-- Haiku A/B steps: run the UPDATE below → re-post the test post battery
-- (gravure/drive/pachinko/gym selfie/K-POP quote/"エロい" ("sexy") combined) and
-- check that every one is judged correctly. If quality drops, switch back to Sonnet.
--   UPDATE public.moderation_config SET model = 'claude-haiku-4-5-20251001';
--   UPDATE public.moderation_config SET model = 'claude-sonnet-5';  -- revert
-- ============================================================

ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'claude-sonnet-5';

COMMENT ON COLUMN public.moderation_config.model IS
    'moderate-post が投稿/コメント判定に使う Anthropic モデル ID。UPDATE だけで即切替 (デプロイ不要)。通報トリアージは対象外 (テキストのみで元々軽微)';
