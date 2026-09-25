-- ============================================================
-- 047_moderation_model_switch.sql
-- モデレーションモデルを SQL 一発で切替可能に (2026-07-25 コスト対策)
-- ============================================================
-- moderate-post Edge Function は判定のたびに moderation_config を読むため、
-- この列を UPDATE するだけで次の判定から即座にモデルが替わる (再デプロイ不要)。
--
-- コスト目安 (512px縮小後の1判定):
--   claude-sonnet-5            : 0.7〜1.4円 (現行。~2026-08-31 の導入価格 $2/$10 前提)
--   claude-haiku-4-5-20251001  : 0.35〜0.7円 (約半額)
--
-- Haiku A/B の手順: 下の UPDATE を実行 → テスト投稿バッテリー
-- (グラビア/ドライブ/パチンコ/ジム自撮り/K-POP引用/「エロい」複合) を再投稿し
-- 全件正しく判定されるか確認。品質が落ちたら Sonnet へ戻す。
--   UPDATE public.moderation_config SET model = 'claude-haiku-4-5-20251001';
--   UPDATE public.moderation_config SET model = 'claude-sonnet-5';  -- 戻す
-- ============================================================

ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'claude-sonnet-5';

COMMENT ON COLUMN public.moderation_config.model IS
    'moderate-post が投稿/コメント判定に使う Anthropic モデル ID。UPDATE だけで即切替 (デプロイ不要)。通報トリアージは対象外 (テキストのみで元々軽微)';
