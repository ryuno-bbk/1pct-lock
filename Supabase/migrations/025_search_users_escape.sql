-- ============================================================
-- 025_search_users_escape.sql
-- search_users の LIKE ワイルドカード未エスケープ修正
-- ============================================================
-- 背景 (2026-07-07 Fable レビュー指摘):
--   022 の search_users は query をそのまま LIKE / ILIKE パターンに連結しており、
--   「%」「_」を含む検索語で意図しない全件マッチ的な結果が返る
--   (例: 「_」1文字で全ハンドルが前方一致扱いになる)。
--   セキュリティ問題ではない (返るのは元々公開のプロフィール情報のみ) が、
--   検索結果が壊れるためエスケープを追加して関数を差し替える。
--   ロジックはそれ以外 022 と同一 (handle 前方一致優先 + display_name 部分一致、
--   自分がブロックした相手を除外)。
--
-- 適用方法:
--   022 適用済みの環境に対し、Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/025_search_users_escape.sql`
--
-- 実行順序: 022 の後 (023/024 との前後は問わない)。何度実行しても安全
-- ============================================================

CREATE OR REPLACE FUNCTION public.search_users(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
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
        COALESCE(u.is_pro, false) AS is_pro
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
        CASE WHEN u.handle LIKE lower(e.q) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

-- GRANT は 022 と同一 (authenticated のみ)。CREATE OR REPLACE では権限は維持されるが、
-- 冪等性と明示性のため再宣言する。
REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;
