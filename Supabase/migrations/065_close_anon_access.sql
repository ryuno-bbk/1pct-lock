-- ============================================================================
-- 065: close direct access from unauthenticated users (anon)
--
-- Background: measurements on 2026-08-01 showed that the following were possible with only the
-- publishable key:
--   - the contents of users / user_posts / user_dreams / authors / quotes could be read
--   - fetch_comments_for_post could be executed without authentication (050 missed the permissions)
--
-- Cause 1: the migrations had not a single line of "table-level GRANT/REVOKE", so they
--        stayed at the Supabase default (SELECT to DELETE granted to anon/authenticated/service_role).
-- Cause 2: when 050 did DROP FUNCTION → CREATE FUNCTION,
--        it wrote `REVOKE ... FROM anon` but not `FROM PUBLIC`.
--        PostgreSQL implicitly grants EXECUTE to PUBLIC on CREATE FUNCTION, and
--        anon is a member of PUBLIC, so a REVOKE naming anon does not remove it.
--
-- ⚠️ quotes / authors are intentionally excluded.
--    The launch process in AppBlockerApp.swift:182 reads them before sign-in, so
--    stopping them here would leave new users with no quotes. This is handled separately in the
--    code.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Function execute permission: fetch_comments_for_post (the same kind of hole as 063)
-- ----------------------------------------------------------------------------
-- ⚠️ FROM PUBLIC is the real fix. With FROM anon alone, the implicit PUBLIC grant remains (lesson
-- from 050)
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Revoke anon's permissions on user data tables
--    (confirmed in the real app code that they are not read before sign-in:
--     Onboarding has 0 .rpc/.from calls, LikeService/BlockService return early when userId is nil)
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.users                    FROM anon;
REVOKE ALL ON TABLE public.user_posts               FROM anon;
REVOKE ALL ON TABLE public.user_comments            FROM anon;
REVOKE ALL ON TABLE public.user_dreams              FROM anon;
REVOKE ALL ON TABLE public.user_onboarding_profiles FROM anon;
REVOKE ALL ON TABLE public.block_sessions           FROM anon;
REVOKE ALL ON TABLE public.user_reports             FROM anon;
REVOKE ALL ON TABLE public.user_blocks              FROM anon;
REVOKE ALL ON TABLE public.user_appeals             FROM anon;
REVOKE ALL ON TABLE public.user_likes               FROM anon;
REVOKE ALL ON TABLE public.user_follows             FROM anon;
REVOKE ALL ON TABLE public.user_notifications       FROM anon;
REVOKE ALL ON TABLE public.post_views               FROM anon;
REVOKE ALL ON TABLE public.moderation_config        FROM anon;

-- ----------------------------------------------------------------------------
-- 3. Make sure tables added in the future do not get anon permissions either
-- ----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;

COMMIT;

-- ============================================================================
-- Verification queries (run these after applying and check the results)
-- ============================================================================

-- (A) Tables anon can still touch. Normal if only quotes and authors remain
SELECT table_name,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS anon_privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND grantee = 'anon'
GROUP BY table_name
ORDER BY table_name;

-- (B) Full check that no functions remain executable without authentication
--     is_handle_available(text) showing 🟠 is normal (designed to be called before sign-up)
--     If any other 🔴 / 🟠 appears, that function also needs the same REVOKE/GRANT as the 3 lines
--     above
SELECT p.proname AS fn,
       pg_get_function_identity_arguments(p.oid) AS args,
       CASE
         WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                      WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
              THEN '🔴 PUBLIC(未認証でも実行可)'
         WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                      WHERE a.grantee = 'anon'::regrole::oid AND a.privilege_type = 'EXECUTE')
              THEN '🟠 anon に付与'
         ELSE '✅ 閉じている'
       END AS verdict
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prorettype <> 'trigger'::regtype
ORDER BY verdict, p.proname;
