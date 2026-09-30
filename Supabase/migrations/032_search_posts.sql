-- ============================================================
-- 032_search_posts.sql
-- Post search: search_posts RPC
-- ============================================================
-- Background (2026-07-15 search tab implementation):
--   A new search tab is added with 2 segments, "アカウント / 投稿" ("Accounts / Posts"). Account
--   search reuses search_users from 022_sns_minimum.sql + 025_search_users_escape.sql
--   as is, so this file only adds search_posts
--   (no new RPC for account search).
--
-- Design decisions:
--   - The return columns are exactly the same 17 columns as fetch_mixed_feed_random in
--     029_recommend_feed.sql. So the Swift FeedItem decoder can be reused as is, and
--     search results can be passed straight to FeedCardListView
--     (no new Decodable type). kind is always fixed to 'post'.
--   - Matching targets are user_posts.title (substring match) and tags (prefix match).
--     The body (text_jp/text_en) is not searched (per the spec, caption/tags only).
--   - Query normalization uses the same LIKE escaping as 025 (\ % _), plus removing a leading '#'
--     (so hashtag input such as "#朝活" ("#morningroutine") also hits the tag prefix match).
--   - The WHERE of the post branch (block filter / moderation filter) is
--     word for word the same as the post branch in 029, so that search does not become a loophole
--     around the layer 1/layer 2 filters.
--   - An empty query ('' after normalization) has a guard that returns 0 rows (prevents a full scan).
--   - Order: exact tag match (case-insensitive) first, then like count, then recency.
--     "Posts with a tag identical to the search term" were judged closest to the intent.
--
-- How to apply:
--   paste and run in the SQL Editor of Supabase Dashboard, or
--   `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/032_search_posts.sql`
--
-- Execution order: after 027 (depends on moderation_config / moderation_status). Safe to run any
-- number of times (CREATE OR REPLACE, no new tables or columns are added).
-- ============================================================

CREATE OR REPLACE FUNCTION public.search_posts(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH normalized AS (
        -- Remove a leading '#' (for hashtag input), then escape LIKE special characters.
        -- raw is the string before escaping. The exact tag match check in ORDER BY is an equality comparison,
        -- not a LIKE pattern, so using the escaped q would make tags containing '_' '%' '\' fail to match
        SELECT
            s.stripped AS raw,
            replace(replace(replace(s.stripped, '\', '\\'), '%', '\%'), '_', '\_') AS q
        FROM (
            SELECT CASE
                       WHEN trim(query) LIKE '#%' THEN substring(trim(query) FROM 2)
                       ELSE trim(query)
                   END AS stripped
        ) s
    )
    SELECT
        'post'::text   AS kind,
        up.id           AS item_id,
        up.text_jp      AS body_jp,
        up.text_en      AS body_en,
        up.tags,
        up.like_count,
        up.comment_count,
        up.created_at,
        u.id           AS author_id,
        u.display_name AS author_name,
        u.avatar_url   AS author_avatar_url,
        false          AS is_official_author,
        COALESCE(u.is_pro, false) AS is_pro_author,
        up.background_id,
        up.title,
        up.image_path,
        up.image_count
    FROM public.user_posts up
    JOIN public.users u ON u.id = up.user_id
    CROSS JOIN normalized n
    WHERE query IS NOT NULL
      AND n.q <> ''
      AND (
        up.title ILIKE '%' || n.q || '%'
        OR EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE t ILIKE n.q || '%'
        )
      )
      AND up.user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND up.moderation_status <> 'rejected'
      AND (
        up.moderation_status <> 'flagged'
        OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
      )
    ORDER BY
        CASE WHEN EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE lower(t) = lower(n.raw)
        ) THEN 0 ELSE 1 END,
        up.like_count DESC,
        up.created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.search_posts(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_posts(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.search_posts(text, integer) TO authenticated;

-- ============================================================
-- Queries for checking behavior (no need to run, comments only)
-- ============================================================
-- SELECT kind, item_id, title, tags, like_count FROM search_posts('朝活', 20);
-- SELECT kind, item_id, title, tags, like_count FROM search_posts('#朝活', 20);
-- -- '#' is removed, so this must return the same result as the line before
