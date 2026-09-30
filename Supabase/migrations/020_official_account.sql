-- ============================================================
-- 020_official_account.sql
-- Remove historical figure (author) accounts → reassign to the "1%" official account
-- ============================================================
-- Background:
--   Remove all presentation that looks like "author accounts" of real historical figures. The poster
--   of every quote (quotes) becomes the single "1%" official account, and the author name is demoted
--   to text on the card (a dash + Marcus Aurelius). The goal is avoiding the legal risk of using real
--   names of historical figures (preventing people from mistakenly thinking living people endorse it).
--
-- What to do:
--   1. Add a 1% sentinel row to authors (fixed UUID id)
--   2. Migrate users who had "author follows" to following 1%
--      (existing user_follows rows are not deleted. Only a row for 1% is added)
--   3. Change the quote-side WHERE of fetch_following_feed to "all official quotes if you follow 1%"
--      (fetch_mixed_feed_random / fetch_tag_feed are unchanged)
--
-- How to apply:
--   Together with 019_post_v2.sql, either paste and run in the SQL Editor of Supabase Dashboard,
--   or `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/020_official_account.sql`.
--   Not applied yet (as of 2026-07-05).
--
-- Execution order: after 019 is done. Safe to run any number of times (idempotent via ON CONFLICT DO
-- NOTHING / DROP FUNCTION IF EXISTS)
-- ============================================================

-- ============================================
-- 1. Add a 1% sentinel row to authors
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
-- 2. Migrate existing author follows to following 1% (existing rows are not deleted)
-- ============================================
-- The unique constraint of user_follows is (follower_id, author_id) WHERE author_id IS NOT NULL
-- (user_follows_follower_author_unique in 002_a_user_id.sql), so it is used as is as the
-- ON CONFLICT target.
INSERT INTO public.user_follows (follower_id, author_id)
SELECT DISTINCT uf.follower_id, '11111111-1111-1111-1111-111111111111'::uuid
FROM public.user_follows uf
WHERE uf.author_id IS NOT NULL
  AND uf.author_id <> '11111111-1111-1111-1111-111111111111'::uuid
ON CONFLICT (follower_id, author_id) WHERE author_id IS NOT NULL DO NOTHING;

-- ============================================
-- 3. Change the quote side of fetch_following_feed to be based on following the sentinel
-- ============================================
-- The RETURNS TABLE column list is exactly the same as in 019_post_v2.sql (including title /
-- image_path). The post-side branch is unchanged.

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
        -- If the user follows "the official 1% account" (not "follows the author"), all official quotes are
        -- included
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
