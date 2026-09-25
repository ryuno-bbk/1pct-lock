-- ============================================================
-- 041_feed_cutoff_session_validation.sql
-- おすすめフィードの30日カットオフ (M33) + block_sessions.planned_seconds の
-- サーバー側検証追加 (M34)
-- ============================================================
-- 目的:
--   1. M33: fetch_mixed_feed_random (029_recommend_feed.sql) は毎回 user_posts の
--      rejected 以外の全行をスコアリングしており、投稿数の増加に比例してクエリが
--      線形に重くなる。post 枝 (UGC 投稿) の WHERE 句に「created_at が直近30日以内」
--      の条件を1行追加し、対象行数の増加を頭打ちにする。
--   2. M34: block_sessions.planned_seconds (033_completion_rate_stats.sql で追加) は
--      テーブル定義側の CHECK 制約 (block_sessions_planned_seconds_range: NULL または
--      1〜604800) はあるものの、015_security_audit.sql の validate_block_session
--      トリガー (started_at / ended_at / duration_seconds の妥当性検証の本体) には
--      一切登場しない。完遂率統計 (033 get_user_stats) は「予定時間 10分以上」を
--      分母参入のゲートに使っているため、この値の妥当性も他の妥当性検証と同じ
--      trigger 関数・同じ RAISE EXCEPTION 経路に揃えておく (改ざん耐性の穴埋め)。
--
-- 設計判断:
--   - M33: fetch_mixed_feed_random は 029 時点から RETURNS TABLE の列を増減しない
--     (comment_count 追加は既に 029 で完了済み)。シグネチャ・戻り値列が不変なので
--     021/029 が使った「DROP FUNCTION → CREATE FUNCTION」は不要で、CREATE OR REPLACE
--     のみで足りる (037/040 と同じ判断)。quote 枝・params CTE・スコア式・
--     RETURNS TABLE 列・REVOKE/GRANT 文は 029 から一切変更しない (この diff は
--     post 枝 WHERE 句への 1 行追加のみ)。
--   - カットオフ対象は post 枝のみ。quote 枝は「新しさに意味がない」設計
--     (029 のコメント参照、一括投入日が created_at のため) なのでカットオフ対象外の
--     まま変更しない。like 上位枝 (30日より前でも人気が高ければ残す等) の別建ては
--     今回作らない (ユーザー確定: 単純30日カットオフのみ)。
--   - idx_user_posts_created_at (created_at DESC) は 005_b_user_posts.sql で
--     既に作成済みと grep で確認済みのため、本ファイルでのインデックス追加は
--     不要と判断した (重複 CREATE INDEX IF NOT EXISTS すら書かない)。
--   - M34: 033 の block_sessions_planned_seconds_range CHECK 制約 (NULL または
--     1〜604800) はテーブル定義側に残したまま変更しない。今回追加するのは
--     validate_block_session トリガー内の同値の範囲検証で、CHECK 制約を置き換える
--     ものではなく defense in depth として追加する (他の妥当性チェックと同じ
--     RAISE EXCEPTION 経路に揃え、エラーの発生源を1箇所に見える化する狙い)。
--   - 範囲は「NULL 許容 / 非NULLなら 1〜604800」。クライアント側クランプ
--     (AppBlocker/Core/Services/BlockSessionTracker.swift: enqueueSession は
--     `plannedSeconds > 0` の時のみ `min(plannedSeconds, 604800)` をキューに積み、
--     makeInsert 側も `$0 > 0 ? min($0, 604800) : nil` で同じクランプを再適用する)
--     と同値にした。schedule/location モードは常に nil を送るため NULL 許容は必須。
--   - トリガー本体 (block_sessions_validate, BEFORE INSERT OR UPDATE) は 015 で
--     作成済みのものが public.validate_block_session() を名前で参照し続けるため、
--     DROP/CREATE TRIGGER は不要で関数の CREATE OR REPLACE のみでよい (037/040 と
--     同じ手法)。既存の検証ロジック (rolbypassrls バイパス / started_at 未来 /
--     ended_at 未来 / ended_at<started_at / duration_seconds 不整合 / 7日超) は
--     一切変更せず、末尾に新しい IF ブロックを追加するだけにとどめる。
--
-- 実行順序: 029・033・015 (いずれも適用済み想定) の後ならいつでも。
--   何度実行しても安全 (CREATE OR REPLACE FUNCTION のみ、DROP や破壊的 DDL なし)。
--   本ファイルはユーザーが Supabase Dashboard → SQL Editor で手動適用する想定
--   (自動デプロイはしない)。
-- ============================================================

-- ============================================
-- 1. M33: fetch_mixed_feed_random に30日カットオフ
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    WITH params AS (
        -- ============ チューニング用重み (ここだけ書き換えて CREATE OR REPLACE すれば調整可) ============
        SELECT
            3.0  ::double precision AS w_recency,          -- 投稿の新しさの最大点 (投稿直後)
            24.0 ::double precision AS recency_half_hours, -- この時間経過で新しさ点が半減
            0.5  ::double precision AS w_like,             -- ln(1+like_count) の係数
            0.7  ::double precision AS w_comment,          -- ln(1+comment_count) の係数 (コメントはいいねより強い関心)
            1.2  ::double precision AS w_follow,           -- フォロー中の投稿者へのボーナス
            1.0  ::double precision AS w_seen,             -- ln(1+自分の閲覧回数) の既読ペナルティ係数 (減点)
            1.5  ::double precision AS w_jitter,           -- ランダムジッターの最大値 (探索性)
            0.8  ::double precision AS quote_base          -- 名言の固定ベース点 (新しさ減衰の代替)
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
                + random() * p.w_jitter
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
                + random() * p.w_jitter
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
    )
    SELECT
        kind, item_id, body_jp, body_en, tags, like_count, comment_count, created_at,
        author_id, author_name, author_avatar_url, is_official_author, is_pro_author,
        background_id, title, image_path, image_count
    FROM scored
    ORDER BY score DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ============================================
-- 2. M34: validate_block_session に planned_seconds 検証を追加
-- ============================================
CREATE OR REPLACE FUNCTION public.validate_block_session()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;

    IF NEW.started_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'block_sessions: started_at is in the future';
    END IF;

    IF NEW.ended_at IS NOT NULL THEN
        IF NEW.ended_at > now() + interval '5 minutes' THEN
            RAISE EXCEPTION 'block_sessions: ended_at is in the future';
        END IF;
        IF NEW.ended_at < NEW.started_at THEN
            RAISE EXCEPTION 'block_sessions: ended_at before started_at';
        END IF;
        IF NEW.duration_seconds IS NULL
           OR abs(NEW.duration_seconds - EXTRACT(EPOCH FROM (NEW.ended_at - NEW.started_at))) > 2
        THEN
            RAISE EXCEPTION 'block_sessions: duration_seconds does not match timestamps';
        END IF;
        IF NEW.duration_seconds > 604800 THEN
            RAISE EXCEPTION 'block_sessions: session longer than 7 days rejected';
        END IF;
    END IF;

    IF NEW.planned_seconds IS NOT NULL
       AND (NEW.planned_seconds <= 0 OR NEW.planned_seconds > 604800)
    THEN
        RAISE EXCEPTION 'block_sessions: planned_seconds out of range (1-604800)';
    END IF;

    RETURN NEW;
END;
$$;

-- ============================================
-- 3. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- M33: 31日以上前の post がフィードに出ないことの確認 (テスト行を用意した上で):
--   SELECT kind, item_id, created_at FROM fetch_mixed_feed_random(50)
--   WHERE kind = 'post' AND created_at < now() - interval '30 days';
--   -- 0 件になること (quote は対象外なので kind='post' に絞って確認する)
--
-- M34: planned_seconds が範囲外だと拒否されることの確認 (authenticated で実行 → エラーになること):
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status, planned_seconds)
--   VALUES (auth.uid(), 'timer', now() - interval '10 minutes', now(), 600, 'completed', 999999);
--   -- 'block_sessions: planned_seconds out of range (1-604800)' で拒否されること
-- planned_seconds = NULL (schedule/location 等) は従来通り通ることの確認:
--   INSERT INTO block_sessions (user_id, mode, started_at, ended_at, duration_seconds, status, planned_seconds)
--   VALUES (auth.uid(), 'schedule', now() - interval '10 minutes', now(), 600, 'completed', NULL);
--   -- 成功すること
