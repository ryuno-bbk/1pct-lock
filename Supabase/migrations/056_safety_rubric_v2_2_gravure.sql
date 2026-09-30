-- ============================================================
-- 056_safety_rubric_v2_2_gravure.sql
-- Layer 1 revision: tighten the gravure check (found with the Haiku battery on 2026-07-30)
-- ============================================================
-- Background: Haiku approved a gravure-style composition of a pool × swimsuit. The exception in 048,
-- "competition swimsuits are not a fail in a sports context", very likely became a loophole (it misread
-- pool = sports context). The exception is limited to "scenes where competition/practice is actually
-- happening", and it is written explicitly that compositions whose main purpose is posing, looking at
-- the camera or presenting the body are a fail regardless of location.
--
-- Paired asymmetric escalation (moderate-post v14): when Haiku marks exposure content as fail, that is
-- final in one step (no Sonnet needed). Only when it marks exposure content as pass is low confidence
-- forced so Sonnet re-checks it.
--
-- Method: full rewrite of safety_rubric (includes the content of 048, idempotent). ethos_rubric is not
-- touched.
-- Apply: just run it in the SQL Editor, no deploy needed. Rollback: re-run 048.
-- ============================================================

UPDATE public.moderation_config
SET safety_rubric = $safety$
【層1: 安全性ルーブリック】
一般的な SNS の投稿基準に照らして判定してください。以下のいずれかに明確に該当する場合は fail としてください:
- 暴力: 実際の暴力行為・怪我・死体等の生々しい描写、暴力を扇動・賛美する内容
- 性的コンテンツ: 露骨な性的表現、児童の性的搾取(いかなる場合も即fail)、ヌード等
- 性的な文脈づけ: 「エロい」等の性的な形容・誘い文句を、タイトル・本文・画像内の文字として
  掲げた投稿。人物写真と組み合わせた場合はもちろん、人物が写っていない文字だけの投稿でも、
  性的な提示・誘引・釣りを目的としたテキストであれば fail とする。
  (学術的・健康的な文脈での性に関する言及まで弾く必要はない)
- 過度な露出: 下着姿や、性的アピールが主目的と見える過度な露出の人物写真
  (グラビア風・アダルトサービスの宣伝風のもの等)。
  判定手順: まず「この写真の主目的は何か」を一言で認定する —
  (a) 運動・競技・練習を実際にしている場面の記録か、(b) 身体を見せることが主目的の
  ポーズ写真 (カメラ目線・グラビア的ポージング・構図が身体の強調) か。
  (b) は、プール・海辺・ジム等のスポーツ的な場所であっても fail とする
  (場所や衣装の種類はスポーツ文脈の証明にならない)。
  (a) に限り、スポーツウェア (タンクトップ・レギンス・競技用水着等) の露出を理由に
  fail にしない。アイドル・アーティストのステージ上のパフォーマンス写真・宣材写真も
  同様に露出だけを理由に fail にしない (性的アピールが主目的の場合のみ fail)
- ヘイトスピーチ: 人種・性別・性的指向・宗教・障害等に基づく差別的表現や中傷
- ハラスメント: 特定個人への誹謗中傷・晒し行為・つきまとい
- スパム: 無関係な宣伝、フィッシング、詐欺的リンク、大量重複投稿
- 違法行為: 違法薬物の売買・使用の助長、その他明確に違法な行為の描写や勧誘

誤爆コスト (合法な投稿を誤って弾くこと) より放置コスト (違反投稿を見逃すこと) の方が
高いドメインです。上記に明確に該当する場合のみ fail とし、判断に迷う場合は pass にせず
confidence を低くしてください (迷った点は analysis フィールドに明記)。
$safety$
WHERE id = true;
