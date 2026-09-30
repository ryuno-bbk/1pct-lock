-- ============================================================================
-- 🔴🔴🔴 Read this before applying 🔴🔴🔴
--
-- ⚠️ This file contains an irreversible DELETE on public.authors.
-- ⚠️ Before applying, always open Supabase Dashboard → Table Editor → authors,
--    take a full dump with "Export data as CSV", and only then run it.
--    (This is the same caution that the header of 060_quote_audit_anonymize.sql required,
--     and the only way to roll back is a manual restore from this dump.)
-- ============================================================================

-- ============================================================================
-- 071: delete the real-name author rows from authors (the unfinished part of the policy to remove all
-- real names)
--
-- Background: 060_quote_audit_anonymize.sql reassigned all quotes.author_id to the anonymous author
--       (Anonymous, id = 0c606f06-0722-46f8-a8e0-f2f906411120).
--       However, as written in 060's own comment, it stopped in the state:
--         "All remaining quotes go to the anonymous author (all real names removed). The authors
--          rows of celebrities are kept (not referenced from anywhere, invisible)"
--       So the authors table still has, as rows, the real names (name) / bio_jp / bio_en /
--       image_url of real famous people, including living people. This completes the unfinished
--       part of the "remove all real names" policy decided by the user
--       (decision in project_legal_risk_celebrity_names; the quotes side was done in 060)
--       by deleting the real-name rows from authors itself.
--
-- What this does:
--   Delete from authors everything except 2 rows: Anonymous (the anonymous author) and the 1%
--   official account (created in 020_official_account.sql:29-31 as
--   id = 11111111-1111-1111-1111-111111111111). However, rows still referenced from quotes are
--   protected by a NOT EXISTS guard and excluded from the deletion.
--
-- Why the NOT EXISTS guard:
--   quotes.author_id is a foreign key to authors(id), but the CREATE TABLE statements of authors /
--   quotes themselves were run before migration management started (before migrations/ in this
--   repository), so the ON DELETE behavior (NO ACTION or CASCADE) cannot be checked from the files.
--     - If it is NO ACTION / RESTRICT and some quotes rows still point to a real-name author,
--       the DELETE itself would stop on an FK violation
--       (no real harm, but finding the cause takes effort).
--     - If it is effectively CASCADE, those quotes rows (= quotes) would be deleted along with it,
--       which would be an accident.
--   With NOT EXISTS, "rows referenced from quotes are not included in the deletion at all", so it
--   is structurally on the safe side for both possibilities.
--   After 060 is applied, all quotes should point to Anonymous and the guard should normally hit
--   nothing, but this covers the case where quotes rows pointing to a real-name author still remain,
--   e.g. from a manual INSERT after 060. Rows caught by the guard (= real-name authors left
--   undeleted) are made visible by check query (C). 0 rows is normal.
--
-- Effect on user_follows:
--   user_follows.author_id is explicitly defined in 002_a_user_id.sql:67 as
--   `REFERENCES public.authors(id) ON DELETE CASCADE`.
--   So if any user followed a real-name author deleted here in the past, those user_follows
--   rows are deleted in cascade. There is no real harm:
--   020_official_account.sql already migrated from "following individual authors" to "following
--   the 1% official account" (a migration that copied existing follow relations and just left the
--   original author follow rows in place), and the current fetch_following_feed was also changed to
--   only look at whether the user follows the 1% official account
--   (020_official_account.sql:100-105). So the user_follows rows deleted in cascade here are
--   leftover data not referenced anywhere under the current spec, and the effect on user experience
--   is zero.
--
-- Idempotency: safe to run again. From the 2nd run on, no rows match the WHERE condition anymore,
--   so it finishes with 0 rows.
-- ============================================================================

BEGIN;

DELETE FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',  -- Anonymous (the author that 060 reassigned all quotes to)
    '11111111-1111-1111-1111-111111111111'   -- 1% official account (020_official_account.sql:29-31)
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id);

COMMIT;

-- ============================================================================
-- Check queries
-- ============================================================================

-- (A) [MUST run before applying] Number of rows about to be deleted (SELECT only, no side effects).
--     Before running BEGIN ... COMMIT, run these 2 separately, compare with the dump, and visually
--     confirm that only real-name rows other than Anonymous / 1% are targeted.
SELECT count(*) AS will_be_deleted
FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id);

-- List of names of the rows about to be deleted
SELECT a.id, a.name, a.is_official
FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id)
ORDER BY a.name;

-- (B) [After applying] All rows of authors. Normal if only the 2 rows Anonymous and 1% remain.
SELECT id, name, is_official FROM public.authors ORDER BY name;
-- Expected result: 2 rows (Anonymous, 1%)

-- (C) [After applying] Rows the guard could not delete = real-name authors still referenced from
--     quotes. 0 rows is normal. If 1 or more appear, those rows intentionally stay in authors until
--     the quotes that reference that author are handled the same way as 060 (reassign author_id to
--     Anonymous). Do not leave it as is; report it.
SELECT a.id, a.name, count(q.id) AS quotes_still_referencing
FROM public.authors a
JOIN public.quotes q ON q.author_id = a.id
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
GROUP BY a.id, a.name
ORDER BY a.name;
-- Expected result: 0 rows
