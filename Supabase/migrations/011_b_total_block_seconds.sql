-- ============================================================
-- 011_b_total_block_seconds.sql
-- S13: 他人プロフィールに累計ロック時間を表示するための RPC
-- ============================================================
-- 目的:
--   block_sessions の RLS は「自分のみ SELECT 可」を維持したまま、
--   合計値だけ誰でも取得できる SECURITY DEFINER 関数を追加。
--   (詳細レコード = いつ何時間ブロックしたか はプライバシー保護)
--
-- 実行順序: 010 完了後。何度実行しても安全 (CREATE OR REPLACE)
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
