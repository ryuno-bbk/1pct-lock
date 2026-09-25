-- ============================================================
-- 037_moderation_visibility_fixes.sql
-- モデレーション可視性・RLS 抜け穴の一括修正 (H7/H13/H14/M31/L26)
-- ============================================================
-- 出典:
--   最終総合監査 (2026-07-20, Docs/final_audit_2026_07_20.md) で確定した項目のうち、
--   user_posts / user_comments のモデレーション可視性と周辺 RLS の抜け穴に絞った
--   5 件をまとめて塞ぐ。監査バッチ1 (d10d5be, C1/C2/H2/H3/H12 対応) の続き。
--
-- 目的:
--   1. H7:  user_posts の SELECT ポリシーが USING (true) のままで、rejected 判定済み
--      投稿が他人のプロフィール一覧・単体取得 (通知タップ等) 経由で見え続けている。
--      owner-or-not-rejected に変更する (投稿者本人は自分の rejected 投稿を見られる
--      ままにする。将来の異議申し立て機能のため)。
--   2. H13: user_posts の本文相当列 (text_jp/text_en/title/image_path/overlays/
--      image_count/tags/background_id) は、moderate-post Edge Function が INSERT
--      のみを判定対象にし UPDATE を無視するにもかかわらず、投稿者からの UPDATE で
--      無制限に書き換え可能なまま。編集 UI は存在しないため、承認後の書き込みは
--      すべて拒否してよい。書き込み後イミュータブル化する。
--   3. H14: user_comments には moderation_status 列があるのに (027 で追加済み)、
--      コメント取得系 3 RPC (fetch_comments_for_post / fetch_comments_for_quote /
--      fetch_feed_extras) にも user_comments の SELECT ポリシーにも一切フィルタが
--      掛かっていない。post 側 (027) と同じフィルタ (rejected は常時除外、flagged は
--      moderation_config.ethos_enforce が true の間のみ除外) をコメント側にも適用する。
--   4. M31: block_sessions はアプリが INSERT しかしないのに update/delete ポリシーが
--      開いたまま残っており、累計ロック時間の自己改ざん・履歴消去が可能。両ポリシーを
--      撤去する (アカウント削除は auth.users への ON DELETE CASCADE 経由で動作し RLS に
--      依存しないため、DELETE ポリシー撤去による影響はない)。
--   5. L26: user_reports の INSERT ポリシーは reporter_id しか検証しておらず、
--      status / resolved_at / ai_severity / ai_summary をクライアントが任意の値で
--      INSERT できてしまう。BEFORE INSERT trigger で固定値に強制する。
--
-- 設計判断:
--   - 新方式は発明せず、既存パターンをそのまま踏襲する:
--     protect trigger は 027_ai_moderation.sql の protect_user_posts_moderation /
--     031_protect_view_count.sql と同じ rolbypassrls 判定 (service_role と
--     SECURITY DEFINER 関数所有者 postgres は素通り、一般 authenticated の直接
--     UPDATE/INSERT のみ拒否)。
--   - コメント取得 3 RPC は 027 の「戻り値の列は変えないので CREATE OR REPLACE で
--     足りる」方針をそのまま踏襲し、RETURNS TABLE の列リストと REVOKE/GRANT 文は
--     元定義 (014_b_comments_notifications.sql / 017_b_quote_comments.sql /
--     028_bereal_ui.sql) から一切変更しない。WHERE 句へのフィルタ追加のみ。
--
-- 実行順序:
--   027 (moderation_status 列 + moderation_config テーブル) 完了後。何度実行しても
--   安全 (DROP POLICY IF EXISTS → CREATE POLICY / CREATE OR REPLACE FUNCTION /
--   DROP TRIGGER IF EXISTS → CREATE TRIGGER パターンのみ、新規の破壊的操作なし)。
-- ============================================================

-- ============================================
-- 1. H7: user_posts の SELECT ポリシーを owner-or-not-rejected に変更
-- ============================================
-- 現状 (005_b_user_posts.sql:90-92) は USING (true) で rejected 投稿まで全員に見える。
-- 所有者は自分の rejected 投稿を見られる必要がある (将来の異議申し立て機能のため)。
DROP POLICY IF EXISTS "user_posts_select_all" ON public.user_posts;

CREATE POLICY "user_posts_select_all"
    ON public.user_posts FOR SELECT
    USING (auth.uid() = user_id OR moderation_status <> 'rejected');

-- ============================================
-- 2. H13: user_posts のコンテンツ列を書き込み後イミュータブル化
-- ============================================
-- user_posts_update_own ポリシー (005_b_user_posts.sql:100-103) は行全体の UPDATE を
-- 許可したまま。編集 UI が存在しないのに、承認後の投稿を PostgREST 直叩きで無害な
-- 内容から別の内容 (ヘイト等) へ差し替えても moderate-post は INSERT のみ処理する
-- ため再判定が起きない。027_ai_moderation.sql の protect_user_posts_moderation と
-- 全く同じ骨格で、本文相当の列を書き込み後イミュータブルにする。
CREATE OR REPLACE FUNCTION public.protect_user_posts_content()
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
    IF NEW.text_jp IS DISTINCT FROM OLD.text_jp
        OR NEW.text_en IS DISTINCT FROM OLD.text_en
        OR NEW.title IS DISTINCT FROM OLD.title
        OR NEW.image_path IS DISTINCT FROM OLD.image_path
        OR NEW.overlays IS DISTINCT FROM OLD.overlays
        OR NEW.image_count IS DISTINCT FROM OLD.image_count
        OR NEW.tags IS DISTINCT FROM OLD.tags
        OR NEW.background_id IS DISTINCT FROM OLD.background_id THEN
        RAISE EXCEPTION 'post content is immutable after creation (no edit feature exists)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_protect_content ON public.user_posts;
CREATE TRIGGER user_posts_protect_content
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_content();

-- ============================================
-- 3. H14: rejected/flagged コメントをコメント取得系から除外
-- ============================================
-- user_comments.moderation_status (027 で追加済み) を、post 側と同じ 2 条件
-- (rejected は常時除外 / flagged は ethos_enforce=true の間のみ除外) でフィルタする。
-- 対象は既存 3 RPC + user_comments の SELECT ポリシー。RETURNS TABLE の列リストと
-- REVOKE/GRANT 文は元定義から変更しない。

-- ---- 3-1. fetch_comments_for_post (ベース: 014_b_comments_notifications.sql:704-763) ----
CREATE OR REPLACE FUNCTION public.fetch_comments_for_post(
    target_post_id uuid,
    limit_count    integer DEFAULT 200
)
RETURNS TABLE (
    id                 uuid,
    post_id            uuid,
    parent_comment_id  uuid,
    author_user_id     uuid,
    author_name        text,
    author_avatar_url  text,
    is_pro_author      boolean,
    text               text,
    like_count         integer,
    is_liked_by_me     boolean,
    created_at         timestamptz,
    reply_to_name      text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id,
        c.post_id,
        c.parent_comment_id,
        c.author_user_id,
        u.display_name      AS author_name,
        u.avatar_url        AS author_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_author,
        c.text,
        c.like_count,
        EXISTS (
            SELECT 1 FROM public.user_comment_likes l
            WHERE l.comment_id = c.id AND l.user_id = auth.uid()
        ) AS is_liked_by_me,
        c.created_at,
        -- 返信先ユーザー名 (parent が存在すればその author の display_name)
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name
    FROM public.user_comments c
    JOIN public.users u ON u.id = c.author_user_id
    WHERE c.post_id = target_post_id
      AND c.author_user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND c.moderation_status <> 'rejected'
      AND (
        c.moderation_status <> 'flagged'
        OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
      )
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;

-- ---- 3-2. fetch_comments_for_quote (ベース: 017_b_quote_comments.sql:176-234) ----
CREATE OR REPLACE FUNCTION public.fetch_comments_for_quote(
    target_quote_id uuid,
    limit_count     integer DEFAULT 200
)
RETURNS TABLE (
    id                 uuid,
    post_id            uuid,
    parent_comment_id  uuid,
    author_user_id     uuid,
    author_name        text,
    author_avatar_url  text,
    is_pro_author      boolean,
    text               text,
    like_count         integer,
    is_liked_by_me     boolean,
    created_at         timestamptz,
    reply_to_name      text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id,
        c.post_id,
        c.parent_comment_id,
        c.author_user_id,
        u.display_name      AS author_name,
        u.avatar_url        AS author_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_author,
        c.text,
        c.like_count,
        EXISTS (
            SELECT 1 FROM public.user_comment_likes l
            WHERE l.comment_id = c.id AND l.user_id = auth.uid()
        ) AS is_liked_by_me,
        c.created_at,
        (
            SELECT pu.display_name
            FROM public.user_comments pc
            JOIN public.users pu ON pu.id = pc.author_user_id
            WHERE pc.id = c.parent_comment_id
        ) AS reply_to_name
    FROM public.user_comments c
    JOIN public.users u ON u.id = c.author_user_id
    WHERE c.quote_id = target_quote_id
      AND c.author_user_id NOT IN (
        SELECT blocked_user_id
        FROM public.user_blocks
        WHERE blocker_id = auth.uid()
      )
      AND c.moderation_status <> 'rejected'
      AND (
        c.moderation_status <> 'flagged'
        OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
      )
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) TO authenticated;

-- ---- 3-3. fetch_feed_extras (ベース: 028_bereal_ui.sql:106-190、comment_rows CTE のみ変更) ----
CREATE OR REPLACE FUNCTION public.fetch_feed_extras(
    post_ids  uuid[] DEFAULT '{}',
    quote_ids uuid[] DEFAULT '{}'
)
RETURNS TABLE (
    kind     text,
    item_id  uuid,
    likers   jsonb,   -- [{user_id, display_name, avatar_url}] 最新順 ≤3
    comments jsonb    -- [{id, author_name, text}] 最新3件を古い順
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    WITH targets AS (
        SELECT 'post'::text AS kind, unnest(post_ids)  AS item_id
        UNION ALL
        SELECT 'quote'::text,        unnest(quote_ids)
    ),
    my_blocks AS (
        SELECT blocked_user_id FROM public.user_blocks
        WHERE blocker_id = auth.uid()
    ),
    liker_rows AS (
        SELECT
            t.kind,
            t.item_id,
            u.id           AS user_id,
            u.display_name,
            u.avatar_url,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY l.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_likes l
            ON (t.kind = 'post'  AND l.post_id  = t.item_id)
            OR (t.kind = 'quote' AND l.quote_id = t.item_id)
        JOIN public.users u ON u.id = l.user_id
        WHERE l.user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
    ),
    comment_rows AS (
        SELECT
            t.kind,
            t.item_id,
            c.id       AS comment_id,
            u.display_name AS author_name,
            c.text,
            c.created_at,
            row_number() OVER (
                PARTITION BY t.kind, t.item_id
                ORDER BY c.created_at DESC
            ) AS rn
        FROM targets t
        JOIN public.user_comments c
            ON (t.kind = 'post'  AND c.post_id  = t.item_id)
            OR (t.kind = 'quote' AND c.quote_id = t.item_id)
        JOIN public.users u ON u.id = c.author_user_id
        WHERE c.author_user_id NOT IN (SELECT blocked_user_id FROM my_blocks)
          AND c.moderation_status <> 'rejected'
          AND (
            c.moderation_status <> 'flagged'
            OR NOT COALESCE((SELECT ethos_enforce FROM public.moderation_config LIMIT 1), false)
          )
    )
    SELECT
        t.kind,
        t.item_id,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'user_id',      lr.user_id,
                'display_name', lr.display_name,
                'avatar_url',   lr.avatar_url
            ) ORDER BY lr.rn)
            FROM liker_rows lr
            WHERE lr.kind = t.kind AND lr.item_id = t.item_id AND lr.rn <= 3
        ), '[]'::jsonb) AS likers,
        COALESCE((
            -- 最新 3 件を拾ってから古い順に並べ直す
            SELECT jsonb_agg(jsonb_build_object(
                'id',          cr.comment_id,
                'author_name', cr.author_name,
                'text',        cr.text
            ) ORDER BY cr.created_at ASC)
            FROM comment_rows cr
            WHERE cr.kind = t.kind AND cr.item_id = t.item_id AND cr.rn <= 3
        ), '[]'::jsonb) AS comments
    FROM targets t;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_feed_extras(uuid[], uuid[]) TO authenticated;

-- ---- 3-4. user_comments の SELECT ポリシー (ベース: 014_b_comments_notifications.sql:113-116) ----
DROP POLICY IF EXISTS "user_comments_select_all" ON public.user_comments;

CREATE POLICY "user_comments_select_all"
    ON public.user_comments FOR SELECT
    USING (auth.uid() = author_user_id OR moderation_status <> 'rejected');

-- ============================================
-- 4. M31: block_sessions の UPDATE/DELETE ポリシーを撤去
-- ============================================
-- アプリは block_sessions に INSERT しかしない。update/delete ポリシーが開いたままだと
-- 自己アカウントの累計ロック時間のリセット・水増しが可能なため撤去する。
-- アカウント削除は auth.users への ON DELETE CASCADE 経由で動作し RLS に依存しないため、
-- DELETE ポリシー撤去による影響はない。
DROP POLICY IF EXISTS "block_sessions_update_own" ON public.block_sessions;
DROP POLICY IF EXISTS "block_sessions_delete_own" ON public.block_sessions;

-- ============================================
-- 5. L26: user_reports の INSERT 時にクライアントが status/ai系列を任意設定できる問題
-- ============================================
-- user_reports_insert_own ポリシー (006_b_moderation.sql:70-73) は reporter_id しか
-- チェックしていないため、status / resolved_at / ai_severity / ai_summary を
-- クライアントが任意の値で INSERT できてしまう。BEFORE INSERT trigger で固定値に
-- 強制する (rolbypassrls チェックは既存 protect trigger と同じパターン)。
CREATE OR REPLACE FUNCTION public.lock_user_reports_insert()
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
    NEW.status := 'pending';
    NEW.resolved_at := NULL;
    NEW.ai_severity := NULL;
    NEW.ai_summary := NULL;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_reports_lock_insert ON public.user_reports;
CREATE TRIGGER user_reports_lock_insert
    BEFORE INSERT ON public.user_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_user_reports_insert();
