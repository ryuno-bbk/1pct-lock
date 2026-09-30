-- ============================================================
-- 063_feed_seeded_shuffle.sql
-- Fix for the feed order not changing on pull-to-refresh (2026-07-31)
-- ============================================================
-- Symptom (reported by the user, several times):
--   Restarting the app changes the order, but pulling down to refresh at the top of the feed keeps
--   the same order. The app-side wiring (refreshable → loadRecommended → RPC re-fetch →
--   @Published replacement) is correct in the code, and since a restart changes it, the jitter
--   itself works.
--
-- Cause (presumed):
--   This function is declared LANGUAGE sql **STABLE**, but its body used the VOLATILE random().
--   STABLE is a declaration that "it returns the same result for the same arguments within the same
--   transaction", and PostgreSQL is allowed to trust it and reuse the plan.
--   Consecutive calls with the same arguments (limit_count=50) could return the same result under
--   the conditions of a pooled connection + a cached plan. An app restart recreates both the
--   connection and the plan, so it changes. This matches the reported symptom (restart = changes /
--   refresh = does not change).
--
-- Fix: stop relying on the server's random(), and switch to **the app passing an order seed every time**.
--   - Jitter = a uniform 0-1 value made from md5(item_id || seed). If the seed changes, the order
--     always changes, and the same seed always gives the same order (= the declaration matches the
--     implementation)
--   - If seed is omitted, the server makes one with gen_random_uuid() (compatibility with old clients)
--   - The function is changed to VOLATILE (the default) = a declaration that matches reality.
--     Prevents identical results from plan reuse
--
-- ⚠️ The number of arguments grows, so CREATE OR REPLACE would create a separate function (overload).
--    To keep PostgREST resolution unambiguous, DROP the old signature first and then recreate it.
--    seed has a DEFAULT, so it can also be called from app versions before the update (which send
--    only limit_count).
--
-- Apply: run the whole text in the SQL Editor. Idempotent.
-- Rollback: re-running 062 goes back to the old implementation (random()).
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
        -- ============ Tuning weights (edit only here and CREATE OR REPLACE to adjust) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- Max score for post recency (right after posting)
            24.0 ::double precision AS recency_half_hours, -- The recency score halves after this much time
            0.5  ::double precision AS w_like,             -- Coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- Coefficient of ln(1+comment_count) (a comment is stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- Bonus for authors you follow
            1.0  ::double precision AS w_seen,             -- Read penalty coefficient of ln(1+your own view count) (deduction)
            1.5  ::double precision AS w_jitter,           -- Max jitter (exploration)
            0.45 ::double precision AS quote_base,         -- 062: quotes are weighted lower than user posts
            2    ::integer          AS author_cap,         -- Max number of posts from the same author per feed (posts only)
            15   ::integer          AS quote_cap,          -- 062: lower bound of the quote slots when there are enough posts (adaptive)
            -- 063: order seed. The app passes a new value every time. If omitted, the server makes one
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
                -- 063: uniform jitter from the seed (the same seed gives the same order / changing it always changes
                -- the order)
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
        -- posts: cap on consecutive posts from the same author (052).
        -- quotes: one partition per kind = quote cap for the whole feed (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- Adaptive quote slots (062): whatever the post candidates lack for limit_count is filled with quotes
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
