-- ============================================================
-- 020_official_account.sql
-- 偉人(著者)アカウント廃止 → 「1%」公式アカウントへの付け替え
-- ============================================================
-- 背景:
--   実在偉人の「著者アカウント」風の見せ方を全廃する。名言 (quotes) の投稿主体は
--   すべて「1%」公式アカウント1本になり、著者名はカード上のテキスト表記
--   (— Marcus Aurelius) に降格する。目的は偉人実名の法的リスク回避
--   (存命人物の公認誤認防止)。
--
-- やること:
--   1. authors へ 1% sentinel 行を追加 (id 固定 UUID)
--   2. 既存の「著者フォロー」をしていたユーザーを 1% への フォローに移行
--      (既存の user_follows 行は削除しない。単に 1% への行を追加するだけ)
--   3. fetch_following_feed の quote 側 WHERE を「1% をフォローしていれば全公式名言」に変更
--      (fetch_mixed_feed_random / fetch_tag_feed は変更なし)
--
-- 適用方法:
--   019_post_v2.sql とあわせて、Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/020_official_account.sql`
--   のいずれか。まだ未適用 (2026-07-05 時点)。
--
-- 実行順序: 019 完了後。何度実行しても安全 (ON CONFLICT DO NOTHING / DROP FUNCTION IF EXISTS で冪等)
-- ============================================================

-- ============================================
-- 1. authors へ 1% sentinel 行を追加
-- ============================================
INSERT INTO public.authors (id, name, bio_jp, bio_en, is_official)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '1%',
    'スマホを置いた時間だけが、あなたを作る。',
    'Only the hours away from your phone build you.',
    true
)
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- 2. 既存の著者フォローを 1% フォローへ移行 (既存行は削除しない)
-- ============================================
-- user_follows の一意制約は (follower_id, author_id) WHERE author_id IS NOT NULL
-- (002_a_user_id.sql の user_follows_follower_author_unique) なので、これをそのまま
-- ON CONFLICT のターゲットに使う。
INSERT INTO public.user_follows (follower_id, author_id)
SELECT DISTINCT uf.follower_id, '11111111-1111-1111-1111-111111111111'::uuid
FROM public.user_follows uf
WHERE uf.author_id IS NOT NULL
  AND uf.author_id <> '11111111-1111-1111-1111-111111111111'::uuid
ON CONFLICT (follower_id, author_id) WHERE author_id IS NOT NULL DO NOTHING;

-- ============================================
-- 3. fetch_following_feed の quote 側を sentinel フォロー基準に変更
-- ============================================
-- RETURNS TABLE の列リストは 019_post_v2.sql と完全に同一 (title / image_path を含む)。
-- post 側の分岐は無変更。

DROP FUNCTION IF EXISTS public.fetch_following_feed(integer);

CREATE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            CASE WHEN q.category IS NULL THEN '{}'::text[] ELSE ARRAY[q.category] END AS tags,
            q.like_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        -- 「著者をフォロー」ではなく「1% 公式アカウントをフォロー」していれば全公式名言が対象
        WHERE EXISTS (
            SELECT 1 FROM public.user_follows
            WHERE follower_id = auth.uid()
              AND author_id = '11111111-1111-1111-1111-111111111111'::uuid
        )

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id,
            p.title,
            p.image_path
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE u.id IN (
            SELECT followed_user_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND followed_user_id IS NOT NULL
        )
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;
