-- ============================================================
-- 032_search_posts.sql
-- 投稿検索: search_posts RPC
-- ============================================================
-- 背景 (2026-07-15 検索タブ実装):
--   検索タブを「アカウント / 投稿」2セグメント制で新設する。アカウント検索は
--   022_sns_minimum.sql + 025_search_users_escape.sql の search_users を
--   そのまま流用するため、本ファイルは search_posts のみを追加する
--   (アカウント検索用の新規 RPC は作らない)。
--
-- 設計判断:
--   - 戻り値の列は 029_recommend_feed.sql の fetch_mixed_feed_random と
--     完全に同じ 17 列にする。Swift 側の FeedItem デコーダをそのまま使い回し、
--     検索結果を FeedCardListView にそのまま渡せるようにするため
--     (新しい Decodable 型を作らない)。kind は常に 'post' 固定。
--   - マッチ対象は user_posts.title (部分一致) と tags (前方一致) の2つ。
--     本文 (text_jp/text_en) は対象にしない (仕様通り、キャプション/タグのみ)。
--   - クエリ正規化は 025 と同じ LIKE エスケープ (\ % _) に加え、先頭の '#' を
--     除去する (ハッシュタグ入力 "#朝活" のような入力でもタグ前方一致にヒットさせる)。
--   - post 枝の WHERE (ブロックフィルタ / モデレーションフィルタ) は
--     029 の post 枝と一言一句同じにする。検索経由で層1/層2フィルタが抜け穴に
--     ならないようにするため。
--   - 空クエリ (正規化後 '') は 0 行を返すガードを入れる (全件スキャン防止)。
--   - 並び順: タグ完全一致 (大文字小文字無視) を最優先、次にいいね数、次に新しさ。
--     "検索語そのものと同じタグを持つ投稿" が最も意図に近いと判断。
--
-- 適用方法:
--   Supabase Dashboard の SQL Editor で貼り付け実行、または
--   `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/032_search_posts.sql`
--
-- 実行順序: 027 の後 (moderation_config / moderation_status に依存)。何度実行しても安全
-- (CREATE OR REPLACE、新テーブル・新列は追加しない)。
-- ============================================================

CREATE OR REPLACE FUNCTION public.search_posts(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    kind                text,
    item_id             uuid,
    body_jp             text,
    body_en             text,
    tags                text[],
    like_count          integer,
    comment_count       integer,
    created_at          timestamptz,
    author_id           uuid,
    author_name         text,
    author_avatar_url   text,
    is_official_author  boolean,
    is_pro_author       boolean,
    background_id       integer,
    title               text,
    image_path          text,
    image_count         integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH normalized AS (
        -- 先頭の '#' を除去 (ハッシュタグ入力対応) してから LIKE 特殊文字をエスケープ。
        -- raw はエスケープ前の文字列。ORDER BY のタグ完全一致判定は LIKE パターンでなく
        -- 等値比較なので、エスケープ済み q を使うと '_' '%' '\' を含むタグが一致しなくなる
        SELECT
            s.stripped AS raw,
            replace(replace(replace(s.stripped, '\', '\\'), '%', '\%'), '_', '\_') AS q
        FROM (
            SELECT CASE
                       WHEN trim(query) LIKE '#%' THEN substring(trim(query) FROM 2)
                       ELSE trim(query)
                   END AS stripped
        ) s
    )
    SELECT
        'post'::text   AS kind,
        up.id           AS item_id,
        up.text_jp      AS body_jp,
        up.text_en      AS body_en,
        up.tags,
        up.like_count,
        up.comment_count,
        up.created_at,
        u.id           AS author_id,
        u.display_name AS author_name,
        u.avatar_url   AS author_avatar_url,
        false          AS is_official_author,
        COALESCE(u.is_pro, false) AS is_pro_author,
        up.background_id,
        up.title,
        up.image_path,
        up.image_count
    FROM public.user_posts up
    JOIN public.users u ON u.id = up.user_id
    CROSS JOIN normalized n
    WHERE query IS NOT NULL
      AND n.q <> ''
      AND (
        up.title ILIKE '%' || n.q || '%'
        OR EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE t ILIKE n.q || '%'
        )
      )
      AND up.user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND up.moderation_status <> 'rejected'
      AND (
        up.moderation_status <> 'flagged'
        OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
      )
    ORDER BY
        CASE WHEN EXISTS (
            SELECT 1 FROM unnest(up.tags) t WHERE lower(t) = lower(n.raw)
        ) THEN 0 ELSE 1 END,
        up.like_count DESC,
        up.created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.search_posts(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_posts(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.search_posts(text, integer) TO authenticated;

-- ============================================================
-- 動作確認用クエリ (実行不要、コメント)
-- ============================================================
-- SELECT kind, item_id, title, tags, like_count FROM search_posts('朝活', 20);
-- SELECT kind, item_id, title, tags, like_count FROM search_posts('#朝活', 20); -- '#' を除去して同じ結果になること
