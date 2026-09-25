-- ============================================================
-- 055_haiku_cascade.sql
-- 2段カスケード有効化: 基本Haiku→低confidenceのみSonnet 5 (2026-07-30 ユーザー確定
-- 「基本俳句で、怪しいのはソネットファイブで見て、それでもunsureなら俺が見る」)
-- ============================================================
-- 全体像 (moderate-post v10 / review-appeal v5 とセット):
--   一次判定: Haiku 全件 → confidence < escalation_threshold なら Sonnet で再判定
--   申し立て: Haiku 再審査 → unsure なら Sonnet で再審査 → それでも unsure なら
--             運営キュー (ベル通知 054 + 運営の審査画面)
--
-- コスト: 通常判定 0.35〜0.7円 (Haiku)、エスカレーション時のみ +0.7〜1.4円 (Sonnet)。
--         047 試算の「平均 0.45〜0.9円」ライン。
--
-- 冪等。ロールバック (Sonnet 単独へ戻す):
--   UPDATE public.moderation_config SET model = 'claude-sonnet-5';
--   (model = escalation_model になるとカスケードは自動で無効化される)
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

-- 基本モデルを Haiku へ切替 (カスケードの土台。品質バッテリー6種で確認すること:
-- グラビア/ドライブ/パチンコ/ジム自撮り/K-POP引用/「エロい」複合)
UPDATE public.moderation_config SET model = 'claude-haiku-4-5-20251001';
