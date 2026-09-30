-- ============================================================================
-- 067_moderation_hardening.sql
-- Round 2: moderation gaps (2026-08-01)
-- ============================================================================
-- Design: Fable 5 / Implementation: Sonnet 5 / Review: Fable 5
-- Design doc: Docs/design_phase2_moderation_2026_08_01.md (#5 to #9 + addendum)
-- Handoff: Docs/handoff_to_fable_2026_08_01.md #5 to #7
--
-- Closes the 3+2 gaps that make the "AI-reviewed" label untrue:
--   #5   Add the 7 missing categories to the layer 1 safety rubric (self-harm/suicide, eating
--        disorders, gore, dangerous acts, weapons, animal abuse, glorifying terrorism)
--        + a catch-all clause + state "layer 1 takes priority" in layer 2
--   #5-b Do not show the rejection reason (AI-generated text) in preview_text of user notifications
--   #6   Block Storage overwrites after approval (re-uploading to the same path escapes re-review)
--   #8   Raise the report threshold 3→5 + make report-based hiding independent of ethos_enforce
--   #9   Add 'off_topic' (ethos only) as a report reason
--   (#7 image fetch retry + fail-closed is in moderate-post/index.ts. Out of scope for this file)
--
-- ★Most important (same as 066): the exemption condition uses auth.uid() IS NULL. Not rolbypassrls.
--   None of the new trigger functions in this file need a "backend exemption"
--   (the report threshold trigger / lock triggers / protect triggers all run the same logic
--   regardless of the caller, or only reuse the existing rolbypassrls check pattern).
--
-- Do not use DROP FUNCTION (all existing functions use CREATE OR REPLACE).
--   DROP resets the privileges. In 063 this actually created a release blocker
--   (all posts were readable without authentication. Fixed in 064).
-- ============================================================================

BEGIN;

-- ============================================================================
-- §1. Layer 1 safety rubric: 7 missing categories + catch-all clause (#5, #5-c)
-- ============================================================================
-- The wording of the existing 8 categories in 056_safety_rubric_v2_2_gravure.sql (violence / sexual
-- content / sexual framing / excessive exposure / hate speech / harassment / spam / illegal acts) is
-- unchanged, word for word (those 8 lines in this file are copy-pasted from 056).
-- The only additions/changes are (a) the wording of the first sentence (b) 7 categories at the end
-- (c) the catch-all clause (d) the closing paragraph (removes the internal contradiction of "fail only").
--
-- #5-c: The current ending says "missing something costs more" but then closes the list with
-- "fail only if it clearly matches the above", which contradicts itself (in practice, gore content
-- slipped through because of this contradiction).
-- Downgrade the list to "representative examples" and add a catch-all clause.
-- The catch-all verdict goes to rejected (mapVerdictToStatus: safety=fail → rejected already exists
-- in moderate-post/index.ts:391 and needs no change. Only the rubric text changes here).
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
-- §2. Layer 2 ethos rubric: state the "layer 1 first" principle (#5-d)
-- ============================================================================
-- Based on the full text of 057_post_limit_5_ethos_stage_quote.sql, insert only one "layer 1 first"
-- paragraph right after the opening (the description of this app). All other wording (each fail/pass
-- item, the rules for the reason text shown to the user, etc.) is unchanged from 057.
--
-- Background: for safety=fail, mapVerdictToStatus (moderate-post/index.ts:390-394) returns rejected
-- without looking at the ethos value, so in code layer 1 already takes priority.
-- What is added here is an explicit statement in the prompt text. It is a reminder so the AI does not
-- let "it is in a study / workout / self-improvement context" pull its analysis toward pass for
-- content that belongs to layer 1 (extreme fasting, etc.) (design doc #5-d).
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
-- §3. Do not show the rejection reason in preview_text of user notifications (#5-b)
-- ============================================================================
-- Current state (read before implementing): the message computed property in
-- NotificationListView.swift (4 kinds: contentRejected/contentFlagged/appealApproved/appealRejected)
-- always shows a fixed localized string looked up from kind, and never references the AI reason text
-- (notification.previewText). previewText is shown separately, as an extra line in quoted italics
-- "if non-empty" (NotificationListView.swift:212-219,
-- `if let preview = notification.previewText, !preview.isEmpty { ... }`), and
-- this was in effect exposing the AI safety_reason/ethos_reason to the user.
-- → If NULL is passed, this if branch is skipped and nothing is shown (the layout does not break).
-- This is not a "layout breaks on NULL" case, so there is no need to add a new fixed string.
--
-- Only the 2 kinds content_rejected/content_flagged are affected. appeal_approved/appeal_rejected
-- (resolve_user_appeal trigger, 039) keep passing resolution_note (text written for the user by the
-- operator/AI, including the user_note of #10) to preview_text. This is not "the AI's internal verdict
-- text" but "a result note written for the user", so it is not the kind of text #5-b is about.
-- The moderation_verdict column itself is not removed (the review room admin-appeals uses it to decide).
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
    -- 067 #5-b: do not pass the AI verdict text (safety_reason/ethos_reason) to preview_text.
    -- The client shows a fixed string based on kind, so NULL is fine (see the comment above).
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
-- Postgres refuses direct calls to functions that RETURNS trigger, so REVOKE/GRANT is not needed
-- (same as the original definition in 039). The trigger itself (WHEN clause, binding) is unchanged
-- from 039.

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
    -- 067 #5-b: same as above (same reason as the post side)
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
-- §4. Block Storage overwrites after approval (#6)
-- ============================================================================
-- Current state: post_images_owner_update (019_post_v2.sql:97-103) allows "overwrite at any time if it
-- is under your own uid folder". After approved, upserting a banned image to the same path leaves the
-- DB row (moderation_*) unchanged, so no re-review happens (the image is swapped while the approved
-- status stays).
--
-- The client writes to post-images from UserPostService.swift:280 (upload) with upsert:true, and the
-- normal flow is "Storage upload → user_posts INSERT" (retrying a failed upload needs UPDATE
-- permission, so the policy cannot be removed entirely, as designed in 019).
-- At upload time the matching user_posts row does not exist yet, so the helper below
-- always returns false (not locked = can overwrite). The existing normal flow behaves the same.
--
-- If an RLS policy references public.user_posts directly, it is evaluated with the calling user's
-- privileges, which makes the RLS interaction hard to read. Create one SECURITY DEFINER helper
-- function and call it from the policy (as the design doc says).
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

-- 067: this function can be called directly from the client, so always set REVOKE/GRANT
-- (FROM anon alone leaves the implicit PUBLIC grant in place. Lesson from 065)
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
-- WITH CHECK is omitted, as in the original definition in 019 (when an UPDATE policy has no WITH
-- CHECK, Postgres uses the USING clause to check the new row too, so the effect is the same).
--
-- The avatars bucket is out of scope (avatars are not moderated, as the design doc states. Do not touch).

-- ============================================================================
-- §5. Change the report threshold + separate it from ethos_enforce (#8)
-- ============================================================================
-- Current state: 042 sets moderation_status='flagged' at distinct reporter >= 3, and the feed
-- exclusion in 063:160-162 (the same pattern is in fetch_following_feed/fetch_tag_feed/search_posts/
-- fetch_comments_for_post/fetch_comments_for_quote/fetch_feed_extras) hides flagged only while
-- ethos_enforce=true. So report-based hiding is tied to ethos checks being on or off
-- (turning off ethos also disables reports).
--
-- Chosen approach: add a report_flagged boolean column to user_posts / user_comments to record
-- explicitly that the row "was flagged by the report threshold" (moderation_status itself still
-- stays 'flagged' = places that decide by status, such as the existing file_appeal / RLS, work
-- without changes. The "status IN ('rejected','flagged')" check in resolve_user_appeal, the
-- content_flagged notification in fetch_notifications, and the review room list all stay as they are).
-- The exclusion condition in every place is changed to
--   moderation_status <> 'flagged' OR (NOT report_flagged AND NOT ethos_enforce)
-- (the condition above). As a result:
--   - Over the report threshold (report_flagged=true) → always hidden, whatever ethos_enforce is
--   - Flagged only by layer 2 ethos (report_flagged=false) → follows ethos_enforce on/off as before
--     (meets the design doc requirement that reports always work even if ethos checks are turned
--     off in the future)
--
-- Why a separate column (why the alternative of putting a mark inside the verdict jsonb was not used):
--   - moderation_verdict already has a fixed meaning, "the AI verdict result" (039/052/
--     admin-appeals rely on it). Mixing in a different kind of information (from reports) makes
--     the meaning unclear
--   - As the comment in 042 says, "threshold flags often have no verdict, so it is NULL".
--     report_flagged must be set on its own even on paths with no AI verdict (reports only), and
--     a column is easier than a value inside jsonb to reference from both WHERE clauses and RLS policies
--   - The existing 6 places (feed etc.) repeat almost the same WHERE clause that only checks
--     "flagged and ethos_enforce", so adding the report_flagged column is the smallest diff

-- §5-1. Add the report_flagged column
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

-- §5-2. Prevent self-assignment / tampering: report_flagged is written by service_role only
-- user_posts_update_own / user_comments_update_own (RLS UPDATE policies) allow UPDATE of the whole
-- row, and body/image/moderation columns are protected by separate protect triggers. Without the same
-- pattern, the post author could change report_flagged directly with UPDATE
-- (set their own post back to report_flagged=false and remove the hiding).
-- Add report_flagged to the guarded columns of protect_user_posts_moderation /
-- protect_user_comments_moderation from 027 (treat it as a "service_role only column", like
-- moderation_status). This is CREATE OR REPLACE with the same signature, so the ACL and trigger
-- bindings are kept as they are.
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
        -- 067: lock report_flagged the same way as the moderation columns
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
-- The trigger itself (BEFORE UPDATE ... EXECUTE FUNCTION) was already created in 027, so
-- CREATE OR REPLACE of the function applies the new logic immediately (no need to recreate it).

-- §5-3. Prevent self-assignment on INSERT (add report_flagged := false to 066 lock_user_posts_insert /
-- lock_user_comments_insert). This is not required for abuse resistance (a new post has no report
-- history, so claiming report_flagged=true would only hide your own post, which only hurts yourself),
-- but it follows the policy of 066, which fixes the other self-assignable columns (moderation_status
-- etc.) to pending/false, and keeps "service_role only columns always have their default value, even
-- at INSERT".
CREATE OR REPLACE FUNCTION public.lock_user_posts_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    total_overlay_len integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;   -- service_role / SQL Editor / cron = backend operation (design doc §1)
    END IF;

    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    NEW.comment_count      := 0;
    NEW.view_count         := 0;
    -- 067: report_flagged cannot be self-assigned either (see the comment in §5-2)
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
        RETURN NEW;   -- service_role / SQL Editor / cron = backend operation
    END IF;

    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    -- 067: report_flagged cannot be self-assigned either
    NEW.report_flagged     := false;

    RETURN NEW;
END;
$$;
-- Both are RETURNS trigger functions that cannot be called directly, so REVOKE/GRANT is not needed
-- (same as 066). No need to recreate the triggers (066 already created them as BEFORE INSERT, and
-- CREATE OR REPLACE of the functions is enough to enable the new logic).

-- §5-4. Report threshold 3→5 + set report_flagged + allow rows that are already flagged to be re-evaluated
--
-- ⚠️ The original WHERE clause in 042 was `moderation_status IN ('approved', 'pending')`, which
-- excluded rows that were already 'flagged' from the UPDATE (the design at the time: "flagged is a
-- no-op"). That was harmless before the report_flagged concept existed, but left as is it becomes a
-- bug: "a post flagged earlier by layer 2 ethos never gets report_flagged, even when reports later
-- exceed 5" (because the UPDATE's WHERE clause skips it).
-- So the condition is changed to `moderation_status <> 'rejected'`, so the report threshold can be
-- applied from any of approved/pending/flagged (the original intent, not overwriting rejected out of
-- respect for the layer 1 AI verdict, is kept).
CREATE OR REPLACE FUNCTION public.flag_content_on_report_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- 067: 3 → 5 (user decision, design doc addendum #8)
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
    -- quote / user reports have no automatic handling (same as 042, handled manually by the operator)

    RETURN NEW;
END;
$$;
-- The trigger itself (AFTER INSERT ON user_reports) is unchanged from 042.

-- §5-5. Reset report_flagged when an appeal is approved
-- resolve_user_appeal (039) sets moderation_status back to 'approved' on approval, but if
-- report_flagged stays true, then when the item is flagged again later for a different reason
-- (layer 2 ethos only), it keeps an excessive treatment: "always hidden even though it is not from
-- reports". Approving an appeal is the operator/AI deciding "this post is fine", so it makes sense to
-- clear every mark, report_flagged included.
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
-- The trigger itself (AFTER UPDATE ... WHEN (...)) is unchanged from 039.

-- §5-6. Update the 6 feed/search/comment exclusion places to handle report_flagged
-- Targets are the 6 latest function definitions that have the same WHERE clause
-- "moderation_status <> 'flagged' OR NOT ethos_enforce" (older versions that were later overwritten
-- by a function with the same name are not touched):
--   fetch_mixed_feed_random  (latest = 063)
--   fetch_following_feed     (latest = 029)
--   fetch_tag_feed           (latest = 029)
--   search_posts             (latest = 032)
--   fetch_comments_for_post  (latest = 050)
--   fetch_comments_for_quote (latest = 037)
--   fetch_feed_extras        (latest = 037, only the comment_rows CTE applies. likers is out of scope
--     because user_likes has no moderation_status, so it was never relevant)
-- None of them change the RETURNS TABLE columns or the signature, so CREATE OR REPLACE is enough.
-- The bodies are copied word for word from the latest versions above, and only the one exclusion
-- block is rewritten.

-- ---- 5-6-1. fetch_mixed_feed_random (latest: 063_feed_seeded_shuffle.sql) ----
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

-- ---- 5-6-2. fetch_following_feed (latest: 029_recommend_feed.sql) ----
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

-- ---- 5-6-3. fetch_tag_feed (latest: 029_recommend_feed.sql) ----
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

-- ---- 5-6-4. search_posts (latest: 032_search_posts.sql) ----
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

-- ---- 5-6-5. fetch_comments_for_post (latest: 050_comment_owner_like.sql) ----
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

-- ---- 5-6-6. fetch_comments_for_quote (latest: 037_moderation_visibility_fixes.sql) ----
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

-- ---- 5-6-7. fetch_feed_extras (latest: 037_moderation_visibility_fixes.sql) ----
-- Only the comment_rows CTE is changed. liker_rows is not relevant because user_likes has no
-- moderation_status (unchanged since 037).
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

-- §5-7. Apply report_flagged to direct SELECT paths (RLS policies) such as the profile too
--
-- Current state: loadPosts(byUser:) in UserPostService.swift (another user's profile list) does not
-- go through an RPC and calls `.from("user_posts").select().eq("user_id", ...)` directly, so
-- visibility depends entirely on the RLS policy user_posts_select_all. The definition as of 037
-- (`auth.uid() = user_id OR moderation_status <> 'rejected'`) does not filter flagged at all
-- (always visible regardless of ethos_enforce). This is an existing gap on the profile side only,
-- separate from the feed-side design of "hide depending on ethos_enforce", and it is exactly what
-- this task (#8: make report-based hiding consistent on all exclusion paths) is about.
-- Here, as #8 requires, only "report-based (report_flagged) is always hidden" is added. The
-- pre-existing asymmetry, "ethos-based flagged posts (report_flagged=false) stay visible on the
-- profile, ignoring ethos_enforce", is intentionally left unchanged
-- (#8 asks only for consistency of report-based hiding. Applying ethos_enforce itself to profiles is
-- a separate discussion. This avoids widening the behavior beyond the requested scope. Details are in
-- the implementation report).
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
-- §6. Add 'off_topic' to the CHECK on user_reports.reason (#9)
-- ============================================================================
-- The CHECK at 006_b_moderation.sql:32 is still an unnamed constraint (auto-named by Postgres as
-- user_reports_reason_check) and has never been changed (confirmed with grep).
-- There was no report reason for ethos violations ("does not fit the purpose of this app"), so users
-- could only pick 'other' and write free text.
-- The threshold count treats it the same as the other reasons (flag_content_on_report_threshold in §5
-- decides only by the number of distinct reporters and does not look at reason, so no code change).
ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_reason_check;
ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_reason_check
    CHECK (reason IN ('spam', 'harassment', 'hate', 'nudity', 'violence', 'other', 'off_topic'));

COMMIT;

-- ============================================================================
-- Verification queries (run these after applying and check the results. Same format as 065/066)
-- ============================================================================

-- (A) Were the 7 new categories added to safety_rubric
-- SELECT safety_rubric LIKE '%自傷・自殺%' AND safety_rubric LIKE '%摂食障害%'
--        AND safety_rubric LIKE '%グロテスク%' AND safety_rubric LIKE '%危険行為%'
--        AND safety_rubric LIKE '%武器%' AND safety_rubric LIKE '%動物虐待%'
--        AND safety_rubric LIKE '%テロ%' AS all_7_present
-- FROM moderation_config;
-- Expected: true

-- (B) Was the "layer 1 first" sentence added to ethos_rubric
-- SELECT ethos_rubric LIKE '%層1優先の原則%' AS priority_note_present FROM moderation_config;
-- Expected: true

-- (C) Was the report_flagged column added, with existing rows filled with false
-- SELECT count(*) FILTER (WHERE report_flagged IS NULL) AS null_count,
--        count(*) FILTER (WHERE report_flagged = true)  AS true_count
-- FROM user_posts;
-- Expected: null_count = 0 (because of NOT NULL DEFAULT false)

-- (D) Is the report threshold trigger enabled + does it have permission to write report_flagged
-- SELECT tgrelid::regclass, tgname, tgenabled
-- FROM pg_trigger
-- WHERE tgname IN (
--     'user_reports_flag_threshold', 'user_posts_protect_moderation',
--     'user_comments_protect_moderation', 'user_posts_lock_insert', 'user_comments_lock_insert'
-- );
-- Expected: all tgenabled='O'

-- (E) Privileges of post_image_is_locked (only authenticated can execute?)
-- SELECT grantee, privilege_type FROM information_schema.role_routine_grants
-- WHERE routine_name = 'post_image_is_locked';
-- Expected: only one row, authenticated / EXECUTE (no PUBLIC/anon)

-- (F) Is off_topic accepted for user_reports.reason (example test with ROLLBACK so real data stays clean)
-- BEGIN; INSERT INTO user_reports (reporter_id, target_post_id, reason)
--   VALUES ('<your uid>', '<existing post_id>', 'off_topic'); ROLLBACK;

-- (G) Does report_flagged get set at 5 reports (manual test steps, no need to run)
-- 1. For some post_id, from 5 different accounts
--    INSERT INTO user_reports (reporter_id, target_post_id, reason) VALUES (..., '<post_id>', 'spam');
-- 2. SELECT moderation_status, report_flagged FROM user_posts WHERE id = '<post_id>';
--    → moderation_status='flagged', report_flagged=true
-- 3. UPDATE moderation_config SET ethos_enforce = false;
-- 4. SELECT * FROM fetch_mixed_feed_random(50) WHERE item_id = '<post_id>';
--    → 0 rows (must not appear even with ethos_enforce set to false, because it is report-based)
