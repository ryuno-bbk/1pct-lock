-- ============================================================
-- 050_comment_owner_like.sql
-- is_liked_by_owner for the "投稿者がいいねしました" ("Liked by the author") badge (2026-07-25 real device feedback)
-- ============================================================
-- Add "whether the post's author liked that comment" to the return value of fetch_comments_for_post.
-- Input for the same UI as TikTok's creator heart (author avatar + red heart next to the reply button).
-- Quote comments (fetch_comments_for_quote) are excluded because there is no "author" concept.
--
-- Note: adding columns to RETURNS TABLE is not possible with CREATE OR REPLACE → DROP, then recreate.
-- The body is based on the latest version, 3-1 of 037_moderation_visibility_fixes.sql (filter
-- conditions unchanged). The client (UserComment) uses decodeIfPresent, so builds do not break
-- either before or after this SQL is applied.
-- ============================================================

DROP FUNCTION IF EXISTS public.fetch_comments_for_post(uuid, integer);

CREATE FUNCTION public.fetch_comments_for_post(
    target_post_id uuid,
    limit_count    integer DEFAULT 200
)
RETURNS TABLE (
    id                 uuid,
    post_id            uuid,
    parent_comment_id  uuid,
    author_user_id     uuid,
    author_name        text,
    author_avatar_url  text,
    is_pro_author      boolean,
    text               text,
    like_count         integer,
    is_liked_by_me     boolean,
    created_at         timestamptz,
    reply_to_name      text,
    is_liked_by_owner  boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id,
        c.post_id,
        c.parent_comment_id,
        c.author_user_id,
        u.display_name      AS author_name,
        u.avatar_url        AS author_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_author,
        c.text,
        c.like_count,
        EXISTS (
            SELECT 1 FROM public.user_comment_likes l
            WHERE l.comment_id = c.id AND l.user_id = auth.uid()
        ) AS is_liked_by_me,
        c.created_at,
        -- Name of the user replied to (the display_name of the parent's author, if the parent exists)
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name,
        -- Whether the author (user_posts.user_id) liked this comment (050)
        EXISTS (
            SELECT 1
            FROM public.user_comment_likes ol
            JOIN public.user_posts p ON p.id = c.post_id
            WHERE ol.comment_id = c.id AND ol.user_id = p.user_id
        ) AS is_liked_by_owner
    FROM public.user_comments c
    JOIN public.users u ON u.id = c.author_user_id
    WHERE c.post_id = target_post_id
      AND c.author_user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND c.moderation_status <> 'rejected'
      AND (
        c.moderation_status <> 'flagged'
        OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
      )
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;
