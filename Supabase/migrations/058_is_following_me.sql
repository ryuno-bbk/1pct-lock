-- ============================================================
-- 058_is_following_me.sql
-- RPC for showing mutual follows (goes with the 2026-07-30 plan D profile rework)
-- ============================================================
-- Background: change the follow button on another user's profile to show "相互フォロー" ("Mutual
-- follow") when that user follows you (user request: "knowing it is a mutual follow creates a bond").
-- Other people's rows in user_follows cannot be read under RLS, so a SECURITY DEFINER RPC that returns
-- only a boolean keeps disclosure minimal (it does not disclose the list of who follows whom.
-- Only 1 bit, "them → me", and the caller can only ask about themself).
--
-- Client: FollowService.isFollowedBy → button display in UserProfileView.
-- If not applied, the client treats it as false (normal Following display) and does not break.
-- Idempotent. Rollback: DROP FUNCTION public.is_following_me(uuid);
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_following_me(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.user_follows
        WHERE follower_id = p_user_id
          AND followed_user_id = auth.uid()
    );
$$;

COMMENT ON FUNCTION public.is_following_me(uuid) IS
    '引数のユーザーが呼び出し元 (auth.uid) をフォローしているか。相互フォロー表示用の最小開示RPC';

REVOKE EXECUTE ON FUNCTION public.is_following_me(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_following_me(uuid) TO authenticated;
