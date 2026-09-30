-- ============================================================
-- 027_ai_moderation.sql
-- AI moderation (automatic review of posts/comments + AI triage of reports)
-- ============================================================
-- Design: Fable 5 / Implementation: Sonnet 5
-- Design doc: Docs/ai_moderation_design_2026_07_10.md (2-layer taxonomy / async webhook setup)
--
-- Purpose:
--   1. Add moderation_status to user_posts / user_comments. Right after posting it is
--      'pending' (shown in the feed immediately, does not block the UX), and an Edge Function
--      (moderate-post) asynchronously judges it with the Claude API and updates it to
--      'approved'/'flagged'/'rejected'.
--   2. Add the AI triage result (ai_severity 1-5 / ai_summary) to user_reports,
--      to lighten manual operation (checking status='pending' in SQL Editor).
--   3. Store the rubric text in moderation_config (one row only), so it can be tuned with
--      a single SQL UPDATE. While ethos_enforce=false, layer 2 (the 1% ethos) is
--      shadow judgment only (even if flagged it stays in the feed; it is only recorded).
--
-- Design decisions:
--   - Layer 1 (safety: violence/sexual/hate/harassment/spam/illegal) → rejected is hard hidden.
--     Leaving such content up costs more than false positives, so it is enforced from the start.
--   - Layer 2 (1% ethos: junk food / watching entertainment other than sports / people playing,
--     etc.) → shadow at first (even if flagged it stays visible; it is only recorded in
--     moderation_verdict).
--     flagged is also hidden only from the moment moderation_config.ethos_enforce is set to true.
--     No app update needed, switched with one UPDATE statement in SQL Editor (no logic change in the
--     Edge Function; the feed RPCs read the config each time).
--   - The 4 values of moderation_status: pending (waiting for review, stays visible) / approved
--     (passed) / flagged (layer 2 NG, shadow, stays visible) / rejected (layer 1 NG, hidden).
--   - The moderation columns cannot be written by the client. The protect trigger follows the
--     pg_roles.rolbypassrls check pattern (lesson from 014_b_comments_notifications.sql:
--     `current_setting('role') = 'service_role'` does not work because even inside SECURITY DEFINER
--     it stays the caller's role. The correct check is rolbypassrls: the SECURITY DEFINER owner
--     postgres and direct calls with the service_role key are bypassed so they pass, and a normal
--     user's direct authenticated UPDATE is rejected).
--   - moderation_config is RLS ON + no policies = always 0 rows from the client
--     (only service_role / postgres, the owner of SECURITY DEFINER functions, can read it).
--     The feed RPCs are SECURITY DEFINER, so they can read it without exposing anything to the
--     client.
--   - Existing posts/comments are not judged retroactively. Right after the column is added with
--     'pending' via ADD COLUMN, they are backfilled to 'approved' in bulk. So that a rerun does not
--     pull in new pending rows, the backfill is limited to "created_at before the time this migration
--     was applied" (see the cutoff constant below).
--
-- Execution order:
--   After 026 is done. Safe to run any number of times (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT
--   DO NOTHING pattern). Only the bulk UPDATE that backfills the 'pending' rows existing at that time
--   to 'approved' is limited to rows whose created_at is before the cutoff (the date this file was
--   applied, 2026-07-10), so it can be rerun safely.
-- ============================================================

-- ============================================================
-- 1. user_posts: moderation_status / moderation_verdict / moderated_at
-- ============================================================
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS moderation_status text NOT NULL DEFAULT 'pending';

ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS moderation_verdict jsonb;

ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS moderated_at timestamptz;

ALTER TABLE public.user_posts
    DROP CONSTRAINT IF EXISTS user_posts_moderation_status_check;

ALTER TABLE public.user_posts
    ADD CONSTRAINT user_posts_moderation_status_check
    CHECK (moderation_status IN ('pending', 'approved', 'flagged', 'rejected'));

COMMENT ON COLUMN public.user_posts.moderation_status IS
    'pending=判定待ち(表示継続) / approved=合格 / flagged=層2NG(shadow、表示継続) / rejected=層1NG(非表示)';
COMMENT ON COLUMN public.user_posts.moderation_verdict IS
    'Claude API 判定結果全文 (jsonb)。ルーブリックチューニングの学習データ';
COMMENT ON COLUMN public.user_posts.moderated_at IS 'AI 判定が完了した日時 (NULL=未判定)';

-- Existing posts are not judged retroactively: only rows that existed when this migration was first
-- applied are filled with 'approved'. Rows with created_at after the cutoff (= posted after this
-- migration) are real targets of the Edge Function's review, so a rerun does not touch them.
UPDATE public.user_posts
    SET moderation_status = 'approved'
    WHERE moderation_status = 'pending'
      AND created_at < '2026-07-10 00:00:00+00'::timestamptz;

-- ============================================================
-- 2. user_comments: the same 3 columns
-- ============================================================
ALTER TABLE public.user_comments
    ADD COLUMN IF NOT EXISTS moderation_status text NOT NULL DEFAULT 'pending';

ALTER TABLE public.user_comments
    ADD COLUMN IF NOT EXISTS moderation_verdict jsonb;

ALTER TABLE public.user_comments
    ADD COLUMN IF NOT EXISTS moderated_at timestamptz;

ALTER TABLE public.user_comments
    DROP CONSTRAINT IF EXISTS user_comments_moderation_status_check;

ALTER TABLE public.user_comments
    ADD CONSTRAINT user_comments_moderation_status_check
    CHECK (moderation_status IN ('pending', 'approved', 'flagged', 'rejected'));

COMMENT ON COLUMN public.user_comments.moderation_status IS
    'pending=判定待ち(表示継続) / approved=合格 / flagged=層2NG(shadow、表示継続) / rejected=層1NG(非表示)';
COMMENT ON COLUMN public.user_comments.moderation_verdict IS
    'Claude API 判定結果全文 (jsonb)。ルーブリックチューニングの学習データ';
COMMENT ON COLUMN public.user_comments.moderated_at IS 'AI 判定が完了した日時 (NULL=未判定)';

UPDATE public.user_comments
    SET moderation_status = 'approved'
    WHERE moderation_status = 'pending'
      AND created_at < '2026-07-10 00:00:00+00'::timestamptz;

-- ============================================================
-- 3. user_reports: AI triage columns
-- ============================================================
ALTER TABLE public.user_reports
    ADD COLUMN IF NOT EXISTS ai_severity integer;

ALTER TABLE public.user_reports
    ADD COLUMN IF NOT EXISTS ai_summary text;

ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_ai_severity_range;

ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_ai_severity_range
    CHECK (ai_severity IS NULL OR (ai_severity BETWEEN 1 AND 5));

COMMENT ON COLUMN public.user_reports.ai_severity IS
    'AI トリアージ優先度 1(低)-5(高)。運営は SQL Editor で ai_severity DESC に確認';
COMMENT ON COLUMN public.user_reports.ai_summary IS 'AI による通報内容の要約';

-- ============================================================
-- 4. moderation_config (one row only, stores the rubric text in the DB)
-- ============================================================
-- One-row constraint: make id a boolean PK and fix it to true with CHECK(id) (a common pattern for
-- single-row tables)
CREATE TABLE IF NOT EXISTS public.moderation_config (
    id             boolean PRIMARY KEY DEFAULT true,
    ethos_enforce  boolean NOT NULL DEFAULT false,
    safety_rubric  text NOT NULL,
    ethos_rubric   text NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT moderation_config_single_row CHECK (id)
);

COMMENT ON TABLE public.moderation_config IS
    'モデレーション設定 (1行のみ)。ethos_enforce=false は層2(1%エトス)をshadow判定のみに留める。ルーブリックのチューニングはUPDATE文1発 (SQL Editor)';
COMMENT ON COLUMN public.moderation_config.ethos_enforce IS
    'true にすると層2(1%エトス) flagged も rejected 同様にフィードから除外する。false の間は記録のみ (shadow mode)';

-- Auto-update updated_at (reuses the existing set_updated_at function)
DROP TRIGGER IF EXISTS moderation_config_set_updated_at ON public.moderation_config;
CREATE TRIGGER moderation_config_set_updated_at
    BEFORE UPDATE ON public.moderation_config
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- RLS: define no policies at all = always 0 rows from clients (anon/authenticated).
-- service_role (Edge Function) and postgres, the owner of SECURITY DEFINER functions, have
-- rolbypassrls=true, so they pass through RLS, and the feed RPCs can read it without problems.
ALTER TABLE public.moderation_config ENABLE ROW LEVEL SECURITY;

-- Insert the initial rubrics (Japanese version of the policy confirmed by the user, 2026-07-10)
INSERT INTO public.moderation_config (id, ethos_enforce, safety_rubric, ethos_rubric)
VALUES (
    true,
    false,
    $safety$
【層1: 安全性ルーブリック】
一般的な SNS の投稿基準に照らして判定してください。以下のいずれかに明確に該当する場合は fail としてください:
- 暴力: 実際の暴力行為・怪我・死体等の生々しい描写、暴力を扇動・賛美する内容
- 性的コンテンツ: 露骨な性的表現、児童の性的搾取(いかなる場合も即fail)、ヌード等
- ヘイトスピーチ: 人種・性別・性的指向・宗教・障害等に基づく差別的表現や中傷
- ハラスメント: 特定個人への誹謗中傷・晒し行為・つきまとい
- スパム: 無関係な宣伝、フィッシング、詐欺的リンク、大量重複投稿
- 違法行為: 違法薬物の売買・使用の助長、その他明確に違法な行為の描写や勧誘

誤爆コスト (合法な投稿を誤って弾くこと) より放置コスト (違反投稿を見逃すこと) の方が
高いドメインです。上記に明確に該当する場合のみ fail とし、判断に迷う場合は pass にせず
confidence を低くしてください (本文で理由を明記)。
$safety$,
    $ethos$
【層2: 「1%」エトス・ルーブリック】
このアプリ「1%」は自己改善・自己抑制をテーマにしたコミュニティです。投稿画像・テキストが
アプリの世界観(勉強・筋トレ・作業・自己改善)に沿っているかを判定してください。

弾く対象 (fail):
- 明らかなジャンクフード・お菓子 (スナック菓子、菓子パン、ファストフード等) の写真
- スポーツ以外のエンタメを視聴している様子 (ドラマ・お笑い番組・バラエティ・YouTube動画・
  映画を視聴中の画面や様子など)
- 遊んでいる姿 (ゲームをプレイしている様子、遊興・娯楽に興じている様子)

許可する対象 (pass):
- パスタ等の食事の写真 (境界的なもの含む。迷ったら許可する)
- スポーツ全般 (格闘技を含む) の実施・観戦
- 映画のポスターや俳優の写真等、モチベーション目的の引用・言及 (視聴中の様子ではなく
  静止画やポスター、名言の引用等)
- 勉強・筋トレ・作業・自己改善に関する内容全般

方針: 判断に迷う場合は必ず pass (許可) にしてください。false negative (本来弾くべきものを
見逃す) より false positive (許可すべきものを誤って弾く) の方がユーザー体験を大きく損ないます。
初期運用では ethos_enforce=false のため shadow 判定 (記録のみ、表示に影響しない) です。
$ethos$
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 5. Trigger that prevents tampering with the moderation columns (protect trigger)
-- ============================================================
-- rolbypassrls check pattern (follows the lesson from 014, does not use current_setting('role')):
--   - service_role (direct UPDATE from the Edge Function) and postgres, the owner of SECURITY DEFINER
--     functions, have rolbypassrls=true, so they pass
--   - A normal user's direct authenticated UPDATE is rejected for changes to the moderation columns

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
        OR NEW.moderated_at IS DISTINCT FROM OLD.moderated_at THEN
        RAISE EXCEPTION 'moderation columns are read-only for users (service_role only)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_protect_moderation ON public.user_posts;
CREATE TRIGGER user_posts_protect_moderation
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_moderation();

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
        OR NEW.moderated_at IS DISTINCT FROM OLD.moderated_at THEN
        RAISE EXCEPTION 'moderation columns are read-only for users (service_role only)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_protect_moderation ON public.user_comments;
CREATE TRIGGER user_comments_protect_moderation
    BEFORE UPDATE ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_comments_moderation();

-- Likewise, ai_severity / ai_summary in user_reports cannot be written by the client
-- (user_reports has had no UPDATE policy at all since 006 = the client could never UPDATE it.
--  Only UPDATEs from service_role are allowed because RLS with "no policy" only rejects
--  authenticated/anon, and rolbypassrls roles pass through RLS, so no extra trigger is needed)

-- ============================================================
-- 6. Add the moderation filter to the 3 feed RPCs
-- ============================================================
-- Base: the v4 definition in 021_post_carousel.sql (the version with image_count, the latest).
-- The return columns do not change, so CREATE OR REPLACE is enough (no DROP FUNCTION needed).
-- Filters added (user_posts only; quotes are official, so they are not covered):
--   - moderation_status <> 'rejected'  (layer 1 NG is always hidden)
--   - only while ethos_enforce=true, also exclude moderation_status = 'flagged'
--     (while false, flagged stays visible = shadow mode)

-- ---- 6-1. fetch_mixed_feed_random ----
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
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

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
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
        WHERE p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
          AND p.moderation_status <> 'rejected'
          AND (
            p.moderation_status <> 'flagged'
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ---- 6-2. fetch_following_feed ----
CREATE OR REPLACE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
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
        -- If the user follows "the official 1% account" (not "follows the author"), all official quotes are
        -- included (same as 020)
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ---- 6-3. fetch_tag_feed ----
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;
