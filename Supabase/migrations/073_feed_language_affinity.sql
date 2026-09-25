-- ============================================================================
-- 073_feed_language_affinity.sql
-- フィードで「閲覧者と同じ言語の投稿」を優先できる土台を追加する (2026-08-01)
-- ============================================================================
--
-- 【目的】
-- 投稿者の端末言語 (user_posts.lang) と閲覧者の端末言語 (users.lang) を保存し、
-- fetch_mixed_feed_random のスコアリングに「同じ言語ならボーナス」の項を追加する。
-- ただし本ファイル適用直後の重みは 0 (無効) にして出荷する。理由は §3 参照。
--
-- 【🔴 絶対厳守: 引数も RETURNS TABLE も変えない】
-- fetch_mixed_feed_random(limit_count integer DEFAULT 50, seed text DEFAULT NULL) の
-- シグネチャと戻り値の列は 063_feed_seeded_shuffle.sql から一切変更しない。
-- CREATE OR REPLACE FUNCTION のみで完結させる (DROP FUNCTION は書かない)。
-- CREATE OR REPLACE なら既存の GRANT/REVOKE (064 で修正した権限) がそのまま維持される
-- ため、064 のような「置換後に anon が実行可能に戻ってしまう」事故が起きない。
-- ⚠️ もし将来この関数の引数や戻り値を変える必要が出たら、DROP FUNCTION が必須になり、
-- 064 と同じ REVOKE FROM PUBLIC / FROM anon + GRANT TO authenticated を
-- 必ず同じファイルの末尾に書くこと (063 が一度これを漏らして本番で全投稿が
-- 未認証で読める状態を作った教訓)。
--
-- 【設計判断】
--   1. lang 列は user_posts / users の2つだけに追加する。quotes には追加しない
--      (公式名言は特定の投稿者の端末言語という概念が無いため、同一言語ボーナスの
--      対象は UGC 投稿 (kind='post') のみで良い)。
--   2. CHECK 制約は付けない。AppLanguage enum (en/ja) は将来 case が増える前提の設計
--      (AppLanguage.swift のコメント参照) で、CHECK を付けると新言語追加のたびに
--      マイグレーションが必要になり ADD COLUMN の "詰みにくさ" と矛盾する。
--      想定値は AppLanguage の rawValue ("en" / "ja" / 将来の追加分) だが、
--      DB 側では自由な text として保持する。
--   3. 重み w_same_lang の初期値は 0。ローンチ時点のコーパスはほぼ100%日本語
--      (法務URL公開までの経緯・実名廃止等、直近のコミット群参照) で、
--      「同じ言語を優先した結果フィードの多様性やエンゲージメントがどう動くか」を
--      判断できるデータが無い。0 なら本ファイル適用前後でフィードの出力が
--      完全に同一になることを検証できる (§5 の検証手順 (C))。英語圏の投稿が
--      増えてきたら SQL Editor で本関数を CREATE OR REPLACE し、w_same_lang の
--      数値を上げるだけで有効化できる。アプリ側の変更・再デプロイは不要
--      (029/063 と同じ「params CTE だけ書き換えれば良い」設計を踏襲)。
--   4. 閲覧者の言語は引数を増やさず (SELECT u.lang FROM public.users u WHERE u.id = auth.uid())
--      で取得する。auth.uid() は本関数がすでに follow/block フィルタで使っている
--      (063:137-139, 154-158) ので SECURITY DEFINER 下でも問題なく解決できる。
--   5. インデックスは追加しない。fetch_mixed_feed_random は user_posts.lang を
--      WHERE 句の絞り込み条件ではなく scored CTE 内の CASE 式 (スコア加点) でしか
--      参照しない。本関数は既に created_at > now() - interval '30 days' で
--      絞り込んだ上で残り全行を毎回スキャンする設計 (063:164, idx_user_posts_created_at
--      を使う想定) なので、lang 単体の部分インデックスを足しても本関数の実行計画は
--      変わらない (絞り込みに使われないインデックスは意味が無い)。将来 lang を
--      WHERE 句で使うようになったら (例: 「この言語だけ表示」フィルタ機能) その時点で
--      idx_user_posts_created_at のような複合/部分インデックスを検討すればよい。
--
-- 実行順序: 072 完了後。何度実行しても安全 (ADD COLUMN IF NOT EXISTS +
-- CREATE OR REPLACE FUNCTION の冪等パターン)。
-- ============================================================================

-- ============================================================================
-- 1. lang 列の追加
-- ============================================================================
ALTER TABLE public.user_posts ADD COLUMN IF NOT EXISTS lang text;
ALTER TABLE public.users      ADD COLUMN IF NOT EXISTS lang text;

COMMENT ON COLUMN public.user_posts.lang IS
    '投稿者の端末言語。投稿時にクライアントが mainLanguage (UserDefaults) の値を書き込む '
    '(UserPostService.createPost / createPostV2)。想定値は AppLanguage の rawValue '
    '("en"/"ja"、将来 case 追加で増える) だが CHECK 制約は付けない。'
    '073: fetch_mixed_feed_random の同一言語ボーナス判定に使う。旧投稿は NULL '
    '(NULL は「言語不明」として同一言語ボーナスの対象外= 通常のスコアのまま)';

COMMENT ON COLUMN public.users.lang IS
    '閲覧者(本人)の端末言語。サインイン時 (AppBlockerApp.syncSignInState) と '
    '設定の言語 Picker 変更時 (SettingsListView の @AppStorage("mainLanguage") を '
    'UserDefaults.didChangeNotification 経由で検知) にクライアントが同期する。'
    '想定値は AppLanguage の rawValue。CHECK 制約は付けない (将来の言語追加に備える)。'
    '073: fetch_mixed_feed_random がこの列を読んで同一言語ボーナスの基準にする。'
    '未同期のユーザーは NULL (同一言語ボーナスは常に0扱い)';

-- ============================================================================
-- 2. fetch_mixed_feed_random: 同一言語ボーナス項を追加 (CREATE OR REPLACE のみ)
-- ============================================================================
-- 063 の現行定義を丸ごとコピーし、変更点は以下の2箇所のみ:
--   (a) params CTE に w_same_lang (初期値0) と viewer_lang を追加
--   (b) post 分岐のスコア式に「up.lang が viewer_lang と一致すれば w_same_lang を加点」を追加
-- それ以外 (quote 分岐 / ranked / quota / 最終 SELECT / ORDER BY / LIMIT) は無変更。
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(
    limit_count integer DEFAULT 50,
    seed text DEFAULT NULL
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
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    WITH params AS MATERIALIZED (
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ジッターの最大値 (探索性)
            0.45 ::double precision AS quote_base,         -- 062: 名言はユーザー投稿より控えめに
            2    ::integer          AS author_cap,         -- 1フィードあたり同一投稿者の最大件数 (postsのみ)
            15   ::integer          AS quote_cap,          -- 062: 投稿が十分ある時の名言枠の下限 (適応型)
            -- 063: 並びの種。アプリが毎回新しい値を渡す。省略時はサーバーで1つ作る
            COALESCE(seed, gen_random_uuid()::text) AS shuffle_seed,
            -- 073: 同一言語ボーナス。初期値0 = 無効 (有効化のしかたはファイル末尾を参照)
            0.0  ::double precision AS w_same_lang,
            -- 073: 閲覧者(自分)の端末言語。引数を増やさずサブクエリで取得する。
            -- users.lang が未同期 (NULL) なら同一言語ボーナスは常に0扱いになる
            (SELECT u.lang FROM public.users u WHERE u.id = auth.uid()) AS viewer_lang
    ),
    scored AS (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            CASE WHEN q.category IS NULL THEN '{}'::text[] ELSE ARRAY[q.category] END AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id,
            NULL::text    AS title,
            NULL::text    AS image_path,
            NULL::integer AS image_count,
            (
                p.quote_base
                + p.w_like * ln(1 + q.like_count)
                + p.w_comment * ln(1 + q.comment_count)
                -- 063: seed 由来の一様ジッター (同じ seed なら同じ並び / 変えれば必ず変わる)
                + p.w_jitter * (
                    ('x' || substr(md5(q.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        CROSS JOIN params p

        UNION ALL

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
            up.image_count,
            (
                p.w_recency / (
                    1 + GREATEST(EXTRACT(EPOCH FROM (now() - up.created_at)) / 3600.0, 0)
                        / p.recency_half_hours
                )
                + p.w_like * ln(1 + up.like_count)
                + p.w_comment * ln(1 + up.comment_count)
                + CASE
                    WHEN EXISTS (
                        SELECT 1 FROM public.user_follows f
                        WHERE f.follower_id = auth.uid() AND f.followed_user_id = u.id
                    ) THEN p.w_follow
                    ELSE 0
                  END
                - p.w_seen * ln(1 + COALESCE(pv.view_count, 0))
                -- 073: 投稿者の言語 (up.lang) が閲覧者の言語 (p.viewer_lang) と一致すれば加点。
                -- どちらかが NULL (旧投稿 / lang 未同期ユーザー) なら加点しない (0のまま、減点もしない)
                + CASE
                    WHEN up.lang IS NOT NULL AND up.lang = p.viewer_lang THEN p.w_same_lang
                    ELSE 0
                  END
                + p.w_jitter * (
                    ('x' || substr(md5(up.id::text || p.shuffle_seed), 1, 8))::bit(32)::bigint::double precision
                    / 4294967296.0
                  )
            ) AS score
        FROM public.user_posts up
        JOIN public.users u ON u.id = up.user_id
        LEFT JOIN public.post_views pv
            ON pv.post_id = up.id AND pv.viewer_id = auth.uid()
        CROSS JOIN params p
        WHERE up.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
          AND up.moderation_status <> 'rejected'
          AND (
            up.moderation_status <> 'flagged'
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
          AND up.created_at > now() - interval '30 days'
    ),
    ranked AS (
        -- posts: 同一投稿者の連投キャップ (052)。
        -- quotes: kind 単位の1パーティション = フィード全体の名言キャップ (062)
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY s.kind,
                                (CASE WHEN s.kind = 'post' THEN s.author_id ELSE NULL END)
                   ORDER BY s.score DESC
               ) AS author_rank
        FROM scored s
    ),
    quota AS (
        -- 適応型の名言枠 (062): 投稿候補が limit_count に足りない分は名言で満たす
        SELECT GREATEST(
            p.quote_cap,
            limit_count - (
                SELECT count(*)::integer FROM ranked r2
                WHERE r2.kind = 'post' AND r2.author_rank <= p.author_cap
            )
        ) AS quote_allow
        FROM params p
    )
    SELECT
        r.kind, r.item_id, r.body_jp, r.body_en, r.tags, r.like_count, r.comment_count, r.created_at,
        r.author_id, r.author_name, r.author_avatar_url, r.is_official_author, r.is_pro_author,
        r.background_id, r.title, r.image_path, r.image_count
    FROM ranked r
    CROSS JOIN params p
    CROSS JOIN quota q
    WHERE (r.kind = 'quote' AND r.author_rank <= q.quote_allow)
       OR (r.kind = 'post'  AND r.author_rank <= p.author_cap)
    ORDER BY r.score DESC
    LIMIT limit_count;
$$;

-- ⚠️ CREATE OR REPLACE FUNCTION は既存の GRANT/REVOKE を保持する (DROP しない限り
-- 権限テーブルは触られない)。したがって 064 で設定した
--   REVOKE ... FROM PUBLIC, anon / GRANT ... TO authenticated
-- はここでは何もしなくても維持される。§5 の検証クエリ (B) で実際に維持されている
-- ことを確認すること。
-- ⚠️ 再警告: もし将来この関数を DROP FUNCTION してから作り直す必要が出たら、
-- 063→064 の顛末 (DROP 後に GRANT/REVOKE を書き忘れて未認証で全投稿が読める
-- 状態になった) と同じ事故を避けるため、DROP した同じファイルの末尾に必ず
--   REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM PUBLIC;
--   REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) FROM anon;
--   GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer, text) TO authenticated;
-- を書くこと。

COMMENT ON FUNCTION public.fetch_mixed_feed_random(integer, text) IS
    'おすすめフィード (名言+投稿の混合、スコアリング+seed 由来ジッター)。'
    '052: 同一投稿者は author_cap 件まで / 062: 名言は適応型 quote_cap / '
    '063: 並びの種をアプリが渡す (毎回変えれば必ず並びが変わる。同じ seed なら再現する) / '
    '073: 同一言語ボーナス (w_same_lang、初期値0=無効。SQL Editor で数値を上げるだけで '
    '有効化できる。有効化のしかたは本ファイル末尾のコメント参照)';

-- ============================================================================
-- 3. 有効化のしかた (w_same_lang を 0 から上げるときに読む)
-- ============================================================================
-- 前提: 十分な数のユーザーで user_posts.lang / users.lang が埋まっていること。
-- 具体的には以下の SQL で「lang が NULL の行の割合」を見て、大半のアクティブな
-- 投稿・ユーザーで埋まっていることを確認してから有効化すること:
--
--   SELECT
--     (SELECT count(*) FILTER (WHERE lang IS NULL) FROM public.user_posts
--        WHERE created_at > now() - interval '30 days') AS posts_lang_null_30d,
--     (SELECT count(*) FROM public.user_posts
--        WHERE created_at > now() - interval '30 days')  AS posts_total_30d,
--     (SELECT count(*) FILTER (WHERE lang IS NULL) FROM public.users
--        WHERE total_block_seconds > 0)                   AS users_lang_null_active,
--     (SELECT count(*) FROM public.users
--        WHERE total_block_seconds > 0)                   AS users_total_active;
--
-- 有効化は本関数を CREATE OR REPLACE FUNCTION で再実行し、params CTE の
--   0.0  ::double precision AS w_same_lang,
-- の "0.0" だけを書き換える (引数・RETURNS TABLE は変えないので既存の
-- GRANT/REVOKE はここでも維持される)。
--
-- 数値の目安 (既存の重みとの相対関係):
--   - w_follow = 1.2 (フォロー中の投稿者への定数ボーナス) が「明確に効くが支配的ではない」
--     水準の参考値。同一言語ボーナスも似た性格の項 (関心の強い個別シグナルではなく
--     属性ベースの緩やかな傾斜) なので、まずは 0.3〜0.8 程度から試すことを推奨する。
--   - w_recency の最大値 3.0 や、いいね/コメントの ln() 項 (人気が出れば 0.5〜0.7 × ln(N+1)
--     で simple に 2〜3 点まで積み上がる) と比べて極端に大きくしない限り、
--     新しさ・人気の順位を丸ごと覆すことはない。
--   - w_jitter (最大1.5) より大きい値にすると、同一言語であること自体が探索性ジッターより
--     支配的な要因になる。「言語が違うだけで露出がほぼゼロになる」ような分断を避けたい
--     場合は w_jitter 程度 (1.5 前後) を上限の目安にする。
--   - 1.2 (w_follow) を明確に超える値 (例: 2.0 以上) にすると、「フォローしていない
--     同言語の投稿」が「フォロー中の他言語の投稿」より優先されるようになる。これが
--     意図通りか (言語の壁 > 人間関係) は運用judgement。
--   - 上げすぎた場合の症状: 特定言語のユーザーのフィードが同言語の投稿ばかりになり、
--     多言語コミュニティとしての混在が失われる。異常を感じたら 0 に戻せば即座に
--     旧挙動 (063 相当) に復帰する。
-- ============================================================================

-- ============================================================================
-- 4. 検証クエリ (A): lang 列が両テーブルに追加されているか
-- ============================================================================
-- SELECT table_name, column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name IN ('user_posts', 'users')
--   AND column_name = 'lang'
-- ORDER BY table_name;
-- 期待結果: user_posts.lang / users.lang の2行、どちらも data_type = 'text', is_nullable = 'YES'

-- ============================================================================
-- 5. 検証クエリ (B): CREATE OR REPLACE 後も権限が維持されているか
--    (065/068 の aclexplode チェックと同じ形。fetch_mixed_feed_random に絞って確認)
-- ============================================================================
-- SELECT p.proname,
--        pg_get_function_identity_arguments(p.oid) AS args,
--        CASE
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
--               THEN '🔴 PUBLIC(未認証でも実行可)'
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 'anon'::regrole::oid AND a.privilege_type = 'EXECUTE')
--               THEN '🟠 anon に付与'
--          WHEN EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
--                       WHERE a.grantee = 'authenticated'::regrole::oid AND a.privilege_type = 'EXECUTE')
--               THEN '✅ 閉じている (authenticated のみ)'
--          ELSE '⚠️ authenticated にも付与されていない (退行の可能性)'
--        END AS verdict
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'fetch_mixed_feed_random';
-- 期待結果: verdict = '✅ 閉じている (authenticated のみ)' の1行 (anon には絶対に付かないこと)

-- ============================================================================
-- 6. 検証クエリ (C): w_same_lang = 0 の状態でフィード出力が変わっていないことの確認
-- ============================================================================
-- 本ファイル適用前後で同じ seed を渡し、結果が完全一致することを確認する:
--
--   -- 適用前 (072 まで適用済みの状態) に SQL Editor で実行し、結果を保存しておく:
--   SELECT kind, item_id, score IS NOT NULL AS has_score  -- score は戻り値に含まれないため item_id の並び順のみを比較
--   FROM fetch_mixed_feed_random(30, 'verify-073-fixed-seed');
--
--   -- 073 適用後、同じ seed で再実行:
--   SELECT kind, item_id
--   FROM fetch_mixed_feed_random(30, 'verify-073-fixed-seed');
--
-- item_id の並び順 (1件目から30件目まで) が完全に一致すれば、w_same_lang=0 の項が
-- スコアに何も足していないことが実証される (CASE の ELSE 0 が効いているだけで、
-- 加算対象自体が0なので浮動小数点の丸め誤差すら生まれない)。
-- 差分を機械的に見たい場合は、両方の結果を一時テーブルに保存して
--   SELECT * FROM before_result EXCEPT SELECT * FROM after_result;
-- が0行になることを確認してもよい。
-- ============================================================================
