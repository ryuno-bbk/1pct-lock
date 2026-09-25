-- ============================================================
-- 043_moderation_reason_cleanup.sql
-- 判定理由文の浄化 (B-full、2026-07-23)
-- ============================================================
-- 背景 (実機FB 2026-07-22/23): moderation_verdict の safety_reason/ethos_reason に
-- モデルが分析全文を書いてしまい、本人向けの「判定理由」表示 (AppealSheetView) に
-- 「エトス上は fail」「シャドー判定とする」等の内部用語・判定プロセスがそのまま出ていた。
--
-- 対応 (moderate-post Edge Function の同時デプロイとワンセット):
--   1. Edge Function 側: 出力スキーマ先頭に内部用 analysis フィールドを追加
--      (reasoning-first を維持 = 精度を落とさずに分析の書き場所を reason から移す)
--   2. この SQL: ルーブリック末尾に【本人向け理由文のルール】を追記し、
--      safety_rubric 内の「(本文で理由を明記)」を analysis 行きに書き換える
--
-- 順序: この SQL と Edge Function デプロイはどちらが先でも壊れない
--   (SQL のみ先行 = ルールが analysis に言及するがスキーマに無い間も reason は浄化される /
--    デプロイのみ先行 = analysis は生成されるがルール未追記の間は reason の文体が従来のまま)。
-- ============================================================

UPDATE public.moderation_config
SET
    -- 「迷ったら reason 本文に理由を明記」だった逃し先を analysis へ変更
    safety_rubric = replace(
        safety_rubric,
        '(本文で理由を明記)',
        '(迷った点は analysis フィールドに明記)'
    ),
    -- 出力ルールはプロンプト末尾 (= ethos_rubric の後ろ) に1箇所だけ追記する。
    -- buildSystemPrompt は safety_rubric + ethos_rubric を連結するため層1/層2の両方に効く
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
  -- 冪等ガード: 再実行しても二重追記しない
  AND position('【本人向け理由文のルール】' in ethos_rubric) = 0;
