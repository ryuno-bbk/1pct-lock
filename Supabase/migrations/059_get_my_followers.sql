-- ============================================================
-- 059_get_my_followers.sql
-- 自分のフォロワー一覧 RPC (2026-07-30 フォロワータップのタブ化とセット)
-- ============================================================
-- 背景: マイページのフォロワー数タップ→[フォロワー|フォロー中]タブ (IG方式、ユーザー確定)。
-- user_follows の他人行は RLS で読めないため、SECURITY DEFINER で「自分をフォローしている
-- ユーザーのプロフィール最小セット」だけを返す。呼び出し元は自分のフォロワーしか取れない
-- (引数なし・auth.uid() 固定)。
--
-- クライアント: FollowListView (フォロワータブ)。未適用なら空一覧になるだけで壊れない。
-- 冪等。ロールバック: DROP FUNCTION public.get_my_followers();
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
