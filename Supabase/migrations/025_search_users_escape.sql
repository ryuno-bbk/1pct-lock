-- ============================================================
-- 025_search_users_escape.sql
-- Fix unescaped LIKE wildcards in search_users
-- ============================================================
-- Background (pointed out in the 2026-07-07 Fable review):
--   search_users in 022 concatenated query directly into the LIKE / ILIKE pattern, so
--   search terms with "%" or "_" returned unintended match-everything results
--   (e.g. a single "_" made every handle count as a prefix match).
--   Not a security problem (only already public profile info is returned), but
--   the search results break, so the function is replaced with escaping added.
--   Otherwise the logic is the same as 022 (handle prefix match first + display_name partial match,
--   excluding users you blocked).
--
-- How to apply:
--   On an environment with 022 applied, paste and run it in the SQL Editor of the Supabase
--   Dashboard, or `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/025_search_users_escape.sql`
--
-- Run order: after 022 (order relative to 023/024 does not matter). Safe to run any number of times
-- ============================================================

CREATE OR REPLACE FUNCTION public.search_users(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH escaped AS (
        -- Escape LIKE special characters (\ % _) so they are treated as literals
        SELECT replace(replace(replace(trim(query), '\', '\\'), '%', '\%'), '_', '\_') AS q
    )
    SELECT
        u.id,
        u.display_name,
        u.handle,
        u.avatar_url,
        COALESCE(u.is_pro, false) AS is_pro
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
        CASE WHEN u.handle LIKE lower(e.q) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

-- GRANT is the same as 022 (authenticated only). CREATE OR REPLACE keeps privileges, but
-- they are declared again for idempotency and clarity.
REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;
