-- ============================================================
-- 048_safety_rubric_v2_1.sql
-- Layer 1 revision: extend sexual framing beyond the "combined with a photo of a person" case only
-- (2026-07-25)
-- ============================================================
-- Background: "sexual framing" in 044 required a combination of a photo of a person + sexual text, so
-- posts without a person, such as just the word "エロい" ("sexy") on a black background, slipped through
-- (confirmed in a live test).
-- Posts that present or solicit something sexual, even with text only, are now a fail.
--
-- Assumes: 044 is applied (full rewrite of safety_rubric. The stage costume wording from 045 is also
-- included in the text, so it is consistent whether or not the safety-side UPDATE in 045 was applied).
-- Apply order: 044 → (045) → 048. ethos_rubric is not touched.
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
  ただしジム・トレーニング・スポーツ文脈でのスポーツウェア (タンクトップ・レギンス・
  競技用水着等) は、露出があることを理由に fail にしない。アイドル・アーティストの
  ステージ衣装や宣材写真も同様に、露出だけを理由に fail にしない (性的アピールが
  主目的の場合のみ fail)
- ヘイトスピーチ: 人種・性別・性的指向・宗教・障害等に基づく差別的表現や中傷
- ハラスメント: 特定個人への誹謗中傷・晒し行為・つきまとい
- スパム: 無関係な宣伝、フィッシング、詐欺的リンク、大量重複投稿
- 違法行為: 違法薬物の売買・使用の助長、その他明確に違法な行為の描写や勧誘

誤爆コスト (合法な投稿を誤って弾くこと) より放置コスト (違反投稿を見逃すこと) の方が
高いドメインです。上記に明確に該当する場合のみ fail とし、判断に迷う場合は pass にせず
confidence を低くしてください (迷った点は analysis フィールドに明記)。
$safety$
WHERE id = true;
