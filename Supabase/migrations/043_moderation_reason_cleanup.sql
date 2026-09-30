-- ============================================================
-- 043_moderation_reason_cleanup.sql
-- Cleaning up the verdict reason text (B-full, 2026-07-23)
-- ============================================================
-- Background (real-device feedback 2026-07-22/23): the model wrote its full analysis into
-- safety_reason/ethos_reason of moderation_verdict, and internal terms and the judging process such as
-- "fail on ethos" and "treat as a shadow verdict" appeared as is in the "verdict reason" shown to the
-- user (AppealSheetView).
--
-- Fix (one set with the simultaneous deploy of the moderate-post Edge Function):
--   1. Edge Function side: add an internal analysis field at the start of the output schema
--      (keeps reasoning-first = moves where the analysis is written away from reason, without losing
--      accuracy)
--   2. This SQL: append "【本人向け理由文のルール】" ("[Rules for the reason text shown to the
--      user]") at the end of the rubric, and rewrite "(本文で理由を明記)" ("(state the reason in the
--      body)") in safety_rubric so that it goes to analysis
--
-- Order: nothing breaks whichever of this SQL and the Edge Function deploy comes first
--   (SQL first = the rules mention analysis while it is not yet in the schema, but reason is still
--    cleaned / deploy first = analysis is generated, but until the rules are appended, reason keeps
--    its old style).
-- ============================================================

UPDATE public.moderation_config
SET
    -- The fallback that was "if unsure, state the reason in the reason body" is changed to go to analysis
    safety_rubric = replace(
        safety_rubric,
        '(本文で理由を明記)',
        '(迷った点は analysis フィールドに明記)'
    ),
    -- The output rules are appended in only one place, at the end of the prompt (= after ethos_rubric).
    -- buildSystemPrompt concatenates safety_rubric + ethos_rubric, so it applies to both layer 1 and
    -- layer 2
    ethos_rubric = ethos_rubric || $rules$

【本人向け理由文のルール】(層1・層2共通 / safety_reason・ethos_reason の書き方)
- safety_reason / ethos_reason は投稿者本人の画面にそのまま表示される文章です。
  分析・検討の過程は必ず analysis フィールドに書き、reason には結論の説明だけを書いてください。
- 日本語の丁寧語で、2文以内に収めてください。
- 内部用語・判定プロセスに言及しないでください:
  「層1」「層2」「エトス」「1%エトス」「shadow判定」「シャドー判定」「ethos_enforce」
  「confidence」「fail」「pass」「ルーブリック」等の語は reason に書いてはいけません。
- pass の場合の reason は空文字で構いません。
- fail の場合は「投稿のどの部分が」「どの基準に沿わないか」を本人が読んで分かる言葉で
  簡潔に伝えてください。
  例: 「ゲームをプレイしている様子の投稿は、このアプリのテーマ (勉強・運動・自己改善) に
  合わないため表示が制限されました」
$rules$
WHERE id = true
  -- Idempotency guard: running again does not append twice
  AND position('【本人向け理由文のルール】' in ethos_rubric) = 0;
