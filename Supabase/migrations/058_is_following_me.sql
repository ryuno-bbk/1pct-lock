-- ============================================================
-- 058_is_following_me.sql
-- 相互フォロー表示用 RPC (2026-07-30 D案プロフィール改修とセット)
-- ============================================================
-- 背景: 他人プロフィールのフォローボタンを、相手が自分をフォローしている場合に
-- 「相互フォロー」表示へ変える (ユーザー要望「相互フォローが分かると絆が生まれる」)。
-- user_follows の他人行は RLS で読めないため、boolean だけを返す SECURITY DEFINER RPC で
-- 最小開示にする (誰が誰をフォローしているかの一覧は開示しない。
-- 「相手→自分」の1ビットのみ、かつ呼び出し元は自分の分しか聞けない)。
--
-- クライアント: FollowService.isFollowedBy → UserProfileView のボタン表示。
-- 未適用でもクライアントは false 扱い (通常のフォロー中表示) で壊れない。
-- 冪等。ロールバック: DROP FUNCTION public.is_following_me(uuid);
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
