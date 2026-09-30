-- ============================================================
-- 062_quote_feed_deprioritize.sql
-- Official quotes must not bury user posts (filed by the user 2026-07-31)
-- ============================================================
-- Background: quote scores are fixed at quote_base=0.8 with no decay, no read penalty and no cap.
--   They lose to new posts (recency score 3.0 and up), are even with posts 2 to 3 days old, and win
--   after that. In the early days with few users, the 68 quotes kept filling the empty slots in the feed.
-- Changes (only 2 points, based on the full text of 052):
--   1. quote_base 0.8 → 0.45: posts stay above quotes for about 3 to 4 days
--      (quotes that are doing well get points naturally from the like/comment terms, so it is fine for
--      them to rise; user agreed)
--   2. Adaptive cap for quotes (changed from a fixed cap after user feedback 2026-07-31 "at first only
--      official. I want the feed to always have lots of items"):
--      quote_allow = GREATEST(quote_cap, limit_count − number of post candidates).
--      Whatever posts cannot fill, quotes fill completely = the feed always aims for limit_count items
--      (early on, 50 quotes is fine). As posts increase, the quote slots shrink automatically,
--      down to the lower bound of quote_cap (15) items
-- Apply: run the full text in the SQL Editor. Idempotent.
-- Rollback: change quote_base to 0.8 and quote_cap to 999 and run again.
-- Tuning after the user base grows is also just changing the 2 constants in params.
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
        -- ============ Tuning weights (to adjust, change only this part and run CREATE OR REPLACE) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- max recency score of a post (right after posting)
            24.0 ::double precision AS recency_half_hours, -- the recency score halves after this much time
            0.5  ::double precision AS w_like,             -- coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- coefficient of ln(1+comment_count) (a comment shows stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- bonus for authors you follow
            1.0  ::double precision AS w_seen,             -- read penalty coefficient on ln(1+own view count) (subtracted)
            1.5  ::double precision AS w_jitter,           -- max random jitter (for exploration)
            0.45 ::double precision AS quote_base,         -- 062: 0.8→0.45 (quotes are kept lower than user posts)
            2    ::integer          AS author_cap,         -- max items from the same author per feed (posts only)
            15   ::integer          AS quote_cap           -- 062: lower bound of quote slots when there are enough posts (adaptive, see quota below)
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
        -- posts: cap on consecutive posts from the same author (052).
        -- quotes: changed in 062 to 1 partition per kind = quote cap for the whole feed
        --   (in 060 all quotes became one anonymous author, but it does not depend on author_id
        --    so it will not break if authors split again in the future)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    )
    quota AS (
        -- Adaptive quote slots: whatever the post candidates (after applying author_cap) lack to reach limit_count
        -- is filled with quotes. If there are enough posts, narrow down to the lower bound quote_cap
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
