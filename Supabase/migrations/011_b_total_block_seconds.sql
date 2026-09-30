-- ============================================================
-- 011_b_total_block_seconds.sql
-- S13: RPC to show total lock time on other users' profiles
-- ============================================================
-- Purpose:
--   Keep the block_sessions RLS as "only the owner can SELECT", and
--   add a SECURITY DEFINER function that lets anyone get only the total.
--   (Detailed records = when and for how many hours someone blocked, stay private)
--
-- Run order: after 010. Safe to run any number of times (CREATE OR REPLACE)
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_total_block_seconds(target_user_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE(SUM(duration_seconds), 0)::integer
    FROM public.block_sessions
    WHERE user_id = target_user_id
      AND duration_seconds IS NOT NULL;
$$;

REVOKE EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_total_block_seconds(uuid)
    IS 'プロフィール画面で他人の累計ロック秒数を表示する。詳細は RLS で隠し、合計のみ公開';
