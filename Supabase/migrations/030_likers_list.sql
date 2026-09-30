-- ============================================
-- 030_likers_list.sql
-- RPC for the list of users who liked (2026-07-10, user-specified)
--
-- Tap the like avatar stack at the bottom left of a feed card → show the list of users who liked.
-- Under RLS, user_likes can only be read for your own rows, so a SECURITY DEFINER RPC returns
-- only the public profiles (name/avatar) of "the users who liked that post/quote".
-- Full-list version of the likers (≤3) of 028 fetch_feed_extras.
--
-- Safe to run any number of times (CREATE OR REPLACE).
-- ============================================

CREATE OR REPLACE FUNCTION public.fetch_likers(
    target_kind text,          -- 'post' | 'quote'
    target_id   uuid,
    limit_count integer DEFAULT 200
)
RETURNS TABLE (
    user_id      uuid,
    display_name text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT
        u.id,
        u.display_name,
        u.avatar_url,
        COALESCE(u.is_pro, false)
    FROM public.user_likes l
    JOIN public.users u ON u.id = l.user_id
    WHERE (
            (target_kind = 'post'  AND l.post_id  = target_id)
         OR (target_kind = 'quote' AND l.quote_id = target_id)
        )
        -- Do not show users you have blocked (same policy as fetch_feed_extras)
        AND l.user_id NOT IN (
            SELECT blocked_user_id FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
    ORDER BY l.created_at DESC
    LIMIT LEAST(GREATEST(limit_count, 1), 500);
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_likers(text, uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_likers(text, uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_likers(text, uuid, integer) TO authenticated;
