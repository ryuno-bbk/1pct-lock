-- ============================================================
-- 044_moderation_rubric_v2_enforce.sql
-- Rubric v2 + ethos_enforce goes live (2026-07-24 live test feedback)
-- ============================================================
-- Background (user's real device test 2026-07-24):
--   1. flagged posts flow into the recommended feed → not a bug; ethos_enforce was still false
--      (shadow mode). Now that notifications (039) + appeals + the restriction overlay are all in
--      place, switch it on for real.
--      The moment it is true, existing/future flagged posts disappear from all feed RPCs
--      (029/032/037/041). The author still sees them with an overlay in the My Page views (already
--      implemented on the client).
--   2. Fixes for real examples that slipped through:
--      - Photo of a woman + body text "エロい" ("sexy") → new layer 1 item "sexual framing"
--        (image × text combined)
--      - 4 men and women in a car + "ドライブ❤️" ("Drive ❤️") → new layer 2 item "going out for
--        play/leisure"
--      - "パチンコで12万勝った" ("Won 120,000 yen at pachinko") → new layer 2 item "gambling"
--   3. Boundary to protect (policy confirmed by the user): fitness selfies, progress reports and role
--      model quotes are not rejected for exposure. Only extreme exposure whose main purpose is sexual
--      appeal is rejected (judged on the layer 1 side).
--
-- Apply: just run this file in SQL Editor. No Edge Function redeploy needed
--   (by design, moderate-post reads the rubric from the DB on every review).
-- Rollback: set ethos_enforce=false and display goes back to shadow mode immediately.
--
-- Full rewrite approach (replaces everything, including the initial text from 027 + the additions
-- from 043), so it is idempotent.
-- ============================================================

UPDATE public.moderation_config
SET
    ethos_enforce = true,
    safety_rubric = $safety$
【層1: 安全性ルーブリック】
一般的な SNS の投稿基準に照らして判定してください。以下のいずれかに明確に該当する場合は fail としてください:
- 暴力: 実際の暴力行為・怪我・死体等の生々しい描写、暴力を扇動・賛美する内容
- 性的コンテンツ: 露骨な性的表現、児童の性的搾取(いかなる場合も即fail)、ヌード等
- 性的な文脈づけ: 人物写真に、その人物を性的対象として扱うテキスト (「エロい」等の
  性的な形容・誘い文句をタイトル/本文に付けたもの) を組み合わせた投稿。
  画像単体では穏当でも、テキストとの組み合わせで性的な提示になっていれば fail とする
- 過度な露出: 下着姿や、性的アピールが主目的と見える過度な露出の人物写真
  (グラビア風・アダルトサービスの宣伝風のもの等)。
  ただしジム・トレーニング・スポーツ文脈でのスポーツウェア (タンクトップ・レギンス・
  競技用水着等) は、露出があることを理由に fail にしない
- ヘイトスピーチ: 人種・性別・性的指向・宗教・障害等に基づく差別的表現や中傷
- ハラスメント: 特定個人への誹謗中傷・晒し行為・つきまとい
- スパム: 無関係な宣伝、フィッシング、詐欺的リンク、大量重複投稿
- 違法行為: 違法薬物の売買・使用の助長、その他明確に違法な行為の描写や勧誘

誤爆コスト (合法な投稿を誤って弾くこと) より放置コスト (違反投稿を見逃すこと) の方が
高いドメインです。上記に明確に該当する場合のみ fail とし、判断に迷う場合は pass にせず
confidence を低くしてください (迷った点は analysis フィールドに明記)。
$safety$,
    ethos_rubric = $ethos$
【層2: 「1%」エトス・ルーブリック】
このアプリ「1%」は自己改善・自己抑制をテーマにしたコミュニティです。投稿画像・テキストが
アプリの世界観(勉強・筋トレ・作業・自己改善)に沿っているかを判定してください。

判定の大原則: 画像とテキストは必ず組み合わせて判定してください。画像だけでは中立・境界的でも、
テキストが遊び・娯楽の文脈を確定させる場合 (例: 「ドライブ」「パチンコで12万勝った」) は
テキストを優先して fail とします。

弾く対象 (fail):
- 明らかなジャンクフード・お菓子 (スナック菓子、菓子パン、ファストフード等) の写真
- スポーツ以外のエンタメを視聴している様子 (ドラマ・お笑い番組・バラエティ・YouTube動画・
  映画を視聴中の画面や様子など)
- 遊んでいる姿 (ゲームをプレイしている様子、遊興・娯楽に興じている様子)
- 遊び・レジャーのお出かけ: ドライブ、男女グループやカップルでの遊び・デートの様子、
  飲み会・パーティー・カラオケ等。
  ただし一緒に勉強・筋トレ・作業・スポーツをしている様子であれば、人数や性別の構成に
  関わらず pass とする (ジムに男女2人で写っている等は pass)
- ギャンブル: パチンコ・スロット・競馬・カジノ等をしている様子、および勝敗・収支の報告

許可する対象 (pass):
- パスタ等の食事の写真 (境界的なもの含む。迷ったら許可する)
- スポーツ全般 (格闘技を含む) の実施・観戦
- 映画のポスターや俳優の写真等、モチベーション目的の引用・言及 (視聴中の様子ではなく
  静止画やポスター、名言の引用等)
- 勉強・筋トレ・作業・自己改善に関する内容全般
- フィットネス系の自撮り・進捗報告: ジムでの自撮り、体づくりの進捗、スポーツウェア姿。
  露出があることだけを理由に fail にしない (性的アピールが主目的かどうかは層1で判定する)。
  憧れのロールモデルとして他人のアスリート・モデル写真を引用する投稿も pass

方針: 上記の fail カテゴリに明確に該当しない境界例は必ず pass (許可) にしてください。
false negative (本来弾くべきものを見逃す) より false positive (許可すべきものを誤って弾く)
の方がユーザー体験を大きく損ないます。

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
$ethos$
WHERE id = true;
