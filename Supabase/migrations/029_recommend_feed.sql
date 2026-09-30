-- ============================================================
-- 029_recommend_feed.sql
-- Recommended feed: switch fetch_mixed_feed_random to heuristic scoring
-- + fix the regression in the comment_count return value shared by the 3 feed RPCs
-- ============================================================
-- Design: Fable 5 / Implementation: Sonnet 5
--
-- Purpose:
--   1. fetch_mixed_feed_random is currently pure random with ORDER BY random().
--      Replace it with a heuristic approach that sorts by a weighted sum score of "recency /
--      popularity / follow / already-seen penalty / exploration jitter". No ML and no new tables
--      at all (it only extends the existing shape of the 3 feed RPCs, same as 021/027).
--   2. When 021_post_carousel.sql rebuilt the return columns with DROP → CREATE, the comment_count
--      return column added in 017_b_quote_comments.sql was dropped by mistake
--      (regression). The Swift side FeedItem uses decodeIfPresent ?? 0, so it did not crash,
--      but the feed card's "view all N comments" always showed 0. This file restores the
--      comment_count return value in all 3: fetch_mixed_feed_random / fetch_following_feed /
--      fetch_tag_feed.
--
-- Design decisions:
--   - The score formula is a simple weighted sum: "recency + popularity (likes/comments) + follow
--     bonus - already-seen penalty + exploration jitter". There is no learning, and all weights are
--     constants hardcoded in the params CTE. If we want to tune it in operation, just rewrite this
--     function with CREATE OR REPLACE and change the numbers in params
--     (the same "done entirely in the SQL Editor" idea as the moderation_config rubric in 027).
--   - For quotes, created_at is the bulk import date, not the actual posting time, so
--     "recency" has no meaning. Instead of recency decay they get a fixed base score quote_base,
--     and compete with UGC posts only on the popularity terms (likes/comments).
--   - The already-seen penalty uses your own view count in post_views (028_bereal_ui.sql)
--     (view_count where viewer_id = auth.uid()) as an ln deduction. post_views is a log of how
--     many times the post detail was opened by tapping, so the effect is that "posts you tapped
--     and viewed once gradually sink in the feed" (posts you only scrolled past in the feed are
--     not included, only tapped details are a signal).
--   - The jitter (w_jitter * random()) is an exploration term so the order is never exactly the same
--     every time. It shuffles the ranks of posts with close scores, to avoid an experience where
--     reloading the same feed shows nothing new.
--   - All weights are gathered in the params CTE (CROSS JOIN). The design lets the user (operator)
--     tune it just by running CREATE OR REPLACE on this function again in the SQL Editor.
--   - The number of return columns grows (comment_count added), so CREATE OR REPLACE cannot be used,
--     and it is DROP FUNCTION IF EXISTS → CREATE FUNCTION, the same way as 021.
--     DROP also removes existing GRANT/REVOKE, so they are set again at the end for all 3.
--   - fetch_following_feed (created_at DESC) and fetch_tag_feed (random()) keep their order.
--     This time, for both, the only change is restoring comment_count.
--   - The SELECT columns, JOINs and WHERE (moderation filter / block filter / follow check) of the
--     quote branch and post branch follow the definition in 027_ai_moderation.sql word for word.
--     They are not based on 021 (021 has no moderation filter, and basing on it would regress the
--     layer 1/layer 2 filters).
--
-- Run order: after 028 is done. Safe to run any number of times (idempotent pattern of
-- DROP FUNCTION IF EXISTS → CREATE). No new tables or columns are added.
-- ============================================================

-- ============================================================
-- 1. fetch_mixed_feed_random (heuristic scoring version)
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_mixed_feed_random(integer);

CREATE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
        -- ============ Tuning weights (to adjust, rewrite only this part and run CREATE OR REPLACE) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- max recency score (right after posting)
            24.0 ::double precision AS recency_half_hours, -- the recency score halves after this much time
            0.5  ::double precision AS w_like,             -- coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- coefficient of ln(1+comment_count) (a comment shows stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- bonus for authors you follow
            1.0  ::double precision AS w_seen,             -- coefficient of the already-seen penalty on ln(1+your view count) (deduction)
            1.5  ::double precision AS w_jitter,           -- max value of the random jitter (exploration)
            0.8  ::double precision AS quote_base          -- fixed base score for quotes (in place of recency decay)
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
    )
    SELECT
        kind, item_id, body_jp, body_en, tags, like_count, comment_count, created_at,
        author_id, author_name, author_avatar_url, is_official_author, is_pro_author,
        background_id, title, image_path, image_count
    FROM scored
    ORDER BY score DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ============================================================
-- 2. fetch_following_feed (only restores comment_count, keeps created_at DESC)
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_following_feed(integer);

CREATE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
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
        -- If the user follows "the 1% official account" rather than "the author", all official quotes are
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ============================================================
-- 3. fetch_tag_feed (only restores comment_count, keeps random())
-- ============================================================
DROP FUNCTION IF EXISTS public.fetch_tag_feed(text, integer);

CREATE FUNCTION public.fetch_tag_feed(
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
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;

-- ============================================================
-- 4. Queries for checking behavior (no need to run, comments only)
-- ============================================================
-- SELECT kind, item_id, like_count, comment_count, created_at FROM fetch_mixed_feed_random(20);
-- Run the same query twice and check that the order changes (jitter)
