-- ============================================================
-- 027_ai_moderation.sql
-- AI モデレーション (投稿/コメントの自動判定 + 通報AIトリアージ)
-- ============================================================
-- 設計: Fable 5 / 実装: Sonnet 5
-- 設計書: Docs/ai_moderation_design_2026_07_10.md (2層タクソノミー/非同期webhook構成)
--
-- 目的:
--   1. user_posts / user_comments に moderation_status を追加し、投稿直後は
--      'pending' (フィードには即時表示、UXを止めない)、Edge Function
--      (moderate-post) が非同期で Claude API 判定し 'approved'/'flagged'/'rejected'
--      に更新する。
--   2. user_reports に AI トリアージ結果 (ai_severity 1-5 / ai_summary) を追加し、
--      手動運用 (SQL Editor で status='pending' を確認) を軽くする。
--   3. moderation_config (1行のみ) にルーブリック本文を保管し、SQL の UPDATE 1発で
--      チューニングできるようにする。ethos_enforce=false の間は層2 (1%エトス) は
--      シャドウ判定のみ (flagged でもフィード表示は継続、記録だけ行う)。
--
-- 設計判断:
--   - 層1 (安全性: 暴力/性的/ヘイト/ハラスメント/スパム/違法) → rejected はハード非表示。
--     誤爆コストより放置コストが高いため、初期から enforce。
--   - 層2 (1%エトス: ジャンクフード/スポーツ以外のエンタメ視聴/遊んでいる様子 等) →
--     初期は shadow (flagged でも表示継続、moderation_verdict に記録するだけ)。
--     moderation_config.ethos_enforce を true にした瞬間だけ flagged も非表示化する。
--     アプリ更新不要、SQL Editor の UPDATE 1文で切替 (Edge Function 側のロジック変更不要、
--     フィード RPC 側で config を都度参照する)。
--   - moderation_status の 4 値: pending (判定待ち、表示継続) / approved (合格) /
--     flagged (層2 NG、shadow 表示継続) / rejected (層1 NG、非表示)。
--   - moderation 列はクライアントから書けない。protect trigger は pg_roles.rolbypassrls
--     判定パターンを踏襲 (014_b_comments_notifications.sql の教訓:
--     `current_setting('role') = 'service_role'` は SECURITY DEFINER 内でも呼び出し元の
--     role のままなので機能しない。正しくは rolbypassrls — SECURITY DEFINER の所有者
--     postgres と service_role キーで直接叩く場合は bypass されるので通り、一般ユーザーの
--     authenticated 直 UPDATE は拒否される)。
--   - moderation_config は RLS ON + ポリシー無し = クライアントからは常に 0 行
--     (service_role / SECURITY DEFINER 関数の所有者 postgres のみ読める)。
--     フィード RPC は SECURITY DEFINER なので、クライアントに一切公開せずに参照できる。
--   - 既存投稿/コメントは遡及判定しない。'pending' で ADD COLUMN された直後に
--     'approved' へ一括バックフィルする。再実行しても新規の pending 行を巻き込まない
--     よう、バックフィルは「このマイグレーション適用時点より前の created_at」に限定する
--     (下記 cutoff 定数を参照)。
--
-- 実行順序:
--   026 完了後。何度実行しても安全 (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT
--   DO NOTHING パターン)。ただし当時点で存在する 'pending' 行を 'approved' に
--   バックフィルする一括 UPDATE のみ、cutoff (このファイルの適用日 2026-07-10) より
--   created_at が前の行に限定して安全に再実行可能にしてある。
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

-- 既存投稿の遡及判定は行わない: この移行を最初に適用した時点で存在する行のみ
-- 'approved' で埋める。cutoff より後の created_at (= この移行より後に投稿された行) は
-- 実際に Edge Function の判定対象なので、再実行時に触らない。
UPDATE public.user_posts
    SET moderation_status = 'approved'
    WHERE moderation_status = 'pending'
      AND created_at < '2026-07-10 00:00:00+00'::timestamptz;

-- ============================================================
-- 2. user_comments: 同 3 列
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
-- 3. user_reports: AI トリアージ列
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
-- 4. moderation_config (1行のみ、ルーブリック本文をDBに保管)
-- ============================================================
-- 1行制約: id を boolean PK にして CHECK(id) で true 固定 (よくある単一行テーブルの型)
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

-- updated_at 自動更新 (既存 set_updated_at 関数を再利用)
DROP TRIGGER IF EXISTS moderation_config_set_updated_at ON public.moderation_config;
CREATE TRIGGER moderation_config_set_updated_at
    BEFORE UPDATE ON public.moderation_config
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- RLS: ポリシーを一切定義しない = クライアント(anon/authenticated)からは常に0行。
-- service_role (Edge Function) と SECURITY DEFINER 関数の所有者 postgres は
-- rolbypassrls=true のため RLS を素通りし、フィード RPC からは問題なく参照できる。
ALTER TABLE public.moderation_config ENABLE ROW LEVEL SECURITY;

-- 初期ルーブリック投入 (ユーザー確定ポリシーの日本語化、2026-07-10)
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
-- 5. moderation 列の改ざん防止 trigger (protect trigger)
-- ============================================================
-- rolbypassrls 判定パターン (014 の教訓を踏襲、current_setting('role') は使わない):
--   - service_role (Edge Function の直接 UPDATE) と SECURITY DEFINER 関数所有者 postgres は
--     rolbypassrls=true のため通す
--   - 一般ユーザーの authenticated 直 UPDATE は moderation 列の変更を拒否

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

-- user_reports の ai_severity / ai_summary も同様にクライアントから書けないようにする
-- (user_reports は 006 で UPDATE ポリシー自体が存在しない = クライアントは元々 UPDATE 不可。
--  service_role からの UPDATE のみ許可されるのは RLS が「ポリシー無し」で拒否する対象は
--  authenticated/anon のみで、rolbypassrls ロールは RLS を素通りするため追加の trigger は不要)

-- ============================================================
-- 6. フィード RPC 3 本にモデレーションフィルタを追加
-- ============================================================
-- ベース: 021_post_carousel.sql の v4 定義 (image_count 追加版、最新)。
-- 戻り値の列は変更しないため CREATE OR REPLACE で足りる (DROP FUNCTION 不要)。
-- 追加するフィルタ (user_posts 側のみ、quotes は公式なので対象外):
--   - moderation_status <> 'rejected'  (層1 NG は常に非表示)
--   - ethos_enforce=true の間だけ moderation_status = 'flagged' も除外
--     (false の間は flagged も表示継続 = shadow mode)

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
        -- 「著者をフォロー」ではなく「1% 公式アカウントをフォロー」していれば全公式名言が対象 (020 と同じ)
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
