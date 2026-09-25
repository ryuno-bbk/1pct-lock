-- ============================================================
-- 052_feed_author_cap_appeal_ai_review.sql
-- フィード多様性 + 投稿上限引き下げ + 申し立てAI再審査の下地 (2026-07-29)
-- ============================================================
-- 背景 (ユーザー起票 2026-07-29):
--   1. おすすめフィードは author 多様性の制御が無く、1人が連投すると limit 50 の
--      大半を占有できる (投稿母数が少ない今は特に顕著)。TikTok 等の「連投が伸びない」
--      挙動の実体はランキング側の per-author キャップ。
--   2. 投稿上限 100/24h (046) は荒らし対策の位置づけだったが、AI モデレーションの
--      コスト天井としては高すぎる (100件×0.7〜1.4円 = 最大140円/日/人)。
--      10/24h へ引き下げ (BeReal=1〜2本/日、IG平均<1本/日。実ユーザーには見えない天井)。
--      クライアント文言は 046 の時点で数字を含まないため変更不要。
--   3. review-appeal Edge Function (申し立てAI再審査) が所見を書き込む ai_review 列を追加。
--
-- 適用: Supabase Dashboard → SQL Editor で本ファイル全文を実行 (ユーザー作業)。
-- 冪等: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS のみ。何度実行しても安全。
-- ロールバック: author_cap を 999 にして再実行すればキャップ実質無効化。
--   投稿上限を戻す場合は 10 を 100 に書き換えて再実行。
-- ============================================================

-- ============================================================
-- 1. fetch_mixed_feed_random: per-author キャップ追加
-- ============================================================
-- 041 の全文をベースに、posts のみ「同一投稿者は1回のフィードで最大 author_cap 件」を
-- 追加 (row_number() で score 上位のみ残す)。quotes (公式名言) は偉人ごとに author が
-- 異なりキュレーション済みのため対象外。
-- ⚠️ RETURNS TABLE の列は 029/041 から増減していない (M33 の教訓どおり列変更は
--    DROP→再作成が必要になるため、キャップは WHERE 句の追加のみで実現)

CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
    WITH params AS (
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ランダムジッターの最大値 (探索性)
            0.8  ::double precision AS quote_base,         -- 名言の固定ベース点 (新しさ減衰の代替)
            2    ::integer          AS author_cap          -- 052: 1フィードあたり同一投稿者の最大件数 (postsのみ)
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
                + random() * p.w_jitter
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
                + random() * p.w_jitter
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
          AND up.created_at > now() - interval '30 days'
    ),
    ranked AS (
        -- 052: 同一投稿者の連投キャップ。score 上位 author_cap 件だけ残す (postsのみ)。
        -- jitter が random() なため毎回のフィードで「どの2件が残るか」も入れ替わる
        SELECT s.*,
               row_number() OVER (PARTITION BY s.kind, s.author_id ORDER BY s.score DESC) AS author_rank
        FROM scored s
    )
    SELECT
        r.kind, r.item_id, r.body_jp, r.body_en, r.tags, r.like_count, r.comment_count, r.created_at,
        r.author_id, r.author_name, r.author_avatar_url, r.is_official_author, r.is_pro_author,
        r.background_id, r.title, r.image_path, r.image_count
    FROM ranked r
    CROSS JOIN params p
    WHERE r.kind = 'quote' OR r.author_rank <= p.author_cap
    ORDER BY r.score DESC
    LIMIT limit_count;
$$;

COMMENT ON FUNCTION public.fetch_mixed_feed_random(integer) IS
    'おすすめフィード (名言+投稿の混合、スコアリング+ジッター)。'
    '052: 同一投稿者は1フィードあたり author_cap 件まで (params CTE で調整可)';

-- ============================================================
-- 2. 投稿レート制限 100 → 10 / 24h
-- ============================================================
-- コメント側 (enforce_comment_rate_limit, 300/24h) は変更しない。
-- クライアント文言は数字を含まないため変更不要 (046 で撤去済み)

CREATE OR REPLACE FUNCTION public.enforce_post_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    SELECT count(*) INTO recent_count
    FROM public.user_posts
    WHERE user_id = NEW.user_id
      AND created_at > now() - interval '24 hours';
    -- 052: 100 → 10 (AI判定コストの1人あたり天井。最大 140円/日 → 14円/日)
    IF recent_count >= 10 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;
    RETURN NEW;
END;
$$;

-- トリガー自体は 046 で作成済み (関数の CREATE OR REPLACE だけで反映される)。
-- 046 未適用環境でも壊れないよう IF NOT EXISTS 相当の再作成を添える
DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- ============================================================
-- 3. user_appeals.ai_review (申し立てAI再審査の所見)
-- ============================================================
-- review-appeal Edge Function (service_role) が書き込む:
--   { analysis, overturn, user_note, model, reviewed_at }
-- overturn=true の場合は同 Function が status='approved' へ更新し、既存の
-- user_appeals_resolve トリガー (039) が投稿復活+appeal_approved 通知まで面倒を見る。
-- overturn=false は status='pending' のまま = 人間 (運営) の最終裁定キューに残る。
-- 運営キューの SQL (Docs/moderation_ops_guide.md) では ai_review->>'analysis' が
-- 二次所見として読める。RLS: SELECT ポリシーは本人のみ (039) のまま —
-- ai_review はクライアント UI では使わないが、本人が読めても差し支えない内容
-- (analysis の内部用語は本人向け文言ではないが機密ではない。043 の許容判断と同じ)

ALTER TABLE public.user_appeals
    ADD COLUMN IF NOT EXISTS ai_review jsonb;

COMMENT ON COLUMN public.user_appeals.ai_review IS
    'review-appeal Edge Function のAI二次審査所見 { analysis, overturn, user_note, model, reviewed_at }。'
    'NULL = 未審査。overturn=false でも status は pending のまま (人間の最終裁定待ち)';
