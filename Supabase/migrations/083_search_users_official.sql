-- ============================================================
-- 083_search_users_official.sql
-- ユーザー検索の結果に公式マークを出せるようにする + 運営アカウントの作成
-- ============================================================
-- 背景 (2026-09-09 の点検で発覚):
--   075/076 で公式マーク (users.is_official) を入れたが、**ユーザー検索だけ
--   返り値に含まれていなかった**。フィード / 投稿検索 / タグ / プロフィールは
--   すべて is_official を返しており、検索だけが穴だった:
--     fetch_mixed_feed_random  ✅
--     fetch_following_feed     ✅
--     fetch_tag_feed           ✅
--     search_posts             ✅
--     search_users             ❌  ← ここ
--   運営アカウントを探す人が最初に使うのは検索なので塞ぐ。
--
-- 🔴 RETURNS TABLE の型が変わるので CREATE OR REPLACE では差し替えられない。
--    DROP → CREATE が必須。DROP したら末尾で REVOKE/GRANT を必ず貼り直すこと
--    (2026-07-31 の再発防止ルール)。
--
-- ⚠️ 検索結果にマークが出るのは 1.0.4 以降のアプリだけ。
--    1.0.3 は is_official を読むコード自体を持っていないが、
--    JSON に増えたキーは無視されるだけなので**古いアプリは壊れない**。
--
-- 実行順序: 082 の後。何度実行しても安全
-- ============================================================

DROP FUNCTION IF EXISTS public.search_users(text, integer);

CREATE FUNCTION public.search_users(query text, limit_count integer)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean,
    is_official  boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    WITH escaped AS (
        -- LIKE 特殊文字 (\ % _) をエスケープしてリテラル扱いにする
        SELECT replace(replace(replace(trim(query), '\', '\\'), '%', '\%'), '_', '\_') AS q
    )
    SELECT
        u.id,
        u.display_name,
        u.handle,
        u.avatar_url,
        COALESCE(u.is_pro, false)      AS is_pro,
        COALESCE(u.is_official, false) AS is_official
    FROM public.users u, escaped e
    WHERE query IS NOT NULL
      AND e.q <> ''
      AND (
        u.handle LIKE lower(e.q) || '%'
        OR u.display_name ILIKE '%' || e.q || '%'
      )
      AND u.id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY
        -- 公式アカウントを先頭に寄せる (運営を探しに来た人が一番上で見つかる)
        COALESCE(u.is_official, false) DESC,
        CASE WHEN u.handle LIKE lower(e.q) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

-- 🔴 DROP したので権限を貼り直す (065 と同じ方針: anon は一切触れない)
REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;

COMMENT ON FUNCTION public.search_users(text, integer)
    IS '@handle 前方一致優先 + display_name 部分一致。公式アカウントを先頭に寄せる (083)';
