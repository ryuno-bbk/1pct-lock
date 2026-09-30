-- ============================================================
-- 045_rubric_kpop_rolemodel.sql
-- Name idols explicitly in role model quotes (user feedback 2026-07-24)
-- ============================================================
-- "Role models you admire" include K-POP idols etc., and stage outfits can be revealing,
-- so state it in both layer 1 and layer 2 so they are not wrongly rejected for exposure alone.
-- Moderation cost does not increase (only a few dozen more rubric tokens in the same call).
-- Assumes 044 is applied. Replace approach, idempotent with a guard against applying twice.
-- ============================================================

-- Layer 1: add stage outfits to the sportswear exclusion
UPDATE public.moderation_config
SET safety_rubric = replace(
    safety_rubric,
    '露出があることを理由に fail にしない',
    '露出があることを理由に fail にしない。アイドル・アーティストのステージ衣装や宣材写真も同様に、露出だけを理由に fail にしない (性的アピールが主目的の場合のみ fail)'
)
WHERE id = true
  AND position('ステージ衣装や宣材写真' in safety_rubric) = 0;

-- Layer 2: add idols to the examples of role model quotes
UPDATE public.moderation_config
SET ethos_rubric = replace(
    ethos_rubric,
    '他人のアスリート・モデル写真を引用する投稿も pass',
    '他人のアスリート・モデル・アイドル (K-POP アイドル等) の写真を引用する投稿も pass'
)
WHERE id = true
  AND position('アイドル (K-POP アイドル等)' in ethos_rubric) = 0;
