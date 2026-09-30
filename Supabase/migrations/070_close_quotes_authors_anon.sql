-- ============================================================================
-- 070: close unauthenticated (anon) access to quotes / authors (left over from 065)
--
-- Background: 065_close_anon_access.sql closed the problem "user data tables are readable without
--       authentication", but intentionally left out 2 tables, quotes and authors.
--       Original text of the 065 header comment:
--         "⚠️ quotes / authors are intentionally out of scope.
--           The launch code at AppBlockerApp.swift:182 reads them before sign-in, so
--           blocking them here would leave new users with no quotes. To be handled separately in code."
--       In fact, inside the launch .task of AppBlockerApp.swift, QuoteService.shared.loadQuotes() is
--       called whether restoreSession() succeeds or not, so devices before sign-in (during
--       onboarding) also access quotes/authors with the anon key.
--
--       Still, "all rows of quotes/authors can be read with only the unauthenticated publishable
--       key" is essentially the same kind of hole that 065 closed, and that is no reason to leave it
--       open. 065 left it out "because closing it right away would break the app", not "because it
--       is not a problem". This file closes the leftover.
--
-- Cause: same as 065. The migrations never had a single table-level GRANT/REVOKE, so the Supabase
--       default (SELECT to DELETE granted to anon/authenticated/service_role) was still in place.
--
-- What this does:
--   1. REVOKE anon (and PUBLIC) from the table privileges of quotes / authors
--   2. As a second layer, replace the RLS policies "authors_select_all" / "quotes_select_all"
--      (which were FOR SELECT USING (true) = no role specified, at 003_a_rls_rpc.sql:84, :95)
--      with FOR SELECT TO authenticated USING (true)
--
-- ⚠️ How it fails: §1 above (REVOKE of table privileges) and §2 (RLS policies) fail
--   differently. The REVOKE takes effect first, so an unauthenticated request does not get
--   "an empty set from RLS" but **a permission error (401/403) from PostgREST**.
--   RLS alone (with the GRANT still there) would give 200 + an empty array, but this file
--   adds both, so you get the error. Written down so that anyone investigating this later does not
--   misdiagnose it as "returns 0 rows".
--
-- ⚠️ Client-side changes (shipped together. Either can be applied first):
--   1. The launch .task in AppBlockerApp.swift switches to QuoteService.enableSupabase() only when
--      signed in. When not signed in it reads from LocalQuoteProvider (68 quotes in the bundled
--      Quotes.json = same content as the production quotes after 060), so quotes are never empty.
--   2. .onChange(of: userAuth.isSignedIn) reloads quotes/authors right after sign-in
--      (without it, a user who just signed up has empty authors until restart = no is_official
--      badge. An existing bug independent of 070).
--   Also, SupabaseQuoteProvider.swift:86-89 falls back to LocalQuoteProvider when the fetch fails,
--   so even if only this migration were applied first, quotes would never be empty
--   (permission error → the 68 local quotes keep showing).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Table privileges: remove anon from quotes / authors
-- ----------------------------------------------------------------------------
-- Unlike functions, tables get no implicit grant to PUBLIC at CREATE TABLE
-- (Supabase default privileges GRANT directly to the concrete roles anon/authenticated/service_role).
-- So the REVOKE that actually has an effect is the one naming anon.
-- Still, given the lesson from 065 ("there was a privilege path that a REVOKE naming the role did
-- not remove" = the EXECUTE privilege on functions in 050/063), also REVOKE from PUBLIC for
-- consistency with 065 and as a defensive measure (a safety net so that even if someone later runs
-- something like `GRANT ALL ON quotes TO PUBLIC`, it stays harmless unless it is granted again after
-- this REVOKE).
REVOKE ALL ON TABLE public.quotes  FROM PUBLIC;
REVOKE ALL ON TABLE public.quotes  FROM anon;
REVOKE ALL ON TABLE public.authors FROM PUBLIC;
REVOKE ALL ON TABLE public.authors FROM anon;

-- ----------------------------------------------------------------------------
-- 2. RLS policies: restrict SELECT to the authenticated role (second layer of defense)
-- ----------------------------------------------------------------------------
-- 003_a_rls_rpc.sql:84 (authors_select_all) / :95 (quotes_select_all) both had only USING (true)
-- with no role, so they applied to the default PUBLIC (= all roles, including anon). As a layer
-- independent of the REVOKE above, narrow the policies themselves to authenticated (so that even if
-- only the table privileges were somehow restored, RLS still stops unauthenticated access).
DROP POLICY IF EXISTS "authors_select_all" ON public.authors;
CREATE POLICY "authors_select_all"
    ON public.authors FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "quotes_select_all" ON public.quotes;
CREATE POLICY "quotes_select_all"
    ON public.quotes FOR SELECT
    TO authenticated
    USING (true);

COMMIT;

-- ============================================================================
-- Verification queries (run these after applying and check the results)
-- ============================================================================

-- (A) List of tables anon can still touch (same form as verification query (A) in 065).
--     Correct if quotes / authors do not appear here. If 065 is applied, all other tables should
--     also be 0 rows, so after applying this file the query itself returns 0 rows.
SELECT table_name,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS anon_privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND grantee = 'anon'
  AND table_name IN ('quotes', 'authors')
GROUP BY table_name
ORDER BY table_name;
-- Expected result: 0 rows

-- (B) List of RLS policies on quotes / authors. Check that the roles column is {authenticated}
--     (before the replacement it was {public}).
SELECT schemaname, tablename, policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('quotes', 'authors')
ORDER BY tablename, policyname;
-- Expected result: 2 rows, authors_select_all / quotes_select_all, both with roles = {authenticated}
