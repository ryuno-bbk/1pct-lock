-- ============================================================
-- 083_search_users_official.sql
-- Allow the official badge to show in user search results + create the operator account
-- ============================================================
-- Background (found in the 2026-09-09 review):
--   075/076 added the official badge (users.is_official), but **only user search did not
--   include it in its return value**. Feed / post search / tags / profile
--   all return is_official; only search was a hole:
--     fetch_mixed_feed_random  ✅
--     fetch_following_feed     ✅
--     fetch_tag_feed           ✅
--     search_posts             ✅
--     search_users             ❌  ← here
--   Search is the first thing people use when looking for the operator account, so close the hole.
--
-- 🔴 The RETURNS TABLE type changes, so it cannot be replaced with CREATE OR REPLACE.
--    DROP → CREATE is required. After a DROP, always re-apply REVOKE/GRANT at the end
--    (rule to prevent a repeat of 2026-07-31).
--
-- ⚠️ The badge shows in search results only in app 1.0.4 and later.
--    1.0.3 does not even have the code that reads is_official, but
--    extra keys in the JSON are simply ignored, so **old apps do not break**.
--
-- Run order: after 082. Safe to run any number of times
-- ============================================================

DROP FUNCTION IF EXISTS public.search_users(text, integer);

CREATE FUNCTION public.search_users(query text, limit_count integer)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean,
    is_official  boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    WITH escaped AS (
        -- Escape the LIKE special characters (\ % _) so they are treated as literals
        SELECT replace(replace(replace(trim(query), '\', '\\'), '%', '\%'), '_', '\_') AS q
    )
    SELECT
        u.id,
        u.display_name,
        u.handle,
        u.avatar_url,
        COALESCE(u.is_pro, false)      AS is_pro,
        COALESCE(u.is_official, false) AS is_official
    FROM public.users u, escaped e
    WHERE query IS NOT NULL
      AND e.q <> ''
      AND (
        u.handle LIKE lower(e.q) || '%'
        OR u.display_name ILIKE '%' || e.q || '%'
      )
      AND u.id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY
        -- Put official accounts first (people looking for the operator find it at the very top)
        COALESCE(u.is_official, false) DESC,
        CASE WHEN u.handle LIKE lower(e.q) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

-- 🔴 We did a DROP, so re-apply the privileges (same policy as 065: anon cannot touch it at all)
REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;

COMMENT ON FUNCTION public.search_users(text, integer)
    IS '@handle 前方一致優先 + display_name 部分一致。公式アカウントを先頭に寄せる (083)';
