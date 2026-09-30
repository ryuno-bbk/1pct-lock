-- ============================================================
-- 053_ethos_fiction_quote_exception.sql
-- Layer 2 revision: rescue text on fiction/quotation images (2026-07-30 user idea)
-- ============================================================
-- Background: we want to let through posts that use a movie scene (a casino etc.) as a "cool image"
-- together with a quote or self-improvement text. But making "pass if the text is good" unconditional
-- would open a hole where every real pachinko photo + a high-minded caption slips through, so the
-- rescue condition is tied to the combination with the nature of the image, not the quality of the text:
--   - fiction/quotation material + text in a context of discipline, self-improvement or quotes → pass
--   - a document of the person's own activity (a real-life record) → fail as before, whatever the text
--
-- Method: full rewrite of ethos_rubric (includes the content of 049, idempotent).
-- Cost: only the wording changes, the API call structure is unchanged. The rubric is part of the system
--         prompt that is cached, so the extra cost is practically zero.
-- Assumes: 049 is applied. safety_rubric is not touched (048 is the latest).
-- Apply: just run it in the SQL Editor, no deploy needed (both moderate-post / review-appeal
--       read moderation_config every time, so it takes effect immediately).
-- Rollback: just re-run 049_ethos_scene_first.sql.
-- ============================================================

UPDATE public.moderation_config
SET ethos_rubric = $ethos$
【層2: 「1%」エトス・ルーブリック】
このアプリ「1%」は自己改善・自己抑制をテーマにしたコミュニティです。投稿画像・テキストが
アプリの世界観(勉強・筋トレ・作業・自己改善)に沿っているかを判定してください。

判定の大原則 (この順で判定する):
1. まず画像だけを見て「これは何をしている場面か」を一言で認定し、analysis に書いてください
   (例: ドライブ中の車内写真 / ジムでの自撮り / 食事の写真 / 勉強机の写真)。
   認定した場面が下の fail カテゴリに該当するなら、テキストが無くても・行き先や目的が
   書かれていなくても fail とします。「目的が読み取れない」「単なる移動かもしれない」を
   pass の理由にしないでください。
2. 場面認定の際、その画像が「本人・現実の記録 (自撮り、日常の実写、スクリーンショット等)」か
   「映画・アニメ・ドラマ等のフィクション/引用素材 (作品のワンシーン、シネマティックな
   画質・構図、ポスター、有名人の写真)」かも認定し、analysis に書いてください。
3. テキストは場面認定を補強・確定する材料です。画像だけでは中立・境界的でも、テキストが
   娯楽・遊びの文脈を確定させる場合 (例: 「ドライブ」「パチンコで12万勝った」) は
   テキストを優先して fail とします。

弾く対象 (fail):
- 明らかなジャンクフード・お菓子 (スナック菓子、菓子パン、ファストフード等) の写真
- スポーツ以外のエンタメを視聴している様子 (ドラマ・お笑い番組・バラエティ・YouTube動画・
  映画を視聴中の画面や様子など)
- 遊んでいる姿 (ゲームをプレイしている様子、遊興・娯楽に興じている様子)
- 遊び・レジャーのお出かけ: ドライブ、男女グループやカップルでの遊び・デートの様子、
  飲み会・パーティー・カラオケ等。車内で複数人が楽しんでいる写真は、行き先のテキストが
  無くてもドライブ/お出かけの場面と認定する。
  ただし一緒に勉強・筋トレ・作業・スポーツをしている様子であれば、人数や性別の構成に
  関わらず pass とする (ジムに男女2人で写っている等は pass)
- ギャンブル: パチンコ・スロット・競馬・カジノ等をしている様子、および勝敗・収支の報告
- ⚠️ 上記の fail カテゴリが「本人・現実の記録」である場合、テキストが名言・決意表明・
  意識の高い文言であっても救済しません (行為の記録はテキストで pass にならない)

許可する対象 (pass):
- パスタ等の食事の写真 (境界的なもの含む。迷ったら許可する)
- スポーツ全般 (格闘技を含む) の実施・観戦
- 映画のポスターや俳優の写真等、モチベーション目的の引用・言及 (視聴中の様子ではなく
  静止画やポスター、名言の引用等)
- フィクション/引用素材のワンシーン画像 (カジノ・豪遊・喧嘩などのシーンを含む) を、
  規律・向上・名言・モチベーションの文脈のテキストと共に投稿するもの。
  画像がフィクション/引用であることが見た目から明らかで、本人が行為をしている記録では
  ないことが条件。テキストが娯楽そのものの賛美 (「カジノ行きたい」「ギャンブル最高」等)
  の場合はこの救済を適用せず fail とする。テキストが無い場合は従来どおり場面認定に従う
- 勉強・筋トレ・作業・自己改善に関する内容全般
- フィットネス系の自撮り・進捗報告: ジムでの自撮り、体づくりの進捗、スポーツウェア姿。
  露出があることだけを理由に fail にしない (性的アピールが主目的かどうかは層1で判定する)。
  憧れのロールモデルとして他人のアスリート・モデル・アイドル (K-POP アイドル等) の写真を
  引用する投稿も pass

方針: シーン認定が fail カテゴリに明確に該当する場合はテキストの有無に関わらず fail
(フィクション/引用素材の救済条件を満たす場合を除く)、どのカテゴリにも明確に該当しない
境界例は必ず pass (許可) にしてください。
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
