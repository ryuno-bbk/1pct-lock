-- ============================================================
-- 018_b_notifications_quote_target.sql
-- fetch_notifications に target_quote_id を追加 (017 の補完)
-- ============================================================
-- 017 で公式名言へのコメント返信通知が生まれたが、014 の
-- fetch_notifications は target_quote_id を返しておらず、
-- 通知タップ時にどの名言へ飛べばよいか分からない。
-- RETURNS TABLE の列追加は CREATE OR REPLACE 不可のため DROP → CREATE。
--
-- 実行順序: 017 完了後。何度実行しても安全
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
