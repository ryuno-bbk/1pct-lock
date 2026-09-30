-- ============================================================
-- 059_get_my_followers.sql
-- RPC for your own follower list (2026-07-30, paired with turning the follower tap into tabs)
-- ============================================================
-- Background: tapping the follower count on My Page → [Followers|Following] tabs (IG style,
-- confirmed by the user). Other people's rows in user_follows cannot be read due to RLS, so
-- SECURITY DEFINER returns only "a minimal profile set of the users who follow you". The caller
-- can only get their own followers (no arguments, fixed to auth.uid()).
--
-- Client: FollowListView (followers tab). If not applied, it just shows an empty list and does not
-- break. Idempotent. Rollback: DROP FUNCTION public.get_my_followers();
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_followers()
RETURNS TABLE (
    id           uuid,
    display_name text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id, u.display_name, u.avatar_url, u.is_pro
    FROM public.user_follows f
    JOIN public.users u ON u.id = f.follower_id
    WHERE f.followed_user_id = auth.uid()
    ORDER BY f.created_at DESC;
$$;

COMMENT ON FUNCTION public.get_my_followers() IS
    '自分をフォローしているユーザーの一覧 (プロフィール最小セット)。FollowListView フォロワータブ用';

REVOKE EXECUTE ON FUNCTION public.get_my_followers() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_my_followers() TO authenticated;
