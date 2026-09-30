-- ============================================================
-- 055_haiku_cascade.sql
-- Enable the 2-stage cascade: Haiku by default → Sonnet 5 only for low confidence (2026-07-30 confirmed
-- by the user: "Haiku by default, have Sonnet 5 look at the suspicious ones, and if it's still unsure,
-- I'll look")
-- ============================================================
-- Overall picture (paired with moderate-post v10 / review-appeal v5):
--   First decision: Haiku for everything → if confidence < escalation_threshold, decide again with Sonnet
--   Appeals: Haiku re-review → if unsure, re-review with Sonnet → if still unsure,
--             operator queue (bell notification 054 + the operator review screen)
--
-- Cost: a normal decision is 0.35 to 0.7 yen (Haiku), +0.7 to 1.4 yen only on escalation (Sonnet).
--         This is on the line of "average 0.45 to 0.9 yen" from the 047 estimate.
--
-- Idempotent. Rollback (back to Sonnet alone):
--   UPDATE public.moderation_config SET model = 'claude-sonnet-5';
--   (when model = escalation_model, the cascade is disabled automatically)
-- ============================================================

ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS escalation_model text NOT NULL DEFAULT 'claude-sonnet-5';

COMMENT ON COLUMN public.moderation_config.escalation_model IS
    '低confidence判定 (一次) / unsure (申し立て) を再判定する上位モデル。'
    'model と同一値ならカスケード無効 (単段運用)';

ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS escalation_threshold numeric NOT NULL DEFAULT 0.8;

COMMENT ON COLUMN public.moderation_config.escalation_threshold IS
    '一次判定の confidence がこの値未満なら escalation_model で再判定 (0〜1)。'
    'エスカレーション頻度が高すぎ/低すぎな時は SQL でこの値を調整';

-- Switch the base model to Haiku (the base of the cascade. Check it with the 6-case quality battery:
-- gravure/drive/pachinko/gym selfie/K-POP quote/"エロい" ("sexy") compound)
UPDATE public.moderation_config SET model = 'claude-haiku-4-5-20251001';
