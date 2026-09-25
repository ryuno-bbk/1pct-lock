-- ============================================================================
-- 067_moderation_hardening.sql
-- 第2弾: モデレーションの穴 (2026-08-01)
-- ============================================================================
-- 設計: Fable 5 / 実装: Sonnet 5 / レビュー: Fable 5
-- 設計書: Docs/design_phase2_moderation_2026_08_01.md (#5〜#9 + 追補)
-- 引き継ぎ: Docs/handoff_to_fable_2026_08_01.md #5〜#7
--
-- 「AI審査済み」という看板が外れる3+2の穴を塞ぐ:
--   #5   層1安全ルーブリックに欠落7カテゴリを追加 (自傷自殺/摂食障害/グロ/危険行為/
--        武器/動物虐待/テロ賛美) + キャッチオール条項 + 層2への「層1優先」明記
--   #5-b 却下理由(AIの生成文)をユーザー向け通知の preview_text に出さない
--   #6   承認後の Storage 上書き (同一パスへの再アップロードで再審査を逃れる) を封じる
--   #8   通報閾値 3→5 に引き上げ + 通報由来の非表示を ethos_enforce から独立させる
--   #9   通報理由に 'off_topic' (エトス専用) を追加
--   (#7 画像取得リトライ+fail-closed は moderate-post/index.ts 側。本ファイルの対象外)
--
-- ★最重要 (066を踏襲): 免除条件は auth.uid() IS NULL を使う。rolbypassrls は使わない。
--   本ファイルの新規トリガー関数はどれも「バックエンド免除」を必要としない
--   (report閾値trigger/lock系trigger/protect系trigger はどれも呼び出し元を問わず
--   常に同じロジックで動く設計、または既存の rolbypassrls 判定パターンを流用するのみ)。
--
-- DROP FUNCTION は使わない (既存関数はすべて CREATE OR REPLACE)。
--   DROP すると権限がリセットされる。063 で実際にこれが出荷ブロッカーを作った
--   (未認証で全投稿が読める状態になった。064 で修正)。
-- ============================================================================

BEGIN;

-- ============================================================================
-- §1. 層1安全ルーブリック: 欠落7カテゴリ + キャッチオール条項 (#5, #5-c)
-- ============================================================================
-- 056_safety_rubric_v2_2_gravure.sql の既存8カテゴリ (暴力/性的コンテンツ/性的な
-- 文脈づけ/過度な露出/ヘイトスピーチ/ハラスメント/スパム/違法行為) の文言は
-- 一字一句変更していない (このファイル内の該当8行は 056 からのコピー&ペースト)。
-- 追加/変更したのは (a) 冒頭1文の言い回し (b) 末尾に7カテゴリ (c) キャッチオール条項
-- (d) 結びの段落 (「のみ fail」の内部矛盾を解消) のみ。
--
-- #5-c: 現行末尾は「見逃す方が損」と言いながら「上記に明確に該当する場合のみ fail」と
-- リストを閉じており内部矛盾している (実地でグロテスク系がこの矛盾ですり抜けた)。
-- 列挙を「代表例」に格下げし、キャッチオール条項を追加する。
-- キャッチオールの判定先は rejected (mapVerdictToStatus: safety=fail → rejected は
-- moderate-post/index.ts:391 で既存のまま変更不要。ここはルーブリック文面の変更のみ)。
UPDATE public.moderation_config
SET safety_rubric = $safety$
【層1: 安全性ルーブリック】
一般的な SNS の投稿基準に照らして判定してください。以下は fail の代表例です。
明確に該当する場合はもちろん、個別には挙げられていなくても同種の安全性上の問題が
明確な場合は fail としてください:
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
- 自傷・自殺: 自傷行為の描写・傷跡の写真、自殺の方法・場所・手段への言及、
  自殺や自傷を勧める・美化する内容 (terms.html で禁止と公表済みの項目)
- 摂食障害・極端な減量の助長: 極端な絶食・カロリー制限の実践記録、痩せを目的とした
  嘔吐・下剤使用、「痩せていること」を目標として称揚し体型を貶める内容
- グロテスク・生理的嫌悪: 排泄物・嘔吐物・体液・害虫の大量発生等、生理的な嫌悪感を
  強く催す描写
- 危険行為・チャレンジ: 窒息・大量摂取等の生命に関わるチャレンジ、危険な場所での撮影、
  無謀運転
- 武器: 実物の銃・刃物等の誇示、武器の入手・製造方法への言及、武器を用いた脅迫。
  ただし映画・アニメ等のフィクション/シネマティックな引用表現 (層2エトス・ルーブリックの
  フィクション/引用素材の扱いと同じ考え方) はここでの fail の対象にしない
- 動物虐待: 動物への暴力・虐待行為の描写、動物を苦しめる様子の誇示
- テロ・暴力的過激思想: テロ行為・組織的な暴力的過激思想の賛美・支持・勧誘
  (個別の暴力行為は「暴力」項でカバー済み。本項は組織的な扇動・勧誘を対象とする)
- その他: 上記のいずれにも個別には当てはまらないが、一般的な SNS の利用規約に照らして
  安全性上明確に問題がある内容。上記の列挙は代表例であり、これらへの字面上の一致だけに
  限定されない

誤爆コスト (合法な投稿を誤って弾くこと) より放置コスト (違反投稿を見逃すこと) の方が
高いドメインです。上記の代表例、またはそれに準じる安全性上の問題が明確な場合は fail とし、
判断に迷う場合は pass にせず confidence を低くしてください (迷った点は analysis フィールドに明記)。
$safety$
WHERE id = true;

-- ============================================================================
-- §2. 層2エトス・ルーブリック: 層1優先の原則を明記 (#5-d)
-- ============================================================================
-- 057_post_limit_5_ethos_stage_quote.sql の全文をベースに、冒頭 (このアプリの説明) の
-- 直後へ「層1優先」の1段落だけを挿入する。それ以外の文言 (fail/pass の各項目、
-- 本人向け理由文のルール等) は 057 から一切変更していない。
--
-- 背景: safety=fail は mapVerdictToStatus (moderate-post/index.ts:390-394) が
-- ethos の値を見ずに rejected を返すため、コード上は既に層1が優先されている。
-- ここで追加するのはプロンプト文面側の明記であり、AI が「勉強・筋トレ・自己改善の
-- 文脈だから」という理由で層1相当の内容 (極端な断食等) を pass 方向の分析に
-- 引きずられないようにするための念押し (設計書 #5-d)。
UPDATE public.moderation_config
SET ethos_rubric = $ethos$
【層2: 「1%」エトス・ルーブリック】
このアプリ「1%」は自己改善・自己抑制をテーマにしたコミュニティです。投稿画像・テキストが
アプリの世界観(勉強・筋トレ・作業・自己改善)に沿っているかを判定してください。

⚠️ 層1優先の原則: 層1(安全性)で fail と判定される内容は、層2(このエトス判定)の
結果に関わらず fail の扱いになります。層2の判定はあくまで層1をクリアした内容に
対してのみ意味を持ちます。自傷・摂食障害・危険行為等、層1に該当しうる内容を
「勉強・筋トレ・自己改善の文脈だから」という理由だけで pass 側に倒さないでください。

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
  映画を視聴中の画面や様子など)。ただしアイドル・アーティスト本人が写るステージ写真・
  ライブ写真・宣材写真の引用は「視聴している様子」ではなく、ロールモデル引用 (下記 pass)
  として扱う
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
- 憧れのロールモデルの引用: 他人のアスリート・モデル・アイドル (K-POPアイドル等) の
  写真の引用投稿。ステージ上のパフォーマンス写真・ライブ写真・宣材写真を含む
  (エンタメを視聴している様子とは区別する。露出やステージ衣装だけを理由に fail にしない)
- 勉強・筋トレ・作業・自己改善に関する内容全般
- フィットネス系の自撮り・進捗報告: ジムでの自撮り、体づくりの進捗、スポーツウェア姿。
  露出があることだけを理由に fail にしない (性的アピールが主目的かどうかは層1で判定する)

方針: シーン認定が fail カテゴリに明確に該当する場合はテキストの有無に関わらず fail
(フィクション/引用素材・ロールモデル引用の pass 条件を満たす場合を除く)、どのカテゴリにも
明確に該当しない境界例は必ず pass (許可) にしてください。
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

-- ============================================================================
-- §3. 却下理由をユーザー通知の preview_text に出さない (#5-b)
-- ============================================================================
-- 現状確認 (実装前に読了): NotificationListView.swift の message computed property
-- (contentRejected/contentFlagged/appealApproved/appealRejected の4 kind) は
-- すべて kind から引く固定のローカライズ文言を表示しており、AI の理由文
-- (notification.previewText) は一切参照していない。previewText は別枠で
-- 「非空なら」引用符付きイタリック体で追加表示される仕組み (NotificationListView.swift:212-219、
-- `if let preview = notification.previewText, !preview.isEmpty { ... }`) になっており、
-- これが実質的に AI の safety_reason/ethos_reason をユーザーへ露出させていた。
-- → NULL を渡せばこの if 分岐が素通りして何も表示されない (レイアウトは壊れない)。
-- 「NULL だと表示が崩れる」パターンではないため、固定文言を新設する必要はない。
--
-- 対象は content_rejected/content_flagged の2 kind のみ。appeal_approved/appeal_rejected
-- (resolve_user_appeal トリガー、039) は resolution_note (運営/AIが本人向けに書いた文章、
-- #10 の user_note 含む) を preview_text に渡す設計を維持する — これは「AIの内部判定文」
-- ではなく「本人向けに書かれた結果メモ」であり、#5-b が問題にしている性質のものではない。
-- moderation_verdict 列自体は削除しない (審査室 admin-appeals が判断材料として参照する)。
CREATE OR REPLACE FUNCTION public.notify_on_post_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    -- 067 #5-b: AI の判定文 (safety_reason/ethos_reason) を preview_text に渡さない。
    -- クライアントは kind から固定文言を表示するため NULL で問題ない (上記コメント参照)。
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.user_id,
        p_actor_user_id     => NEW.user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.id,
        p_preview_text      => NULL
    );
    RETURN NEW;
END;
$$;
-- RETURNS trigger の関数は Postgres が直接呼び出しを拒否するため REVOKE/GRANT は不要
-- (039 の元定義と同じ扱い)。トリガー本体 (WHEN句・紐付け) は 039 から変更なし。

CREATE OR REPLACE FUNCTION public.notify_on_comment_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    -- 067 #5-b: 同上 (post 側と同じ理由)
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.author_user_id,
        p_actor_user_id     => NEW.author_user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.post_id,
        p_target_quote_id   => NEW.quote_id,
        p_target_comment_id => NEW.id,
        p_preview_text      => NULL
    );
    RETURN NEW;
END;
$$;

-- ============================================================================
-- §4. 承認後の Storage 上書きを封じる (#6)
-- ============================================================================
-- 現状: post_images_owner_update (019_post_v2.sql:97-103) は「自分の uid フォルダ配下
-- なら常に上書き可」。approved 後に同じパスへ禁止画像を upsert しても DB 行 (moderation_*)
-- は無変更なので再審査が起きない (承認済みの看板だけが残った状態ですり替えられる)。
--
-- クライアントは UserPostService.swift:280 (upload) / upsert:true で post-images に
-- 書き込み、正規フローは「Storage アップロード → user_posts INSERT」の順 (アップロード
-- 失敗時のリトライで UPDATE 権限が必要 = ポリシーの全撤去はできない、019 の設計どおり)。
-- アップロード時点では対応する user_posts 行がまだ存在しないため、下記ヘルパーは
-- 必ず false (未ロック=上書き可) を返す。既存の正規フローの挙動は変わらない。
--
-- RLS ポリシーから public.user_posts を直接参照すると、呼び出しユーザーの権限で
-- 評価されるため RLS の相互作用が読みにくい。SECURITY DEFINER のヘルパー関数を
-- 1本作ってポリシーから呼ぶ (設計書の指示どおり)。
CREATE OR REPLACE FUNCTION public.post_image_is_locked(object_name text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_posts p
        WHERE p.id::text = substring(storage.filename(object_name) from '^([0-9a-f-]{36})')
          AND p.moderated_at IS NOT NULL
    );
$$;

COMMENT ON FUNCTION public.post_image_is_locked(text) IS
    '067 #6: post-images オブジェクトが「対応する投稿が審査済み (moderated_at IS NOT NULL)」で '
    'ロック中かどうかを判定する。storage RLS ポリシーからのみ使う想定。'
    'この関数は「他人の投稿が審査済みかどうか」を真偽値で返すが、moderation_status は '
    'そもそも公開列 (フィード等で誰でも見える) なので新規の情報漏洩にはならない。';

-- 067: クライアントから直接呼べる関数のため REVOKE/GRANT を必ず設定する
-- (FROM anon だけでは暗黙の PUBLIC 付与が残ってしまう。065 の教訓)
REVOKE EXECUTE ON FUNCTION public.post_image_is_locked(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.post_image_is_locked(text) TO authenticated;

DROP POLICY IF EXISTS "post_images_owner_update" ON storage.objects;
CREATE POLICY "post_images_owner_update"
    ON storage.objects
    FOR UPDATE
    USING (
        bucket_id = 'post-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
        AND NOT public.post_image_is_locked(name)
    );
-- WITH CHECK は 019 の元定義どおり省略 (UPDATE ポリシーで WITH CHECK 未指定の場合、
-- Postgres は USING 句をそのまま新行の検証にも使うため実質的に同じ効果になる)。
--
-- avatars バケットは対象外 (アバターはモデレーション対象外、設計書に明記済み。触らない)。

-- ============================================================================
-- §5. 通報閾値の変更 + ethos_enforce からの分離 (#8)
-- ============================================================================
-- 現状: 042 が distinct reporter >= 3 で moderation_status='flagged' にし、
-- 063:160-162 (他 fetch_following_feed/fetch_tag_feed/search_posts/
-- fetch_comments_for_post/fetch_comments_for_quote/fetch_feed_extras も同型) の
-- フィード除外は ethos_enforce=true の間だけ flagged を隠す。つまり通報由来の非表示が
-- エトス判定のオン/オフに巻き込まれている (エトスを止めると通報も無効化されてしまう)。
--
-- 採用した方式: user_posts / user_comments に report_flagged boolean 列を追加し、
-- 「通報閾値で flagged になった」という由来を明示的に持たせる (moderation_status 自体は
-- 引き続き 'flagged' のまま = 既存の file_appeal / RLS 等が status で判定している箇所は
-- 無改修で動く。resolve_user_appeal の「status IN ('rejected','flagged')」判定、
-- fetch_notifications の content_flagged 通知、審査室の一覧表示は全部そのまま)。
-- 除外条件を全箇所で
--   moderation_status <> 'flagged' OR (NOT report_flagged AND NOT ethos_enforce)
-- に統一する。これにより:
--   - 通報閾値超え (report_flagged=true) → ethos_enforce の値に関わらず常に非表示
--   - 層2エトスのみで flagged (report_flagged=false) → 従来どおり ethos_enforce の
--     オン/オフに追従 (エトス判定を将来止めても通報は常に効く、という設計書の要求を満たす)
--
-- 別カラム方式を選んだ理由 (verdict jsonb にマークを埋める代替案を採らなかった理由):
--   - moderation_verdict は「AIの判定結果」を表す列という意味が既に決まっており (039/052/
--     admin-appeals が前提にしている)、通報由来という別種の情報を混ぜると意味が曖昧になる
--   - 042 のコメントに「閾値フラグでは verdict が無いことが多く NULL になる」とある通り、
--     report_flagged は AI 判定を経ない経路 (通報のみ) でも独立して立つ必要があり、
--     jsonb の中に埋めるより列で持つ方が WHERE 句・RLS ポリシーの両方から素直に参照できる
--   - 「flagged かつ ethos_enforce」だけを見る条件式に対して、既存のフィード等6箇所は
--     ほぼ同じ形の WHERE 句を繰り返しており、report_flagged 列を足す差分が最小

-- §5-1. report_flagged 列の追加
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS report_flagged boolean NOT NULL DEFAULT false;
ALTER TABLE public.user_comments
    ADD COLUMN IF NOT EXISTS report_flagged boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_posts.report_flagged IS
    '067 #8: 通報閾値 (5件) を超えて moderation_status=''flagged'' になった場合に true。'
    '層2エトスのみで flagged になった場合は false のまま。'
    'フィード等の除外判定で「ethos_enforce に関わらず常に非表示」にするためのマーカー。'
    '異議申し立て承認時 (resolve_user_appeal) に false へリセットされる';
COMMENT ON COLUMN public.user_comments.report_flagged IS
    '067 #8: user_posts.report_flagged と同じ意味 (コメント側)';

-- §5-2. 自己申告・改ざん防止: report_flagged は service_role 専用の書き込みにする
-- user_posts_update_own / user_comments_update_own (RLS UPDATE ポリシー) は行全体の
-- UPDATE を許可しており、本文/画像/moderation列は個別の protect trigger で守られている
-- のと同じパターンで、report_flagged も投稿者本人が直接 UPDATE で書き換えられてしまう
-- (自分の投稿を report_flagged=false に戻して非表示を解除できてしまう)。
-- 027 の protect_user_posts_moderation / protect_user_comments_moderation の
-- ガード対象列に report_flagged を追加する (moderation_status 等と同じ「service_role
-- 専用列」として扱う)。シグネチャ不変の CREATE OR REPLACE なので ACL・トリガー紐付けは
-- そのまま保持される。
CREATE OR REPLACE FUNCTION public.protect_user_posts_moderation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.moderation_status <> OLD.moderation_status
        OR NEW.moderation_verdict IS DISTINCT FROM OLD.moderation_verdict
        OR NEW.moderated_at IS DISTINCT FROM OLD.moderated_at
        -- 067: report_flagged も moderation 列と同じ扱いでロックする
        OR NEW.report_flagged IS DISTINCT FROM OLD.report_flagged THEN
        RAISE EXCEPTION 'moderation columns are read-only for users (service_role only)';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_user_comments_moderation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.moderation_status <> OLD.moderation_status
        OR NEW.moderation_verdict IS DISTINCT FROM OLD.moderation_verdict
        OR NEW.moderated_at IS DISTINCT FROM OLD.moderated_at
        OR NEW.report_flagged IS DISTINCT FROM OLD.report_flagged THEN
        RAISE EXCEPTION 'moderation columns are read-only for users (service_role only)';
    END IF;
    RETURN NEW;
END;
$$;
-- トリガー本体 (BEFORE UPDATE ... EXECUTE FUNCTION) は 027 で既に張られており、
-- 関数を CREATE OR REPLACE するだけで新しいロジックが即座に効く (再張り不要)。

-- §5-3. INSERT 時の自己申告防止 (066 lock_user_posts_insert / lock_user_comments_insert
-- に report_flagged := false を追加)。悪用耐性としては必須ではない (新規投稿は通報履歴が
-- 無いので report_flagged=true を自称しても自分の投稿を自分で隠すだけの自傷行為にしか
-- ならない) が、066 が他の自己申告可能列 (moderation_status 等) を一律 pending/false に
-- 固定している方針と揃え、「service_role 専用列は INSERT 時点でも常に既定値」を保つ。
CREATE OR REPLACE FUNCTION public.lock_user_posts_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    total_overlay_len integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;   -- service_role / SQL Editor / cron = バックエンド操作 (設計書 §1)
    END IF;

    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    NEW.comment_count      := 0;
    NEW.view_count         := 0;
    -- 067: report_flagged も自己申告不可にする (§5-2 のコメント参照)
    NEW.report_flagged     := false;

    IF NEW.image_path IS NOT NULL
       AND NEW.image_path NOT LIKE (NEW.user_id::text || '/%') THEN
        RAISE EXCEPTION 'image_path must be under your own folder';
    END IF;

    IF NEW.overlays IS NOT NULL THEN
        IF jsonb_array_length(NEW.overlays) > 30 THEN
            RAISE EXCEPTION 'overlays too long (max 30 elements)';
        END IF;

        SELECT COALESCE(sum(char_length(elem ->> 'text')), 0) INTO total_overlay_len
        FROM jsonb_array_elements(NEW.overlays) AS elem;

        IF total_overlay_len > 3000 THEN
            RAISE EXCEPTION 'overlays text too long (max 3000 chars total)';
        END IF;
    END IF;

    IF NEW.tags IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM unnest(NEW.tags) AS t WHERE char_length(t) > 30) THEN
            RAISE EXCEPTION 'tag too long (max 30 chars per tag)';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.lock_user_comments_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;   -- service_role / SQL Editor / cron = バックエンド操作
    END IF;

    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    -- 067: report_flagged も自己申告不可にする
    NEW.report_flagged     := false;

    RETURN NEW;
END;
$$;
-- どちらも RETURNS trigger の直接呼び出し不可な関数のため REVOKE/GRANT は不要 (066 と同じ)。
-- トリガー本体の張り直しは不要 (066 が既に BEFORE INSERT で張っており、関数の
-- CREATE OR REPLACE だけで新ロジックが有効になる)。

-- §5-4. 通報閾値 3→5 + report_flagged セット + 既に flagged な行も再判定できるよう修正
--
-- ⚠️ 042 の元 WHERE 句は `moderation_status IN ('approved', 'pending')` で、既に
-- 'flagged' な行を UPDATE 対象から除外していた (「flagged は no-op」という当時の設計)。
-- これは report_flagged という概念が無かった時代には無害だったが、そのまま残すと
-- 「層2エトスで先に flagged になった投稿は、後から通報が5件を超えても report_flagged が
-- 立たない」というバグになる (UPDATE の WHERE 句自体が素通りしてしまうため)。
-- そこで条件を `moderation_status <> 'rejected'` に変更し、approved/pending/flagged の
-- どの状態からでも通報閾値超えを反映できるようにする (rejected だけは層1 AI 判定を
-- 尊重して上書きしない、という元の意図はそのまま維持)。
CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- 067: 3 → 5 (ユーザー判断、設計書追補 #8)
    report_threshold constant integer := 5;
    v_count integer;
BEGIN
    IF NEW.target_post_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_post_id = NEW.target_post_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_posts
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_post_id
              AND moderation_status <> 'rejected';
        END IF;

    ELSIF NEW.target_comment_id IS NOT NULL THEN
        SELECT count(*) INTO v_count
        FROM public.user_reports
        WHERE target_comment_id = NEW.target_comment_id;

        IF v_count >= report_threshold THEN
            UPDATE public.user_comments
            SET moderation_status = 'flagged',
                moderated_at = now(),
                report_flagged = true
            WHERE id = NEW.target_comment_id
              AND moderation_status <> 'rejected';
        END IF;
    END IF;
    -- quote / user 通報は自動処理なし (042 のまま、運営手動)

    RETURN NEW;
END;
$$;
-- トリガー本体 (AFTER INSERT ON user_reports) は 042 のまま変更なし。

-- §5-5. 異議申し立て承認時に report_flagged をリセットする
-- resolve_user_appeal (039) は approved 時に moderation_status を 'approved' に戻すが、
-- report_flagged が true のまま残ると、対象が将来別の理由 (層2エトスのみ) で再び flagged
-- になった際に「通報由来ではないのに常時非表示」という過剰な扱いを引きずってしまう。
-- 異議申し立て承認 = 運営/AIが「この投稿は問題ない」と判断した行為そのものなので、
-- report_flagged も含めて汚名を洗い流すのが自然。
CREATE OR REPLACE FUNCTION public.resolve_user_appeal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.status = 'approved' THEN
        IF NEW.target_post_id IS NOT NULL THEN
            UPDATE public.user_posts
            SET moderation_status = 'approved', moderated_at = now(), report_flagged = false
            WHERE id = NEW.target_post_id;
        ELSIF NEW.target_comment_id IS NOT NULL THEN
            UPDATE public.user_comments
            SET moderation_status = 'approved', moderated_at = now(), report_flagged = false
            WHERE id = NEW.target_comment_id;
        END IF;
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_approved',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id
        );
    ELSIF NEW.status = 'rejected' THEN
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_rejected',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id,
            p_preview_text      => NEW.resolution_note
        );
    END IF;
    RETURN NEW;
END;
$$;
-- トリガー本体 (AFTER UPDATE ... WHEN (...)) は 039 のまま変更なし。

-- §5-6. フィード/検索/コメント除外の6箇所を report_flagged 対応に更新
-- 対象は「moderation_status <> 'flagged' OR NOT ethos_enforce」という同型の WHERE 句を
-- 持つ最新の関数定義6本 (履歴上、同名関数を後から上書きしている旧バージョンには触れない):
--   fetch_mixed_feed_random  (最新 = 063)
--   fetch_following_feed     (最新 = 029)
--   fetch_tag_feed           (最新 = 029)
--   search_posts             (最新 = 032)
--   fetch_comments_for_post  (最新 = 050)
--   fetch_comments_for_quote (最新 = 037)
--   fetch_feed_extras        (最新 = 037、comment_rows CTE のみ該当。likers は対象外
--     — user_likes に moderation_status が無いため元から無関係)
-- いずれも RETURNS TABLE の列・シグネチャは変更しないため CREATE OR REPLACE で足りる。
-- 本文は上記の最新版から一言一句コピーし、除外条件の1ブロックだけを書き換えている。

-- ---- 5-6-1. fetch_mixed_feed_random (最新: 063_feed_seeded_shuffle.sql) ----
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(
    limit_count integer DEFAULT 50,
    seed text DEFAULT NULL
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    WITH params AS MATERIALIZED (
        SELECT
            3.0  ::double precision AS w_recency,
            24.0 ::double precision AS recency_half_hours,
            0.5  ::double precision AS w_like,
            0.7  ::double precision AS w_comment,
            1.2  ::double precision AS w_follow,
            1.0  ::double precision AS w_seen,
            1.5  ::double precision AS w_jitter,
            0.45 ::double precision AS quote_base,
            2    ::integer          AS author_cap,
            15   ::integer          AS quote_cap,
            COALESCE(seed, gen_random_uuid()::text) AS shuffle_seed
    ),
    scored AS (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            CASE WHEN q.category IS NULL THEN '{}'::text[] ELSE ARRAY[q.category] END AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path,
            NULL::integer AS image_count,
            (
                p.quote_base
                + p.w_like * ln(1 + q.like_count)
                + p.w_comment * ln(1 + q.comment_count)
                + p.w_jitter * (
                    ('x' || substr(md5(q.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        CROSS JOIN params p

        UNION ALL

        SELECT
            'post'::text   AS kind,
            up.id           AS item_id,
            up.text_jp      AS body_jp,
            up.text_en      AS body_en,
            up.tags,
            up.like_count,
            up.comment_count,
            up.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            up.background_id,
            up.title,
            up.image_path,
            up.image_count,
            (
                p.w_recency / (
                    1 + GREATEST(EXTRACT(EPOCH FROM (now() - up.created_at)) / 3600.0, 0)
                        / p.recency_half_hours
                )
                + p.w_like * ln(1 + up.like_count)
                + p.w_comment * ln(1 + up.comment_count)
                + CASE
                    WHEN EXISTS (
                        SELECT 1 FROM public.user_follows f
                        WHERE f.follower_id = auth.uid() AND f.followed_user_id = u.id
                    ) THEN p.w_follow
                    ELSE 0
                  END
                - p.w_seen * ln(1 + COALESCE(pv.view_count, 0))
                + p.w_jitter * (
                    ('x' || substr(md5(up.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.user_posts up
        JOIN public.users u ON u.id = up.user_id
        LEFT JOIN public.post_views pv
            ON pv.post_id = up.id AND pv.viewer_id = auth.uid()
        CROSS JOIN params p
        WHERE up.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
          AND up.moderation_status <> 'rejected'
          AND (
            up.moderation_status <> 'flagged'
            OR (
                NOT up.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
          AND up.created_at > now() - interval '30 days'
    ),
    ranked AS (
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        SELECT GREATEST(
            p.quote_cap,
            limit_count - (
                SELECT count(*)::integer FROM ranked r2
                WHERE r2.kind = 'post' AND r2.author_rank <= p.author_cap
            )
        ) AS quote_allow
        FROM params p
    )
    SELECT
        r.kind, r.item_id, r.body_jp, r.body_en, r.tags, r.like_count, r.comment_count, r.created_at,
        r.author_id, r.author_name, r.author_avatar_url, r.is_official_author, r.is_pro_author,
        r.background_id, r.title, r.image_path, r.image_count
    FROM ranked r
    CROSS JOIN params p
    CROSS JOIN quota q
    WHERE (r.kind = 'quote' AND r.author_rank <= q.quote_allow)
       OR (r.kind = 'post'  AND r.author_rank <= p.author_cap)
    ORDER BY r.score DESC
    LIMIT limit_count;
$$;

COMMENT ON FUNCTION public.fetch_mixed_feed_random(integer, text) IS
    'おすすめフィード (名言+投稿の混合、スコアリング+seed 由来ジッター)。'
    '052: 同一投稿者は author_cap 件まで / 062: 名言は適応型 quote_cap / '
    '063: 並びの種をアプリが渡す / '
    '067: flagged の除外は report_flagged (通報由来、常時) OR ethos_enforce (エトス由来、可変) で判定';

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) TO authenticated;

-- ---- 5-6-2. fetch_following_feed (最新: 029_recommend_feed.sql) ----
CREATE OR REPLACE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            CASE WHEN q.category IS NULL THEN '{}'::text[] ELSE ARRAY[q.category] END AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path,
            NULL::integer AS image_count
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE EXISTS (
            SELECT 1 FROM public.user_follows
            WHERE follower_id = auth.uid()
              AND author_id = '11111111-1111-1111-1111-111111111111'::uuid
        )

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id,
            p.title,
            p.image_path,
            p.image_count
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE u.id IN (
            SELECT followed_user_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND followed_user_id IS NOT NULL
        )
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
          AND p.moderation_status <> 'rejected'
          AND (
            p.moderation_status <> 'flagged'
            OR (
                NOT p.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ---- 5-6-3. fetch_tag_feed (最新: 029_recommend_feed.sql) ----
CREATE OR REPLACE FUNCTION public.fetch_tag_feed(
    target_tag  text,
    limit_count integer DEFAULT 50
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            ARRAY[q.category] AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path,
            NULL::integer AS image_count
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE q.category = target_tag

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id,
            p.title,
            p.image_path,
            p.image_count
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE target_tag = ANY(p.tags)
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
          AND p.moderation_status <> 'rejected'
          AND (
            p.moderation_status <> 'flagged'
            OR (
                NOT p.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;

-- ---- 5-6-4. search_posts (最新: 032_search_posts.sql) ----
CREATE OR REPLACE FUNCTION public.search_posts(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH normalized AS (
        SELECT
            s.stripped AS raw,
            replace(replace(replace(s.stripped, '\', '\\'), '%', '\%'), '_', '\_') AS q
        FROM (
            SELECT CASE
                       WHEN trim(query) LIKE '#%' THEN substring(trim(query) FROM 2)
                       ELSE trim(query)
                   END AS stripped
        ) s
    )
    SELECT
        'post'::text   AS kind,
        up.id           AS item_id,
        up.text_jp      AS body_jp,
        up.text_en      AS body_en,
        up.tags,
        up.like_count,
        up.comment_count,
        up.created_at,
        u.id           AS author_id,
        u.display_name AS author_name,
        u.avatar_url   AS author_avatar_url,
        false          AS is_official_author,
        COALESCE(u.is_pro, false) AS is_pro_author,
        up.background_id,
        up.title,
        up.image_path,
        up.image_count
    FROM public.user_posts up
    JOIN public.users u ON u.id = up.user_id
    CROSS JOIN normalized n
    WHERE query IS NOT NULL
      AND n.q <> ''
      AND (
        up.title ILIKE '%' || n.q || '%'
        OR EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE t ILIKE n.q || '%'
        )
      )
      AND up.user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND up.moderation_status <> 'rejected'
      AND (
        up.moderation_status <> 'flagged'
        OR (
            NOT up.report_flagged
            AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
        )
      )
    ORDER BY
        CASE WHEN EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE lower(t) = lower(n.raw)
        ) THEN 0 ELSE 1 END,
        up.like_count DESC,
        up.created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.search_posts(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_posts(text, integer) TO authenticated;

-- ---- 5-6-5. fetch_comments_for_post (最新: 050_comment_owner_like.sql) ----
CREATE OR REPLACE FUNCTION public.fetch_comments_for_post(
    target_post_id uuid,
    limit_count    integer DEFAULT 200
)
RETURNS TABLE (
    id                 uuid,
    post_id            uuid,
    parent_comment_id  uuid,
    author_user_id     uuid,
    author_name        text,
    author_avatar_url  text,
    is_pro_author      boolean,
    text               text,
    like_count         integer,
    is_liked_by_me     boolean,
    created_at         timestamptz,
    reply_to_name      text,
    is_liked_by_owner  boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id,
        c.post_id,
        c.parent_comment_id,
        c.author_user_id,
        u.display_name      AS author_name,
        u.avatar_url        AS author_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_author,
        c.text,
        c.like_count,
        EXISTS (
            SELECT 1 FROM public.user_comment_likes l
            WHERE l.comment_id = c.id AND l.user_id = auth.uid()
        ) AS is_liked_by_me,
        c.created_at,
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name,
        EXISTS (
            SELECT 1
            FROM public.user_comment_likes ol
            JOIN public.user_posts p ON p.id = c.post_id
            WHERE ol.comment_id = c.id AND ol.user_id = p.user_id
        ) AS is_liked_by_owner
    FROM public.user_comments c
    JOIN public.users u ON u.id = c.author_user_id
    WHERE c.post_id = target_post_id
      AND c.author_user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND c.moderation_status <> 'rejected'
      AND (
        c.moderation_status <> 'flagged'
        OR (
            NOT c.report_flagged
            AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
        )
      )
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;

-- ---- 5-6-6. fetch_comments_for_quote (最新: 037_moderation_visibility_fixes.sql) ----
CREATE OR REPLACE FUNCTION public.fetch_comments_for_quote(
    target_quote_id uuid,
    limit_count     integer DEFAULT 200
)
RETURNS TABLE (
    id                 uuid,
    post_id            uuid,
    parent_comment_id  uuid,
    author_user_id     uuid,
    author_name        text,
    author_avatar_url  text,
    is_pro_author      boolean,
    text               text,
    like_count         integer,
    is_liked_by_me     boolean,
    created_at         timestamptz,
    reply_to_name      text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id,
        c.post_id,
        c.parent_comment_id,
        c.author_user_id,
        u.display_name      AS author_name,
        u.avatar_url        AS author_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_author,
        c.text,
        c.like_count,
        EXISTS (
            SELECT 1 FROM public.user_comment_likes l
            WHERE l.comment_id = c.id AND l.user_id = auth.uid()
        ) AS is_liked_by_me,
        c.created_at,
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name
    FROM public.user_comments c
    JOIN public.users u ON u.id = c.author_user_id
    WHERE c.quote_id = target_quote_id
      AND c.author_user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND c.moderation_status <> 'rejected'
      AND (
        c.moderation_status <> 'flagged'
        OR (
            NOT c.report_flagged
            AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
        )
      )
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) TO authenticated;

-- ---- 5-6-7. fetch_feed_extras (最新: 037_moderation_visibility_fixes.sql) ----
-- comment_rows CTE のみ変更対象。liker_rows は user_likes に moderation_status が
-- 無いため元から無関係 (037 時点から変更なし)。
CREATE OR REPLACE FUNCTION public.fetch_feed_extras(
    post_ids  uuid[] DEFAULT '{}',
    quote_ids uuid[] DEFAULT '{}'
)
RETURNS TABLE (
    kind     text,
    item_id  uuid,
    likers   jsonb,
    comments jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    WITH targets AS (
        SELECT 'post'::text AS kind, unnest(post_ids)  AS item_id
        UNION ALL
        SELECT 'quote'::text,        unnest(quote_ids)
    ),
    my_blocks AS (
        SELECT blocked_user_id FROM public.user_blocks
        WHERE blocker_id = auth.uid()
    ),
    liker_rows AS (
        SELECT
            t.kind,
            t.item_id,
            u.id           AS user_id,
            u.display_name,
            u.avatar_url,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY l.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_likes l
            ON (t.kind = 'post'  AND l.post_id  = t.item_id)
            OR (t.kind = 'quote' AND l.quote_id = t.item_id)
        JOIN public.users u ON u.id = l.user_id
        WHERE l.user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
    ),
    comment_rows AS (
        SELECT
            t.kind,
            t.item_id,
            c.id       AS comment_id,
            u.display_name AS author_name,
            c.text,
            c.created_at,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY c.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_comments c
            ON (t.kind = 'post'  AND c.post_id  = t.item_id)
            OR (t.kind = 'quote' AND c.quote_id = t.item_id)
        JOIN public.users u ON u.id = c.author_user_id
        WHERE c.author_user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
          AND c.moderation_status <> 'rejected'
          AND (
            c.moderation_status <> 'flagged'
            OR (
                NOT c.report_flagged
                AND NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
            )
          )
    )
    SELECT
        t.kind,
        t.item_id,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'user_id',      lr.user_id,
                'display_name', lr.display_name,
                'avatar_url',   lr.avatar_url
            ) ORDER BY lr.rn)
            FROM liker_rows lr
            WHERE lr.kind = t.kind AND lr.item_id = t.item_id AND lr.rn <= 3
        ), '[]'::jsonb) AS likers,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id',          cr.comment_id,
                'author_name', cr.author_name,
                'text',        cr.text
            ) ORDER BY cr.created_at ASC)
            FROM comment_rows cr
            WHERE cr.kind = t.kind AND cr.item_id = t.item_id AND cr.rn <= 3
        ), '[]'::jsonb) AS comments
    FROM targets t;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) TO authenticated;

-- §5-7. プロフィール等の直接 SELECT 経路 (RLS ポリシー) にも report_flagged を効かせる
--
-- 現状確認: UserPostService.swift の loadPosts(byUser:) (他人のプロフィール一覧) は
-- RPC を経由せず `.from("user_posts").select().eq("user_id", ...)` を直接叩いており、
-- 可視性は完全に RLS の user_posts_select_all ポリシーに依存している。037 時点の定義
-- (`auth.uid() = user_id OR moderation_status <> 'rejected'`) は flagged を一切
-- フィルタしていない (ethos_enforce の値に関わらず常に見える) — これはフィード側の
-- 「ethos_enforce に応じて隠す」設計とはそもそも別の、プロフィール側だけの既存ギャップで
-- あり、本タスク (#8: 通報由来の非表示を全除外経路で一貫させる) の対象そのもの。
-- ここでは #8 の要求どおり「通報由来 (report_flagged) は常に非表示」だけを追加し、
-- 「エトス由来 (report_flagged=false) の flagged がプロフィールでは ethos_enforce を
-- 無視して見え続ける」という pre-existing の非対称は意図的に変更しない
-- (#8 の依頼はあくまで通報由来の一貫性であり、ethos_enforce 自体のプロフィール適用は
-- 別議論。挙動を広げすぎて依頼スコープを超えることを避けた。詳細は実装報告に明記)。
DROP POLICY IF EXISTS "user_posts_select_all" ON public.user_posts;
CREATE POLICY "user_posts_select_all"
    ON public.user_posts FOR SELECT
    USING (
        auth.uid() = user_id
        OR (moderation_status <> 'rejected' AND NOT report_flagged)
    );

DROP POLICY IF EXISTS "user_comments_select_all" ON public.user_comments;
CREATE POLICY "user_comments_select_all"
    ON public.user_comments FOR SELECT
    USING (
        auth.uid() = author_user_id
        OR (moderation_status <> 'rejected' AND NOT report_flagged)
    );

-- ============================================================================
-- §6. user_reports.reason の CHECK に 'off_topic' を追加 (#9)
-- ============================================================================
-- 006_b_moderation.sql:32 の CHECK は無名制約 (Postgres が自動命名する
-- user_reports_reason_check) のまま一度も変更されていない (grep で確認済み)。
-- エトス違反 (「このアプリの趣旨に合わない」) 専用の通報理由が無く、ユーザーは
-- 'other' に自由記述するしかなかった。
-- 閾値カウントは他の理由と同列に扱う (§5 の flag_content_on_report_threshold は
-- reason を見ずに distinct reporter 数だけで判定するため、コード変更は不要)。
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_reason_check;
ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_reason_check
    CHECK (reason IN ('spam', 'harassment', 'hate', 'nudity', 'violence', 'other', 'off_topic'));

COMMIT;

-- ============================================================================
-- 検証クエリ (適用後にこれを流して結果を確認する。065/066 と同じ形式)
-- ============================================================================

-- (A) safety_rubric に7新カテゴリが入ったか
-- SELECT safety_rubric LIKE '%自傷・自殺%' AND safety_rubric LIKE '%摂食障害%'
--        AND safety_rubric LIKE '%グロテスク%' AND safety_rubric LIKE '%危険行為%'
--        AND safety_rubric LIKE '%武器%' AND safety_rubric LIKE '%動物虐待%'
--        AND safety_rubric LIKE '%テロ%' AS all_7_present
-- FROM moderation_config;
-- 期待値: true

-- (B) ethos_rubric に層1優先の一文が入ったか
-- SELECT ethos_rubric LIKE '%層1優先の原則%' AS priority_note_present FROM moderation_config;
-- 期待値: true

-- (C) report_flagged 列が追加され、既存行が false で埋まっているか
-- SELECT count(*) FILTER (WHERE report_flagged IS NULL) AS null_count,
--        count(*) FILTER (WHERE report_flagged = true)  AS true_count
-- FROM user_posts;
-- 期待値: null_count = 0 (NOT NULL DEFAULT false のため)

-- (D) 通報閾値トリガーが有効か + report_flagged を書き込む権限があるか
-- SELECT tgrelid::regclass, tgname, tgenabled
-- FROM pg_trigger
-- WHERE tgname IN (
--     'user_reports_flag_threshold', 'user_posts_protect_moderation',
--     'user_comments_protect_moderation', 'user_posts_lock_insert', 'user_comments_lock_insert'
-- );
-- 期待値: 全て tgenabled='O'

-- (E) post_image_is_locked の権限 (authenticated のみ実行可か)
-- SELECT grantee, privilege_type FROM information_schema.role_routine_grants
-- WHERE routine_name = 'post_image_is_locked';
-- 期待値: authenticated / EXECUTE の1行のみ (PUBLIC/anon は無いこと)

-- (F) user_reports.reason に off_topic が通るか (実データを汚さないよう ROLLBACK 前提でテストする場合の例)
-- BEGIN; INSERT INTO user_reports (reporter_id, target_post_id, reason)
--   VALUES ('<自分のuid>', '<既存post_id>', 'off_topic'); ROLLBACK;

-- (G) 通報閾値5件で report_flagged が立つか (手動テスト用手順、実行は不要)
-- 1. 適当な post_id に対し異なる5アカウントから
--    INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (..., '<post_id>', 'spam');
-- 2. SELECT moderation_status, report_flagged FROM user_posts WHERE id = '<post_id>';
--    → moderation_status='flagged', report_flagged=true
-- 3. UPDATE moderation_config SET ethos_enforce = false;
-- 4. SELECT * FROM fetch_mixed_feed_random(50) WHERE item_id = '<post_id>';
--    → 0行 (ethos_enforce を false にしても通報由来なので出てこないこと)
