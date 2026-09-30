-- ============================================================
-- 018_b_notifications_quote_target.sql
-- Add target_quote_id to fetch_notifications (complement to 017)
-- ============================================================
-- 017 introduced comment reply notifications on official quotes, but 014's
-- fetch_notifications does not return target_quote_id, so
-- when a notification is tapped, it is unknown which quote to go to.
-- Adding a RETURNS TABLE column is not possible with CREATE OR REPLACE, so DROP → CREATE.
--
-- Execution order: after 017 is done. Safe to run any number of times
-- ============================================

DROP FUNCTION IF EXISTS public.fetch_notifications(integer);

CREATE FUNCTION public.fetch_notifications(limit_count integer DEFAULT 50)
RETURNS TABLE (
    id                uuid,
    kind              text,
    actor_user_id     uuid,
    actor_name        text,
    actor_avatar_url  text,
    is_pro_actor      boolean,
    target_post_id    uuid,
    target_quote_id   uuid,
    target_comment_id uuid,
    preview_text      text,
    read_at           timestamptz,
    created_at        timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        n.id,
        n.kind,
        n.actor_user_id,
        u.display_name      AS actor_name,
        u.avatar_url        AS actor_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_actor,
        n.target_post_id,
        n.target_quote_id,
        n.target_comment_id,
        n.preview_text,
        n.read_at,
        n.created_at
    FROM public.user_notifications n
    JOIN public.users u ON u.id = n.actor_user_id
    WHERE n.recipient_user_id = auth.uid()
      AND n.actor_user_id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY n.created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_notifications(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_notifications(integer) TO authenticated;
