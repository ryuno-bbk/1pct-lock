-- ============================================================================
-- 🔴🔴🔴 適用前に必ず読むこと 🔴🔴🔴
--
-- ⚠️ このファイルは public.authors に対する不可逆な DELETE を含みます。
-- ⚠️ 適用前に必ず Supabase Dashboard → Table Editor → authors を開き、
--    「Export data as CSV」で全件ダンプを取得してから実行してください。
--    (060_quote_audit_anonymize.sql のヘッダーが要求したのと同じ注意であり、
--     ロールバック手段はこのダンプからの手動リストアのみです。)
-- ============================================================================

-- ============================================================================
-- 071: authors の実名著者行を削除する (実名全廃方針の未完了分)
--
-- 背景: 060_quote_audit_anonymize.sql は quotes.author_id を匿名著者
--       (Anonymous, id = 0c606f06-0722-46f8-a8e0-f2f906411120) へ全件付け替えた。
--       しかし 060 自身のコメントに明記の通り、
--         「残存名言を全て匿名著者へ (実名全廃)。celebrities の authors 行は
--          残置 (どこからも参照されず不可視)」
--       という状態のまま止まっていた。つまり authors テーブルには今も、
--       実在の著名人・存命人物の実名 (name) / bio_jp / bio_en / image_url が
--       行として残っている。ユーザーが決めた「実名全廃」方針
--       (project_legal_risk_celebrity_names の判断、quotes 側は060で実施済み)
--       の未完了分を、authors 自体から実名行を削除して完了させる。
--
-- やること:
--   Anonymous (匿名著者) と 1% 公式アカウント (020_official_account.sql:29-31 で
--   id = 11111111-1111-1111-1111-111111111111 として作成) の2行以外を
--   authors から削除する。ただし、まだ quotes から参照されている行は
--   NOT EXISTS ガードで保護し、削除対象から除外する。
--
-- NOT EXISTS ガードの理由:
--   quotes.author_id は authors(id) を指す外部キーだが、authors / quotes 自体の
--   CREATE TABLE 文はマイグレーション管理が始まる前 (本リポジトリの migrations/
--   より前) に作成されており、ON DELETE の挙動 (NO ACTION か CASCADE か) を
--   ファイルから確認できない。
--     - もし NO ACTION / RESTRICT であれば、万一まだ実名著者を指す quotes 行が
--       残っていた場合、そのままでは DELETE 自体が FK 違反で止まる
--       (実害は無いが原因調査が手間になる)。
--     - もし CASCADE 相当だった場合は、その quotes 行 (= 名言) が巻き添えで
--       消えてしまう事故になる。
--   NOT EXISTS で「quotes から参照されている行はそもそも削除対象に含めない」
--   ことにより、上記どちらの可能性に対しても構造的に安全側に倒す。
--   060 適用後は全 quotes が Anonymous を指しているはずで、通常はガードに
--   何もヒットしないはずだが、060 適用後に手動 INSERT 等で実名著者を指す
--   quotes 行が万一残っていた場合に備える。ガードに引っかかった行 (= 削除
--   されずに残った実名著者) は検証クエリ (C) で可視化する。0件が正常。
--
-- user_follows への影響:
--   user_follows.author_id は 002_a_user_id.sql:67 で
--   `REFERENCES public.authors(id) ON DELETE CASCADE` と明示的に定義されている。
--   そのため、ここで削除される実名著者を過去にフォローしていたユーザーがいた
--   場合、その user_follows 行は連鎖削除される。実害は無い:
--   020_official_account.sql が「著者個別フォロー」から「1% 公式アカウント
--   フォロー」への移行 (既存フォロー関係をコピーし、元の著者フォロー行は
--   残置するだけの移行) を既に実施済みで、現在の fetch_following_feed も
--   1% 公式アカウントをフォローしているか否かだけを見る設計に変わっている
--   (020_official_account.sql:100-105)。つまりここで連鎖削除される
--   user_follows 行は現行仕様上どこからも参照されない残骸データであり、
--   ユーザー体験への影響はゼロ。
--
-- 冪等性: 再実行しても安全。2回目以降は WHERE 条件に一致する行が既に無いため
--   0 rows で完了する。
-- ============================================================================

BEGIN;

DELETE FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',  -- Anonymous（060 で全名言の付け替え先）
    '11111111-1111-1111-1111-111111111111'   -- 1% 公式アカウント（020_official_account.sql:29-31）
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id);

COMMIT;

-- ============================================================================
-- 検証クエリ
-- ============================================================================

-- (A) 【適用前に必ず流すこと】これから削除される行の件数 (SELECT のみ、副作用無し)。
--     BEGIN 〜 COMMIT を実行する前に、この2本を別途流してダンプと突き合わせ、
--     Anonymous / 1% 以外の実名行だけが対象になっていることを目視確認すること。
SELECT count(*) AS will_be_deleted
FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id);

-- これから削除される行の name 一覧
SELECT a.id, a.name, a.is_official
FROM public.authors a
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
AND NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.author_id = a.id)
ORDER BY a.name;

-- (B) 【適用後】authors の全件。Anonymous と 1% の2件だけが残っていれば正常。
SELECT id, name, is_official FROM public.authors ORDER BY name;
-- 期待結果: 2 rows (Anonymous, 1%)

-- (C) 【適用後】ガードで消せなかった行 = まだ quotes から参照されている実名著者。
--     0件なら正常。1件以上出た場合は、その著者を参照している quotes 側を
--     060 と同じ方式 (author_id を Anonymous へ付け替え) で処理するまで、
--     この行は意図的に authors に残っている状態になる。放置せず報告すること。
SELECT a.id, a.name, count(q.id) AS quotes_still_referencing
FROM public.authors a
JOIN public.quotes q ON q.author_id = a.id
WHERE a.id NOT IN (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    '11111111-1111-1111-1111-111111111111'
)
GROUP BY a.id, a.name
ORDER BY a.name;
-- 期待結果: 0 rows
