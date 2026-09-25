-- ============================================================
-- 050_comment_owner_like.sql
-- 「投稿者がいいねしました」バッジ用の is_liked_by_owner (2026-07-25 実機FB)
-- ============================================================
-- fetch_comments_for_post の戻り値に「そのコメントを投稿の作者がいいねしているか」を追加。
-- TikTok の作成者ハートと同じ UI (返信ボタン横に投稿者アバター+赤ハート) の判定材料。
-- 名言コメント (fetch_comments_for_quote) は「投稿者」概念が無いため対象外。
--
-- 注意: RETURNS TABLE の列追加は CREATE OR REPLACE では不可 → DROP してから再作成。
-- 本文は 037_moderation_visibility_fixes.sql の 3-1 が最新ベース (フィルタ条件は不変)。
-- クライアント (UserComment) は decodeIfPresent なので、この SQL 適用前後どちらの
-- ビルドでも壊れない。
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
        -- 返信先ユーザー名 (parent が存在すればその author の display_name)
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name,
        -- 投稿者 (user_posts.user_id) がこのコメントをいいねしているか (050)
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
