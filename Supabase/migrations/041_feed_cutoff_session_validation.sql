-- ============================================================
-- 041_feed_cutoff_session_validation.sql
-- 30-day cutoff for the recommended feed (M33) + server-side validation of
-- block_sessions.planned_seconds (M34)
-- ============================================================
-- Purpose:
--   1. M33: fetch_mixed_feed_random (029_recommend_feed.sql) scores every non-rejected row of
--      user_posts each time, so the query gets heavier linearly as the number of posts grows. Add
--      one condition line, "created_at within the last 30 days", to the WHERE clause of the post
--      branch (UGC posts) to cap the growth in the number of target rows.
--   2. M34: block_sessions.planned_seconds (added in 033_completion_rate_stats.sql) has a CHECK
--      constraint on the table definition (block_sessions_planned_seconds_range: NULL or
--      1-604800), but it does not appear at all in the validate_block_session trigger of
--      015_security_audit.sql (the main validation of started_at / ended_at / duration_seconds).
--      The completion rate stats (033 get_user_stats) use "planned time of 10 minutes or more" as
--      the gate for entering the denominator, so the validation of this value is aligned with the
--      same trigger function and the same RAISE EXCEPTION path as the other validations (closing
--      a tamper-resistance gap).
--
-- Design decisions:
--   - M33: fetch_mixed_feed_random has not added or removed RETURNS TABLE columns since 029
--     (adding comment_count was already done in 029). The signature and return columns do not
--     change, so the "DROP FUNCTION → CREATE FUNCTION" used by 021/029 is not needed, and
--     CREATE OR REPLACE alone is enough (same decision as 037/040). The quote branch, params CTE,
--     score expression, RETURNS TABLE columns and REVOKE/GRANT statements are not changed at all
--     from 029 (this diff is only a 1-line addition to the WHERE clause of the post branch).
--   - Only the post branch gets the cutoff. The quote branch is designed so that "recency has no
--     meaning" (see the comment in 029: created_at is the bulk import date), so it stays out of
--     the cutoff, unchanged. A separate branch for top-liked posts (e.g. keep posts older than 30
--     days if they are popular) is not built this time (user decision: simple 30-day cutoff only).
--   - idx_user_posts_created_at (created_at DESC) was confirmed by grep to already exist in
--     005_b_user_posts.sql, so adding an index in this file was judged unnecessary (not even a
--     duplicate CREATE INDEX IF NOT EXISTS is written).
--   - M34: the block_sessions_planned_seconds_range CHECK constraint from 033 (NULL or
--     1-604800) stays on the table definition, unchanged. What is added now is the same range
--     check inside the validate_block_session trigger. It does not replace the CHECK
--     constraint; it is added as defense in depth (aligned with the same RAISE EXCEPTION path as
--     the other checks, so that the source of the error is visible in one place).
--   - The range is "NULL allowed / if non-NULL, 1-604800". It matches the client-side clamp
--     (AppBlocker/Core/Services/BlockSessionTracker.swift: enqueueSession queues
--     `min(plannedSeconds, 604800)` only when `plannedSeconds > 0`, and makeInsert reapplies
--     the same clamp with `$0 > 0 ? min($0, 604800) : nil`).
--     schedule/location modes always send nil, so allowing NULL is required.
--   - The trigger itself (block_sessions_validate, BEFORE INSERT OR UPDATE), created in 015,
--     keeps referencing public.validate_block_session() by name, so DROP/CREATE TRIGGER is not
--     needed and CREATE OR REPLACE of the function is enough (same method as 037/040). The
--     existing validation logic (rolbypassrls bypass / started_at in the future / ended_at in
--     the future / ended_at<started_at / duration_seconds mismatch / over 7 days) is not changed
--     at all; only a new IF block is added at the end.
--
-- Execution order: any time after 029, 033 and 015 (all assumed to be applied).
--   Safe to run any number of times (CREATE OR REPLACE FUNCTION only, no DROP or destructive DDL).
--   This file is meant to be applied manually by the user in Supabase Dashboard → SQL Editor
--   (no automatic deploy).
-- ============================================================

-- ============================================
-- 1. M33: 30-day cutoff for fetch_mixed_feed_random
-- ============================================
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
        -- ============ Tuning weights (adjust by rewriting only this part and running CREATE OR REPLACE) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- Max recency score (right after posting)
            24.0 ::double precision AS recency_half_hours, -- The recency score halves after this much time
            0.5  ::double precision AS w_like,             -- Coefficient of ln(1+like_count)
            0.7  ::double precision AS w_comment,          -- Coefficient of ln(1+comment_count) (a comment shows stronger interest than a like)
            1.2  ::double precision AS w_follow,           -- Bonus for posters you follow
            1.0  ::double precision AS w_seen,             -- Coefficient of the read penalty ln(1+own view count) (deduction)
            1.5  ::double precision AS w_jitter,           -- Max random jitter (exploration)
            0.8  ::double precision AS quote_base          -- Fixed base score for quotes (instead of recency decay)
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

-- ============================================
-- 2. M34: add planned_seconds validation to validate_block_session
-- ============================================
CREATE OR REPLACE FUNCTION public.validate_block_session()
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

    IF NEW.started_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'block_sessions: started_at is in the future';
    END IF;

    IF NEW.ended_at IS NOT NULL THEN
        IF NEW.ended_at > now() + interval '5 minutes' THEN
            RAISE EXCEPTION 'block_sessions: ended_at is in the future';
        END IF;
        IF NEW.ended_at < NEW.started_at THEN
            RAISE EXCEPTION 'block_sessions: ended_at before started_at';
        END IF;
        IF NEW.duration_seconds IS NULL
           OR abs(NEW.duration_seconds - EXTRACT(EPOCH FROM (NEW.ended_at - NEW.started_at))) > 2
        THEN
            RAISE EXCEPTION 'block_sessions: duration_seconds does not match timestamps';
        END IF;
        IF NEW.duration_seconds > 604800 THEN
            RAISE EXCEPTION 'block_sessions: session longer than 7 days rejected';
        END IF;
    END IF;

    IF NEW.planned_seconds IS NOT NULL
       AND (NEW.planned_seconds <= 0 OR NEW.planned_seconds > 604800)
    THEN
        RAISE EXCEPTION 'block_sessions: planned_seconds out of range (1-604800)';
    END IF;

    RETURN NEW;
END;
$$;

-- ============================================
-- 3. Queries for checking behavior (no need to run, comments only)
-- ============================================
-- M33: confirm that posts older than 31 days do not appear in the feed (after preparing test rows):
--   SELECT kind, item_id, created_at FROM fetch_mixed_feed_random(50)
--   WHERE kind = 'post' AND created_at < now() - interval '30 days';
--   -- Should be 0 rows (quotes are out of scope, so narrow to kind='post' when checking)
--
-- M34: confirm that an out-of-range planned_seconds is rejected (run as authenticated → it should
-- error):
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status, planned_seconds)
--   VALUES (auth.uid(), 'timer', now() - interval '10 minutes', now(), 600, 'completed', 999999);
--   -- Should be rejected with 'block_sessions: planned_seconds out of range (1-604800)'
-- Confirm that planned_seconds = NULL (schedule/location etc.) still passes as before:
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status, planned_seconds)
--   VALUES (auth.uid(), 'schedule', now() - interval '10 minutes', now(), 600, 'completed', NULL);
--   -- Should succeed
