-- ============================================================================
-- 070: quotes / authors への未認証(anon)アクセスを塞ぐ (065 の積み残し)
--
-- 背景: 065_close_anon_access.sql は「未認証からユーザーデータ系テーブルが読める」
--       問題を塞いだが、quotes と authors の2テーブルは意図的に対象外にした。
--       065 のヘッダーコメント原文:
--         「⚠️ quotes / authors は意図的に対象外。
--           AppBlockerApp.swift:182 の起動処理がサインイン前に読むため、
--           ここで止めると新規ユーザーの名言が空になる。別途コード側で対応する。」
--       実際に AppBlockerApp.swift の起動 .task 内では、restoreSession() の
--       成否に関わらず QuoteService.shared.loadQuotes() を呼んでおり、
--       サインイン前 (オンボ中) の端末でも anon キーで quotes/authors に
--       アクセスしている。
--
--       とはいえ「未認証の publishable キーだけで quotes/authors の全件が
--       読める」状態は本質的に 065 が塞いだのと同じ種類の穴であり、放置して
--       よい理由にはならない。065 が対象外にしたのは「今すぐ塞ぐとアプリが
--       壊れるから」であって「問題ではないから」ではなかった。本ファイルで
--       積み残しを閉じる。
--
-- 原因: 065 と同じ。マイグレーション全体にテーブルレベルの GRANT/REVOKE が
--       元々1行も無く、Supabase 既定 (anon/authenticated/service_role に
--       SELECT〜DELETE 付与) のままだった。
--
-- やること:
--   1. quotes / authors のテーブル権限から anon (と PUBLIC) を REVOKE
--   2. 2層目として RLS ポリシーも "authors_select_all" / "quotes_select_all"
--      (003_a_rls_rpc.sql:84, :95 で FOR SELECT USING (true) = ロール無指定
--      だった) を FOR SELECT TO authenticated USING (true) に差し替える
--
-- ⚠️ 失敗の出方: 上の §1 (テーブル権限の REVOKE) と §2 (RLS ポリシー) は
--   エラーの出方が違う。REVOKE の方が先に効くため、未認証アクセスは
--   「RLS が空集合を返す」のではなく **PostgREST が権限エラー (401/403) を返す**。
--   RLS 単独 (GRANT が残っている状態) なら 200 + 空配列になるが、本ファイルは
--   両方を入れるのでエラー側になる。将来ここを調査する人が
--   「0件で返る」と誤診しないよう明記しておく。
--
-- ⚠️ クライアント側の対応 (同時に入れる。適用順序はどちらが先でもよい):
--   1. AppBlockerApp.swift の起動 .task は、サインイン済みのときだけ
--      QuoteService.enableSupabase() へ切り替える。未サインイン時は
--      LocalQuoteProvider (バンドルの Quotes.json 68件 = 060 適用後の本番 quotes と
--      同一内容) から読むため、名言が空になることはない。
--   2. .onChange(of: userAuth.isSignedIn) でサインイン直後に quotes/authors を
--      読み直す (これが無いと、サインアップ直後のユーザーは再起動するまで
--      authors が空 = is_official バッジが付かない。070 とは独立した既存バグ)。
--   なお SupabaseQuoteProvider.swift:86-89 は fetch 失敗時に LocalQuoteProvider へ
--   フォールバックする実装なので、仮にこのマイグレーションだけ先に適用しても
--   名言が空になることはない (権限エラー → ローカル68件で表示が続く)。
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. テーブル権限: quotes / authors から anon を剥奪
-- ----------------------------------------------------------------------------
-- テーブルは関数と違い、CREATE TABLE 時に PUBLIC への暗黙の権限付与は無い
-- (Supabase の既定権限は anon/authenticated/service_role という具体ロールに
-- 直接 GRANT する運用のため)。したがって実際に効くのは anon 名指しの REVOKE の方。
-- それでも 065 の教訓 (「ロール名指しの REVOKE だけでは剥がれない権限経路が
-- あった」= 050/063 の関数 EXECUTE 権限の件) を踏まえ、065 との一貫性と
-- 防御的な意図で PUBLIC からも REVOKE しておく (万一 将来誰かが
-- `GRANT ALL ON quotes TO PUBLIC` のような操作をしても、この REVOKE 以降に
-- 再度 GRANT されない限り無害なままにするための保険)。
REVOKE ALL ON TABLE public.quotes  FROM PUBLIC;
REVOKE ALL ON TABLE public.quotes  FROM anon;
REVOKE ALL ON TABLE public.authors FROM PUBLIC;
REVOKE ALL ON TABLE public.authors FROM anon;

-- ----------------------------------------------------------------------------
-- 2. RLS ポリシー: SELECT を authenticated ロール限定に差し替え (2層目の防御)
-- ----------------------------------------------------------------------------
-- 003_a_rls_rpc.sql:84 (authors_select_all) / :95 (quotes_select_all) は
-- どちらも USING (true) のみでロール指定が無く、既定の PUBLIC (= anon を含む
-- 全ロール) に適用されていた。上の REVOKE とは独立したレイヤーとして、
-- ポリシー自体を authenticated 限定に絞る (万一テーブル権限だけ何らかの理由で
-- 元に戻っても、RLS 側で未認証アクセスが止まるようにするため)。
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
-- 検証クエリ (適用後にこれを流して結果を確認する)
-- ============================================================================

-- (A) anon がまだ触れるテーブル一覧 (065 の検証クエリ (A) と同じ形)。
--     quotes / authors がここに出てこなければ正常。065 適用済みなら他のテーブルも
--     全て0件のはずなので、本ファイル適用後はこのクエリ自体が0件になる。
SELECT table_name,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS anon_privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND grantee = 'anon'
  AND table_name IN ('quotes', 'authors')
GROUP BY table_name
ORDER BY table_name;
-- 期待結果: 0 rows

-- (B) quotes / authors の RLS ポリシー一覧。roles 列が {authenticated} に
--     なっていることを確認する (差し替え前は {public} だった)。
SELECT schemaname, tablename, policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('quotes', 'authors')
ORDER BY tablename, policyname;
-- 期待結果: authors_select_all / quotes_select_all の2行、どちらも roles = {authenticated}
