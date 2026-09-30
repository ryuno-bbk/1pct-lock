-- ============================================================================
-- 068_post_quota_rpc.sql
-- Make the remaining post quota display match the way the server counts (2026-08-01)
-- ============================================================================
-- [What was happening]
-- 066 changed the post rate limit from "counting existing rows in user_posts" to "counting the
-- rate_events ledger", but the client-side remaining count display
-- (UserPostService.remainingDailyPostSlots) still counted user_posts the old way. Result:
--   delete a post → fewer rows in user_posts → the displayed "今日はあと N 件" ("N more today")
--   goes up
--   → but the server counts rate_events (which does not go down on delete), so the post is rejected
-- = a mismatch where "it shows slots remaining but you cannot post".
-- (found by the user in real device testing on 2026-08-01)
--
-- [Why the client cannot count directly]
-- In 066, rate_events was set to RLS enabled + 0 policies + REVOKE ALL FROM anon, authenticated
-- (so the client cannot delete the ledger to bypass the rate limit).
-- So getting the remaining count requires a SECURITY DEFINER RPC.
--
-- [Why it returns "used" and not "remaining"]
-- Writing the limit value 5 in this file too would make it a 3rd definition, in addition to
-- enforce_post_rate_limit (066) and UserPostService.dailyPostLimit (Swift), and accidents from
-- them getting out of sync become more likely. Returning only the used count and leaving the
-- subtraction from the limit to the client, which already has the constant, avoids adding
-- another definition.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_post_quota_used()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    -- The caller's own post count in the last 24 hours (including deleted ones).
    -- It is fixed to auth.uid(), so other people's values cannot be fetched.
    SELECT count(*)::int
    FROM public.rate_events
    WHERE user_id = auth.uid()
      AND kind = 'post'
      AND created_at > now() - interval '24 hours';
$$;

COMMENT ON FUNCTION public.get_post_quota_used() IS
    '直近24時間の自分の投稿回数 (rate_events 台帳ベース、削除済みも含む)。'
    'PostConfirmView の残り枠表示用。上限との引き算はクライアント側 '
    '(UserPostService.dailyPostLimit) で行う';

-- This function is called directly from the client, so tighten its permissions explicitly.
-- ⚠️ FROM anon alone does not work (CREATE FUNCTION implicitly grants EXECUTE to PUBLIC, and
-- anon is a member of PUBLIC, so a REVOKE naming anon does not remove it. Lesson from 063/050).
REVOKE EXECUTE ON FUNCTION public.get_post_quota_used() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_post_quota_used() TO authenticated;

COMMIT;

-- ============================================================================
-- Verification query
-- ============================================================================
-- Must not be executable without authentication (normal if "✅ 閉じている" ("closed") appears)
SELECT p.proname,
       CASE
         WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                      WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
              THEN '🔴 PUBLIC(未認証でも実行可)'
         WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                      WHERE a.grantee = 'anon'::regrole::oid AND a.privilege_type = 'EXECUTE')
              THEN '🟠 anon に付与'
         ELSE '✅ 閉じている'
       END AS verdict
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_post_quota_used';
