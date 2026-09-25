-- ============================================================
-- 063_feed_seeded_shuffle.sql
-- 引き下げ更新 (pull-to-refresh) でフィードの並びが変わらない問題の修正 (2026-07-31)
-- ============================================================
-- 症状 (ユーザー報告・複数回):
--   アプリを再起動すると並び順は変わるのに、フィード最上部で引き下げて更新しても
--   同じ並びのまま。アプリ側の配線 (refreshable → loadRecommended → RPC 再取得 →
--   @Published 差し替え) はコード上正しく、restart で変わる以上ジッター自体は効いている。
--
-- 原因 (推定):
--   本関数は LANGUAGE sql **STABLE** と宣言されているが、本体で VOLATILE な random() を
--   使っていた。STABLE は「同一トランザクション内で同じ引数なら同じ結果を返す」という
--   宣言であり、PostgreSQL はこれを信じてプランを再利用してよい。
--   同じ引数 (limit_count=50) での連続呼び出しが、プール済み接続 + キャッシュ済みプランの
--   条件で同じ結果を返し得た。アプリ再起動では接続もプランも作り直されるため変化する —
--   報告された症状 (再起動=変わる / 更新=変わらない) と一致する。
--
-- 修正方針: サーバーの random() 任せをやめ、**並びの種 (seed) をアプリが毎回渡す**方式へ。
--   - ジッター = md5(item_id || seed) から作る 0〜1 の一様値。seed が変われば必ず並びが変わり、
--     同じ seed なら必ず同じ並びになる (= 宣言と実装が一致する)
--   - seed 省略時はサーバーが gen_random_uuid() で1つ作る (旧クライアント互換)
--   - 関数は VOLATILE (既定) に変更 = 実態どおりの宣言。プラン再利用による同一結果を防ぐ
--
-- ⚠️ 引数が増えるため CREATE OR REPLACE では別関数 (オーバーロード) になってしまう。
--    PostgREST の解決が曖昧にならないよう、旧シグネチャを DROP してから作り直す。
--    seed に DEFAULT があるので、更新前のアプリ (limit_count だけ送る) からも呼べる。
--
-- 適用: SQL Editor で全文実行。冪等。
-- ロールバック: 062 を再実行すれば旧実装 (random()) に戻る。
-- ============================================================

DROP FUNCTION IF EXISTS public.fetch_mixed_feed_random(integer);

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
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ジッターの最大値 (探索性)
            0.45 ::double precision AS quote_base,         -- 062: 名言はユーザー投稿より控えめに
            2    ::integer          AS author_cap,         -- 1フィードあたり同一投稿者の最大件数 (postsのみ)
            15   ::integer          AS quote_cap,          -- 062: 投稿が十分ある時の名言枠の下限 (適応型)
            -- 063: 並びの種。アプリが毎回新しい値を渡す。省略時はサーバーで1つ作る
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
                -- 063: seed 由来の一様ジッター (同じ seed なら同じ並び / 変えれば必ず変わる)
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
          AND up.created_at > now() - interval '30 days'
    ),
    ranked AS (
        -- posts: 同一投稿者の連投キャップ (052)。
        -- quotes: kind 単位の1パーティション = フィード全体の名言キャップ (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- 適応型の名言枠 (062): 投稿候補が limit_count に足りない分は名言で満たす
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
    '063: 並びの種をアプリが渡す (毎回変えれば必ず並びが変わる。同じ seed なら再現する)';
