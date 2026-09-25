-- ============================================================
-- 062_quote_feed_deprioritize.sql
-- 公式名言がユーザー投稿を埋もれさせない (2026-07-31 ユーザー起票)
-- ============================================================
-- 背景: 名言の点数は固定 quote_base=0.8 で減衰なし・既読ペナルティなし・キャップなし。
--   新規投稿 (新しさ点3.0〜) には負けるが、2〜3日経った投稿と互角、それ以降は名言が勝つ。
--   ユーザーが少ない初期はフィードの空きスロットを名言68件が埋め続ける構造だった。
-- 変更 (052 の全文をベースに2点だけ):
--   1. quote_base 0.8 → 0.45: 投稿はおよそ3〜4日は名言より上に居られる
--      (伸びてる名言は like/comment 項で自然に加点されるので上に来てよい — ユーザー了承)
--   2. 名言の適応型キャップ (2026-07-31 ユーザーFB「最初は公式だけ。フィードは
--      ずっとたくさんあってほしい」で固定キャップから変更):
--      quote_allow = GREATEST(quote_cap, limit_count − 投稿候補数)。
--      投稿が埋めきれない分は名言が全部埋める = フィードは常に limit_count 件を
--      目指す (初期は名言50件でもよい)。投稿が増えるほど名言枠は自動で縮み、
--      下限 quote_cap (15) 件まで絞られる
-- 適用: SQL Editor で全文実行。冪等。
-- ロールバック: quote_base を 0.8、quote_cap を 999 に書き換えて再実行。
-- ユーザー増加後のチューニングも params の2定数を書き換えるだけ。
-- ============================================================

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
            0.45 ::double precision AS quote_base,         -- 062: 0.8→0.45 (名言はユーザー投稿より控えめに)
            2    ::integer          AS author_cap,         -- 1フィードあたり同一投稿者の最大件数 (postsのみ)
            15   ::integer          AS quote_cap           -- 062: 投稿が十分ある時の名言枠の下限 (適応型、下のquota参照)
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
        -- posts: 同一投稿者の連投キャップ (052)。
        -- quotes: 062 で kind 単位の1パーティションに変更 = フィード全体の名言キャップ
        --   (060 で全名言が匿名著者1人になったが、将来著者が分かれても壊れないよう
        --    author_id には依存させない)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    )
    quota AS (
        -- 適応型の名言枠: 投稿候補 (author_cap 適用後) が limit_count に足りない分は
        -- 名言で満たす。投稿が十分あれば下限 quote_cap まで絞る
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

COMMENT ON FUNCTION public.fetch_mixed_feed_random(integer) IS
    'おすすめフィード (名言+投稿の混合、スコアリング+ジッター)。'
    '052: 同一投稿者は1フィードあたり author_cap 件まで。'
    '062: quote_base 0.45 + 名言は1フィードあたり quote_cap 件まで (params CTE で調整可)';
