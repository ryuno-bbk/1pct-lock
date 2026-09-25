-- ============================================================================
-- 066_cost_attack_hardening.sql
-- 第1弾: コスト攻撃を止める (2026-08-01)
-- ============================================================================
-- 設計: Fable 5 / 実装: Sonnet 5 / レビュー: Fable 5
-- 設計書: Docs/design_phase1_cost_attack_2026_08_01.md
-- 引き継ぎ: Docs/handoff_to_fable_2026_08_01.md #1〜#4
--
-- 背景:
--   試算では10万MAUでも Anthropic 費は月¥1.5〜4万で問題ない設計だが、それは
--   「1人が月2投稿」前提。以下が生きている限り悪意ある1人が10万人分の審査費を
--   1日で焼ける:
--     #1 moderation_status:'approved' の自己申告による審査バイパス (INSERT/UPDATE 両方)
--     #2 created_at 偽装によるレート制限無効化 + 削除→再投稿による枠復活
--     #3 user_reports / user_appeals の無制限発火 (どちらも通報/申し立て1件ごとに Sonnet が走る)
--     #4 overlays / user_reports.detail の無制限な長さによる AI 入力膨張
--   本ファイルはこの4点をまとめて塞ぐ。
--
-- ★最重要: 免除条件は auth.uid() IS NULL を使う (rolbypassrls は使わない)。
--   既存の 037 lock_user_reports_insert 等は rolbypassrls で免除しているが、
--   この方式を user_comments / user_appeals に流用すると無効化される。
--   create_comment (014) / file_appeal (039) はどちらも SECURITY DEFINER
--   (postgres 所有) なので、rolbypassrls 判定だと current_user が常に postgres に
--   化けて必ず「免除」に落ちる = 制限が丸ごと素通りする (046 の冒頭コメントが
--   同じ罠を記録している)。auth.uid() はセッションの JWT クレームを読むため、
--   SECURITY DEFINER の内側でも「実際に呼び出したユーザー」の ID が残る
--   (current_user と違って所有者に化けない)。SQL Editor / service_role からの
--   バックエンド操作は JWT クレームが無いため auth.uid() IS NULL になり、
--   自然に免除される (詳細は設計書 §1)。
--
-- DROP FUNCTION は使わない (既存関数はすべて CREATE OR REPLACE)。
--   DROP すると権限がリセットされる。063 で実際にこれが出荷ブロッカーを作った
--   (未認証で全投稿が読める状態になった。064 で修正)。
-- ============================================================================

BEGIN;

-- ============================================================================
-- §2-1. user_posts: BEFORE INSERT 列ガード (#1 審査バイパス + #2 created_at偽装 + 他人画像)
-- ============================================================================
-- 骨格は 037_moderation_visibility_fixes.sql の lock_user_reports_insert を流用。
-- UserPostService.swift:301-318 で確認済みの実際の INSERT 列 (id, user_id, title,
-- tags, image_path, image_count, overlays) だけを送ってくる経路にとっては、
-- ここで固定する列 (created_at/moderation_*/各カウンタ) はそもそも送られてこない
-- ので完全な no-op。挙動は変わらない。
--
-- ⚠️トリガー名 user_posts_lock_insert は user_posts_rate_limit より辞書順で前
-- ('l' < 'r')。PostgreSQL の BEFORE トリガーは名前の辞書順に発火するため、
-- レート制限 (§3-3、rate_events 台帳を読む) より先に列固定が走る。
-- (台帳方式への切替後は created_at 偽装によるレート制限回避そのものは成立しなく
-- なっているが、created_at は「未来日付でフィード先頭に固定する」別の攻撃にも
-- 使えるため、列固定は独立して必要。名前の順序も設計書の指示どおり維持する)
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

    -- #1 + #2: moderation列・カウンタ列・created_at の自己申告/偽装を禁止。
    -- クライアントはそもそもこれらを送らないため、正規経路には影響しない。
    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    NEW.comment_count      := 0;
    NEW.view_count         := 0;

    -- 他人の画像を自分の投稿として掲載する経路を塞ぐ。NEW.user_id を信用してよい
    -- 根拠 = INSERT ポリシー (005_b_user_posts.sql:95-97) が auth.uid() = user_id を
    -- 既に強制している。
    IF NEW.image_path IS NOT NULL
       AND NEW.image_path NOT LIKE (NEW.user_id::text || '/%') THEN
        RAISE EXCEPTION 'image_path must be under your own folder';
    END IF;

    -- §4-1: overlays の長さ上限。合計文字数の算出に jsonb_array_elements (副問い合わせ)
    -- が要るため CHECK 制約では書けず、ここでトリガーとして検証する。
    -- UPDATE 側は 037 protect_user_posts_content (本ファイル §2-3 で拡張) が overlays の
    -- 変更そのものを丸ごと禁止しているため、INSERT 時点のここだけで実質的に全経路をカバーする。
    IF NEW.overlays IS NOT NULL THEN
        IF jsonb_array_length(NEW.overlays) > 30 THEN
            RAISE EXCEPTION 'overlays too long (max 30 elements)';
        END IF;

        SELECT COALESCE(sum(char_length(elem ->> 'text')), 0) INTO total_overlay_len
        FROM jsonb_array_elements(NEW.overlays) AS elem;

        -- クライアントは1件120文字に制限済み (StoryTextEditorView.swift:367)。
        -- 30要素 × 120文字 = 3,600 に余裕を見て 3,000 とする (設計書 §4-1)。
        IF total_overlay_len > 3000 THEN
            RAISE EXCEPTION 'overlays text too long (max 3000 chars total)';
        END IF;
    END IF;

    -- §4-1: tags の各要素 30 文字まで (cardinality<=3 は 005 で CHECK 済み、要素自体は無制限だった)
    IF NEW.tags IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM unnest(NEW.tags) AS t WHERE char_length(t) > 30) THEN
            RAISE EXCEPTION 'tag too long (max 30 chars per tag)';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- RETURNS trigger の関数は Postgres がトリガー以外からの直接呼び出しを拒否するため
-- (039_moderation_notifications_appeals.sql の notify_on_post_moderation 等と同じ),
-- REVOKE/GRANT は不要 (絶対に守ることの#3は「クライアントから直接実行できる関数」向けの
-- ルールであり、trigger 関数はその経路が構造的に存在しない)。
DROP TRIGGER IF EXISTS user_posts_lock_insert ON public.user_posts;
CREATE TRIGGER user_posts_lock_insert
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_user_posts_insert();

-- ============================================================================
-- §2-2. user_comments: BEFORE INSERT 列ガード
-- ============================================================================
-- create_comment RPC (014_b_comments_notifications.sql:545) の INSERT は
-- post_id/quote_id, author_user_id, parent_comment_id, text の4列のみで、
-- created_at/moderation_*/like_count のいずれも送っていない。ここで固定する列は
-- 正規経路にとって完全な no-op。
-- ⚠️ user_comments は create_comment RPC (SECURITY DEFINER, postgres所有) だけでなく
-- RLS の user_comments_insert_own ポリシー (auth.uid() = author_user_id のみ検証) 経由で
-- クライアントが直接 INSERT することも可能なため、RPC を経由しない偽装 INSERT
-- (moderation_status='approved' や like_count 水増しの自己申告) もここで塞ぐ。
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

    RETURN NEW;
END;
$$;

-- トリガー名は user_comments_rate_limit より辞書順で前 ('l' < 'r')。posts側と同じ理由。
DROP TRIGGER IF EXISTS user_comments_lock_insert ON public.user_comments;
CREATE TRIGGER user_comments_lock_insert
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_user_comments_insert();

-- ============================================================================
-- §2-3. protect_user_posts_content (037): 比較列に created_at / user_id を追加
-- ============================================================================
-- 037_moderation_visibility_fixes.sql:69-92 は本文相当8列 (text_jp/text_en/title/
-- image_path/overlays/image_count/tags/background_id) しか凍結しておらず、
-- created_at は UPDATE で書き換え可能だった (「投稿 → UPDATE で created_at を過去に
-- する」で §2-1 の INSERT ガードを迂回できてしまう)。既存の8列は一切変更せず、
-- created_at と user_id の2列だけを追加する。
--
-- ⚠️判断: 免除条件はここでは rolbypassrls のまま変更していない (auth.uid() IS NULL
-- に統一しなかった)。理由:
--   1. この関数は UPDATE 専用のイミュータブル化ガードであり、§1 が問題にしている
--      「SECURITY DEFINER RPC 経由の INSERT が rolbypassrls で素通りする」パターン
--      とは性質が異なる (対象は UPDATE で、かつ現状これらの列を書き換える
--      SECURITY DEFINER 経路は存在しない = 037 時点から undefined behavior のリスクなし)。
--   2. 037 は本番稼働済みのトリガーであり、免除方式まで変更すると影響範囲が
--      本タスクの依頼スコープ (2列追加) を超える。最小差分を優先した。
--   → レビュー時にこの判断の妥当性を確認してほしい。
CREATE OR REPLACE FUNCTION public.protect_user_posts_content()
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
    IF NEW.text_jp IS DISTINCT FROM OLD.text_jp
        OR NEW.text_en IS DISTINCT FROM OLD.text_en
        OR NEW.title IS DISTINCT FROM OLD.title
        OR NEW.image_path IS DISTINCT FROM OLD.image_path
        OR NEW.overlays IS DISTINCT FROM OLD.overlays
        OR NEW.image_count IS DISTINCT FROM OLD.image_count
        OR NEW.tags IS DISTINCT FROM OLD.tags
        OR NEW.background_id IS DISTINCT FROM OLD.background_id
        -- 066 追加分: created_at 偽装 (#2 の UPDATE 経路) と user_id 付け替えの凍結
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
        OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'post content is immutable after creation (no edit feature exists)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_protect_content ON public.user_posts;
CREATE TRIGGER user_posts_protect_content
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_content();

-- ============================================================================
-- §3-1. rate_events: 追記専用の台帳テーブル (#2 削除→再投稿での枠復活を防ぐ)
-- ============================================================================
-- 現在の enforce_post_rate_limit (057) は user_posts の現存行を数えているため、
-- 投稿→削除→再投稿で枠が復活する。台帳は投稿が消えても残るのでこれが成立しなくなる。
--
-- 却下した代替案 (設計書 §3):
--   - ソフトデリート化: 影響範囲が巨大 (全フィードRPC/プロフィール/カウンタ/削除UX)
--   - users への累積カウンタ列: ローリング24hウィンドウを1列で表現できない
--   - pg_cron 定期purge: 拡張の有効化が要る。下記の自己purgeで足りる
CREATE TABLE IF NOT EXISTS public.rate_events (
    id         bigserial PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('post', 'comment', 'report', 'appeal')),
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.rate_events IS
    'レート制限用の追記専用台帳。post/comment/report/appeal の各 INSERT ごとに1行追加。'
    '対象コンテンツを削除しても行は残るため「削除→再投稿」で枠が戻らない。'
    '48時間より古い自分の行は各レート制限トリガーが呼び出しのついでに自己purgeする (cron不要)';

CREATE INDEX IF NOT EXISTS idx_rate_events_user_kind_created
    ON public.rate_events (user_id, kind, created_at DESC);

ALTER TABLE public.rate_events ENABLE ROW LEVEL SECURITY;
-- ポリシーを1つも作らない = authenticated/anon は読み書き不可 (default deny)。
-- 書き込むのは SECURITY DEFINER のトリガー関数 (postgres所有) のみ。
--
-- ⚠️ REVOKE ALL の対象に authenticated も含める (anon だけでは不十分)。
-- 065_close_anon_access.sql §3 の `ALTER DEFAULT PRIVILEGES ... REVOKE ALL ON TABLES
-- FROM anon` は anon 分しか対応していないため、このファイルより後に作る新規テーブルは
-- authenticated への Supabase 既定付与 (SELECT〜DELETE) がそのまま残る。
REVOKE ALL ON TABLE public.rate_events FROM anon, authenticated;

-- ============================================================================
-- §3-3. enforce_post_rate_limit / enforce_comment_rate_limit: 台帳参照に差し替え
-- ============================================================================
-- DROP FUNCTION はしない (CREATE OR REPLACE のみ)。シグネチャ不変なので既存の
-- トリガー紐付け・権限は保持されるが、046/065 に倣い DROP TRIGGER→CREATE TRIGGER も
-- 念のため再掲する。

-- ---- 投稿: 5件/24h (057 の現行値を維持) ----
CREATE OR REPLACE FUNCTION public.enforce_post_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- 066: 運営のバックエンド操作 (SQL Editor 等) は免除。auth.uid() はセッションの
    -- JWTクレームを読むため、この関数が SECURITY DEFINER でも実際の呼び出しユーザーの
    -- IDが残る (rolbypassrls は使わない。理由は本ファイル冒頭 / 設計書 §1)。
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    -- 066: 現存行ではなく台帳 (rate_events) でカウントする。投稿を削除しても
    -- 台帳の行は残るため「削除→再投稿」で枠が復活しない。
    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.user_id
      AND kind = 'post'
      AND created_at > now() - interval '24 hours';

    -- 057: 100 → 10 → 5 (AI判定コストの1人あたり天井、ユーザー判断 2026-07-30)
    IF recent_count >= 5 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.user_id, 'post');

    -- 066 §3-2: 自己purge。48時間より古い自分の行を削除する (cron不要、1回あたりの
    -- 仕事量が有界でテーブルが無限に育たない)。kind を絞らず全種まとめて掃除する
    -- (設計書 §3-2 のとおり)。
    DELETE FROM public.rate_events
     WHERE user_id = NEW.user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- ---- コメント: 300件/24h (046 の現行値を維持) ----
CREATE OR REPLACE FUNCTION public.enforce_comment_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- 066: 046 は「rolbypassrls 免除を入れると create_comment (SECURITY DEFINER,
    -- postgres所有) 経由の投稿が丸ごと素通りする」という理由でロール免除を一切
    -- 設けなかった。auth.uid() はセッションのJWTクレームを読むため SECURITY DEFINER
    -- の内側でも実際の呼び出しユーザーのIDが残り、この罠を踏まない (設計書 §1)。
    -- これにより 046 が運用回避策として書いていた「シード時は DISABLE TRIGGER」も
    -- 不要になる (SQL Editor = auth.uid() IS NULL が自然に免除される)。
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    -- user_comments の著者列は author_user_id (014 SQL。user_id ではない)
    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.author_user_id
      AND kind = 'comment'
      AND created_at > now() - interval '24 hours';

    IF recent_count >= 300 THEN
        RAISE EXCEPTION 'daily comment limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.author_user_id, 'comment');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.author_user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_rate_limit ON public.user_comments;
CREATE TRIGGER user_comments_rate_limit
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_comment_rate_limit();

-- ============================================================================
-- §3-3. user_reports / user_appeals: レート制限トリガーを新設 (#3)
-- ============================================================================
-- 通報1件ごと・申し立て1件ごとに Sonnet が走るのに上限が無かった。
-- 上限値はユーザー確認事項 (設計書 §7): 通報20/24h・申し立て10/24h。

-- ---- 通報: 20件/24h ----
-- user_reports への INSERT は RLS ポリシー user_reports_insert_own 経由のクライアント
-- 直INSERT (006_b_moderation.sql:70-73)。SECURITY DEFINER RPC は介在しないが、
-- rate_events への書き込みには昇格権限が要るためこの関数自体は SECURITY DEFINER にする
-- (046/057 の enforce_*_rate_limit と同じ構造)。
CREATE OR REPLACE FUNCTION public.enforce_report_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.reporter_id
      AND kind = 'report'
      AND created_at > now() - interval '24 hours';

    -- 20/24h: 通報のたびに moderate-post が Sonnet を走らせる (index.ts:615)。
    -- 正当な利用で1日20件を超えるのは考えにくく、集団通報による検閲攻撃の緩和にもなる。
    IF recent_count >= 20 THEN
        RAISE EXCEPTION 'daily report limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.reporter_id, 'report');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.reporter_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

-- BEFORE INSERT トリガーは既に user_reports_lock_insert (037) が存在する。
-- 名前順 ('l' < 'r') で lock_insert → rate_limit の順に発火するが、rate_limit 側は
-- NEW.reporter_id と rate_events しか見ないため実害のある順序依存はない。
DROP TRIGGER IF EXISTS user_reports_rate_limit ON public.user_reports;
CREATE TRIGGER user_reports_rate_limit
    BEFORE INSERT ON public.user_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_report_rate_limit();

-- ---- 申し立て: 10件/24h ----
-- user_appeals への INSERT は file_appeal RPC (039、SECURITY DEFINER, postgres所有)
-- 経由のみ (直接 INSERT はポリシー未定義で拒否される)。ここでも auth.uid() IS NULL
-- 判定でなければ免除に落ちる (rolbypassrls だと file_appeal の所有者 postgres が
-- 常に bypass=true になり、レート制限が丸ごと素通りする)。
CREATE OR REPLACE FUNCTION public.enforce_appeal_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.user_id
      AND kind = 'appeal'
      AND created_at > now() - interval '24 hours';

    -- 10/24h: 申し立てのたびに review-appeal が Sonnet を走らせる。1対象1件制限
    -- (user_appeals_unique_post/comment、039) があるため実質上限は低いが、
    -- 対象を量産すれば回せてしまうためこちらも独立に制限する。
    IF recent_count >= 10 THEN
        RAISE EXCEPTION 'daily appeal limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.user_id, 'appeal');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_appeals_rate_limit ON public.user_appeals;
CREATE TRIGGER user_appeals_rate_limit
    BEFORE INSERT ON public.user_appeals
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_appeal_rate_limit();

-- ============================================================================
-- §4-1. 長さ上限 (単純な text 列は CHECK 制約で): user_appeals.reason / user_reports.detail
-- ============================================================================
ALTER TABLE public.user_appeals
    DROP CONSTRAINT IF EXISTS user_appeals_reason_length;
ALTER TABLE public.user_appeals
    ADD CONSTRAINT user_appeals_reason_length CHECK (char_length(reason) <= 1000);

ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_detail_length;
ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_detail_length CHECK (detail IS NULL OR char_length(detail) <= 1000);

-- file_appeal RPC (039) にも同じ検証を足す (設計書 §4-1: 「file_appeal 側にも同じ
-- 検証を足す」)。CHECK 制約は INSERT 時に自然に効くが、RPC 側で早期に弾いた方が
-- エラーメッセージがクライアントにとって分かりやすい。ロジック本体・シグネチャ・
-- REVOKE/GRANT は 039 定義から変更しない (長さチェック1行の追加のみ)。
CREATE OR REPLACE FUNCTION public.file_appeal(
    p_target_post_id    uuid,
    p_target_comment_id uuid,
    p_reason            text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_appeal_id uuid;
    v_owner_id  uuid;
    v_status    text;
BEGIN
    IF (p_target_post_id IS NOT NULL) = (p_target_comment_id IS NOT NULL) THEN
        RAISE EXCEPTION 'exactly one of target_post_id / target_comment_id required';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'reason is required';
    END IF;
    -- 066 追加: user_appeals_reason_length CHECK と同じ上限をここでも検証する
    IF char_length(p_reason) > 1000 THEN
        RAISE EXCEPTION 'reason too long (max 1000 chars)';
    END IF;

    IF p_target_post_id IS NOT NULL THEN
        SELECT user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_posts WHERE id = p_target_post_id;
    ELSE
        SELECT author_user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_comments WHERE id = p_target_comment_id;
    END IF;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'target not found';
    END IF;
    IF v_owner_id <> auth.uid() THEN
        RAISE EXCEPTION 'not your content';
    END IF;
    IF v_status NOT IN ('rejected', 'flagged') THEN
        RAISE EXCEPTION 'only rejected/flagged content can be appealed';
    END IF;

    INSERT INTO public.user_appeals (user_id, target_post_id, target_comment_id, reason)
    VALUES (auth.uid(), p_target_post_id, p_target_comment_id, p_reason)
    RETURNING id INTO v_appeal_id;

    RETURN v_appeal_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'already appealed';
END;
$$;

COMMENT ON FUNCTION public.file_appeal(uuid, uuid, text) IS
    '投稿/コメント (post_id / comment_id のどちらか一方) の異議申し立てを送信。'
    '本人所有かつ moderation_status が rejected/flagged の場合のみ受理。1対象1件まで。'
    '066: reason は1000文字まで (user_appeals_reason_length CHECK と二重検証)';

-- シグネチャは 039 から不変だが、念のため再掲 (039 の file_appeal 自体の記述と同じ方針)
REVOKE EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) TO authenticated;

COMMIT;

-- ============================================================================
-- §5-4. 検証クエリ (適用後にこれを流して結果を確認する。065 と同じ形式)
-- ============================================================================

-- (A) 新規/変更したトリガーが存在し有効 (tgenabled='O') か
SELECT tgrelid::regclass AS table_name, tgname, tgenabled
FROM pg_trigger
WHERE tgname IN (
    'user_posts_lock_insert', 'user_posts_protect_content', 'user_posts_rate_limit',
    'user_comments_lock_insert', 'user_comments_rate_limit',
    'user_reports_lock_insert', 'user_reports_rate_limit',
    'user_appeals_rate_limit'
)
ORDER BY table_name, tgname;
-- 期待値: 8行、すべて tgenabled = 'O' (有効)。'D' が混ざっていたら要調査。

-- (B) BEFORE トリガーの発火順 (lock_insert / rate_limit の辞書順を目視確認)
SELECT tgrelid::regclass AS table_name, tgname
FROM pg_trigger
WHERE tgrelid IN ('public.user_posts'::regclass, 'public.user_comments'::regclass)
  AND NOT tgisinternal
ORDER BY table_name, tgname;
-- 期待値: 各テーブルで *_lock_insert が *_rate_limit より前の行に来ること

-- (C) rate_events に anon/authenticated の権限が残っていないか
SELECT table_name, grantee,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'rate_events'
  AND grantee IN ('anon', 'authenticated')
GROUP BY table_name, grantee;
-- 期待値: 0行 (anon/authenticated どちらも rate_events に触れないこと)
