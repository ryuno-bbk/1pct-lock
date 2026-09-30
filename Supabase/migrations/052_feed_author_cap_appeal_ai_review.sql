-- ============================================================
-- 052_feed_author_cap_appeal_ai_review.sql
-- Feed diversity + lower post limit + groundwork for AI re-review of appeals (2026-07-29)
-- ============================================================
-- Background (filed by the user 2026-07-29):
--   1. The recommended feed has no control over author diversity, so one person posting repeatedly can
--      take most of limit 50 (especially visible now with few posts in total). What makes "repeated
--      posts not spread" on TikTok etc. is actually a per-author cap on the ranking side.
--   2. The post limit of 100/24h (046) was meant as anti-abuse, but as a cost ceiling for AI moderation
--      it is too high (100 posts × 0.7 to 1.4 yen = up to 140 yen/day/person).
--      Lowered to 10/24h (BeReal = 1 to 2 posts/day, IG average < 1 post/day. A ceiling real users
--      will not see). The client wording has contained no number since 046, so no change is needed.
--   3. Add the ai_review column where the review-appeal Edge Function (AI re-review of appeals) writes
--      its findings.
--
-- Apply: run the full text of this file in Supabase Dashboard → SQL Editor (user task).
-- Idempotent: only CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS. Safe to run any number of times.
-- Rollback: set author_cap to 999 and run again to effectively disable the cap.
--   To restore the post limit, change 10 back to 100 and run again.
-- ============================================================

-- ============================================================
-- 1. fetch_mixed_feed_random: add a per-author cap
-- ============================================================
-- Based on the full text of 041, add "at most author_cap items from the same author per feed" for
-- posts only (row_number() keeps only the top by score). quotes (official quotes) are excluded because
-- each great figure has a different author and they are curated.
-- ⚠️ The RETURNS TABLE columns are unchanged from 029/041 (as learned in M33, changing columns
--    requires DROP→recreate, so the cap is done only by adding to the WHERE clause)

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
            0.8  ::double precision AS quote_base,         -- fixed base score for quotes (instead of recency decay)
            2    ::integer          AS author_cap          -- 052: max items from the same author per feed (posts only)
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
        -- 052: cap on consecutive posts from the same author. Keep only the top author_cap items by score
        -- (posts only). jitter is random(), so "which 2 items remain" also changes on every feed
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
-- 2. Post rate limit 100 → 10 / 24h
-- ============================================================
-- The comment side (enforce_comment_rate_limit, 300/24h) is not changed.
-- The client wording contains no number, so no change is needed (removed in 046)

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
    -- 052: 100 → 10 (per-person ceiling on AI moderation cost. Max 140 yen/day → 14 yen/day)
    IF recent_count >= 10 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;
    RETURN NEW;
END;
$$;

-- The trigger itself was created in 046 (CREATE OR REPLACE of the function alone applies it).
-- Add an IF NOT EXISTS-style recreate so it does not break in an environment without 046
DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- ============================================================
-- 3. user_appeals.ai_review (findings of the AI re-review of appeals)
-- ============================================================
-- Written by the review-appeal Edge Function (service_role):
--   { analysis, overturn, user_note, model, reviewed_at }
-- When overturn=true, the same Function updates status to 'approved', and the existing
-- user_appeals_resolve trigger (039) takes care of restoring the post + the appeal_approved notification.
-- overturn=false keeps status='pending' = stays in the queue for the final ruling by a human (operator).
-- In the operator queue SQL (Docs/moderation_ops_guide.md), ai_review->>'analysis' can be read
-- as a secondary finding. RLS: the SELECT policy stays owner-only (039).
-- ai_review is not used in the client UI, but it is fine if the owner can read it
-- (the internal terms in analysis are not wording meant for the user but are not secret. Same judgment
-- as allowed in 043)

ALTER TABLE public.user_appeals
    ADD COLUMN IF NOT EXISTS ai_review jsonb;

COMMENT ON COLUMN public.user_appeals.ai_review IS
    'review-appeal Edge Function のAI二次審査所見 { analysis, overturn, user_note, model, reviewed_at }。'
    'NULL = 未審査。overturn=false でも status は pending のまま (人間の最終裁定待ち)';
