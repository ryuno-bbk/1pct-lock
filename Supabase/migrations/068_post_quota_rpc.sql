-- ============================================================================
-- 068_post_quota_rpc.sql
-- 残り投稿枠の表示をサーバーの数え方に合わせる (2026-08-01)
-- ============================================================================
-- 【何が起きていたか】
-- 066 で投稿レート制限を「user_posts の現存行カウント」から「rate_events 台帳カウント」へ
-- 変更したが、クライアント側の残数表示 (UserPostService.remainingDailyPostSlots) は
-- 旧方式のまま user_posts を数えていた。結果:
--   投稿を削除する → user_posts の行が減る → 表示上の「今日はあと N 件」は増える
--   → しかしサーバーは rate_events (削除しても減らない) で数えるので投稿は弾かれる
-- = 「残り枠があると表示されているのに投稿できない」という食い違いが発生した。
-- (2026-08-01 実機テストでユーザーが発見)
--
-- 【なぜクライアントが直接数えられないか】
-- rate_events は 066 で RLS 有効 + ポリシー0本 + REVOKE ALL FROM anon, authenticated
-- にしてある (クライアントから台帳を消してレート制限を迂回されないため)。
-- したがって残数取得には SECURITY DEFINER の RPC が要る。
--
-- 【なぜ「残り」ではなく「使用済み」を返すか】
-- 上限値 5 をこのファイルにも書くと、enforce_post_rate_limit (066) と
-- UserPostService.dailyPostLimit (Swift) に加えて3箇所目の定義になり、
-- 同期漏れの事故が起きやすくなる。使用済み件数だけを返し、上限との引き算は
-- 既に定数を持っているクライアント側に任せることで、定義箇所を増やさない。
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_post_quota_used()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    -- 呼び出し元自身の直近24時間の投稿回数 (削除済みを含む)。
    -- auth.uid() 固定なので他人の値は取得できない。
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

-- クライアントから直接呼ぶ関数なので権限を明示的に締める。
-- ⚠️ FROM anon だけでは効かない (CREATE FUNCTION は暗黙で PUBLIC に EXECUTE を付与し、
-- anon は PUBLIC のメンバーなので anon 名指しの REVOKE では剥がれない。063/050 の教訓)。
REVOKE EXECUTE ON FUNCTION public.get_post_quota_used() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_post_quota_used() TO authenticated;

COMMIT;

-- ============================================================================
-- 検証クエリ
-- ============================================================================
-- 未認証から実行できないこと (✅ 閉じている が出れば正常)
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
