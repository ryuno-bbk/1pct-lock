-- ============================================
-- 030_likers_list.sql
-- いいねした人の一覧 RPC (2026-07-10 ユーザー指定)
--
-- フィードカード左下のいいねアバタースタックをタップ → いいねした人一覧を表示する。
-- user_likes は RLS で本人の行しか読めないため、SECURITY DEFINER の RPC で
-- 「その投稿/名言にいいねした人」の公開プロフィール (名前/アバター) だけを返す。
-- 028 fetch_feed_extras の likers (≤3) のフルリスト版。
--
-- 何度実行しても安全 (CREATE OR REPLACE)。
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
        -- 自分がブロックした相手は出さない (fetch_feed_extras と同じ方針)
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
