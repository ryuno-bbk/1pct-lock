-- ============================================================================
-- 065: 未認証(anon)からの直接アクセスを塞ぐ
--
-- 背景: 2026-08-01 の実測で、publishable キーだけで以下が可能な状態だった。
--   - users / user_posts / user_dreams / authors / quotes の中身が読める
--   - fetch_comments_for_post が未認証で実行できる (050 の権限書き漏れ)
--
-- 原因1: マイグレーション全体に「テーブルレベルの GRANT/REVOKE」が1行も無く、
--        Supabase 既定 (anon/authenticated/service_role に SELECT〜DELETE 付与) のままだった。
-- 原因2: 050 が DROP FUNCTION → CREATE FUNCTION した際、
--        `REVOKE ... FROM anon` は書いたが `FROM PUBLIC` を書かなかった。
--        PostgreSQL は CREATE FUNCTION で暗黙に PUBLIC へ EXECUTE を付与し、
--        anon は PUBLIC のメンバーなので、anon 名指しの REVOKE では剥がれない。
--
-- ⚠️ quotes / authors は意図的に対象外。
--    AppBlockerApp.swift:182 の起動処理がサインイン前に読むため、
--    ここで止めると新規ユーザーの名言が空になる。別途コード側で対応する。
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. 関数の実行権限: fetch_comments_for_post (063 と同型の穴)
-- ----------------------------------------------------------------------------
-- ⚠️ FROM PUBLIC が本体。FROM anon だけでは暗黙の PUBLIC 付与が残る (050 の教訓)
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. ユーザーデータ系テーブルから anon の権限を剥奪
--    (サインイン前に読まれないことを実機コードで確認済み:
--     Onboarding は .rpc/.from が0件、LikeService/BlockService は userId nil で早期 return)
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
-- 3. 今後追加されるテーブルにも anon 権限が付かないようにする
-- ----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;

COMMIT;

-- ============================================================================
-- 検証クエリ (適用後にこれを流して結果を確認する)
-- ============================================================================

-- (A) anon がまだ触れるテーブル。quotes と authors だけが残っていれば正常
SELECT table_name,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS anon_privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND grantee = 'anon'
GROUP BY table_name
ORDER BY table_name;

-- (B) 未認証で実行できる関数が残っていないか全数チェック
--     is_handle_available(text) が 🟠 なのは正常 (サインアップ前に呼ぶ設計)
--     それ以外に 🔴 / 🟠 が出たら、その関数にも上の3行と同じ REVOKE/GRANT が必要
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
