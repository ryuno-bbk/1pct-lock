-- ============================================================
-- 017_b_quote_comments.sql
-- 公式名言 (quotes) へのコメント対応
-- ============================================================
-- 設計判断 (2026-07-05 Fable5):
--   - S16 の「公式 quote コメントは足さない」方針をユーザー指示で正式に変更。
--     UGC が東京移行でリセットされた今、コメント導線の主役は公式名言になる
--   - user_comments を user_likes と同じ XOR パターンに拡張
--     (post_id / quote_id どちらか片方必須)
--   - 公式名言へのコメントでは「投稿者への comment 通知」は発生しない
--     (著者は users にいない偉人のため)。返信 (reply) 通知は従来通り機能する
--   - コメントの削除権限: 公式名言には「投稿者」がいないため、
--     自分のコメントのみ削除可 (既存 RLS の post owner 分岐が quote では
--     自然に空になるので変更不要)
--
-- 実行順序: 016 完了後。何度実行しても安全
-- ============================================

-- ============================================
-- 1. user_comments を quote 対応に拡張
-- ============================================
ALTER TABLE public.user_comments
    ALTER COLUMN post_id DROP NOT NULL;

ALTER TABLE public.user_comments
    ADD COLUMN IF NOT EXISTS quote_id uuid REFERENCES public.quotes(id) ON DELETE CASCADE;

ALTER TABLE public.user_comments
    DROP CONSTRAINT IF EXISTS user_comments_target_xor;

ALTER TABLE public.user_comments
    ADD CONSTRAINT user_comments_target_xor CHECK (
        (post_id IS NOT NULL AND quote_id IS NULL) OR
        (post_id IS NULL AND quote_id IS NOT NULL)
    );

CREATE INDEX IF NOT EXISTS idx_user_comments_quote_created
    ON public.user_comments (quote_id, created_at ASC)
    WHERE quote_id IS NOT NULL;

COMMENT ON TABLE public.user_comments IS 'UGC投稿 (post_id) または公式名言 (quote_id) へのコメント。parent_comment_id で1階層返信';

-- ============================================
-- 2. quotes.comment_count denormalize 列
-- ============================================
ALTER TABLE public.quotes
    ADD COLUMN IF NOT EXISTS comment_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.quotes.comment_count IS 'コメント数 (denormalize、trigger で同期)';

-- ============================================
-- 3. comment_count 同期 trigger を quote 対応に拡張
-- ============================================
CREATE OR REPLACE FUNCTION public.sync_post_comment_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.post_id IS NOT NULL THEN
            UPDATE public.user_posts
                SET comment_count = comment_count + 1
                WHERE id = NEW.post_id;
        ELSIF NEW.quote_id IS NOT NULL THEN
            UPDATE public.quotes
                SET comment_count = comment_count + 1
                WHERE id = NEW.quote_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.post_id IS NOT NULL THEN
            UPDATE public.user_posts
                SET comment_count = GREATEST(comment_count - 1, 0)
                WHERE id = OLD.post_id;
        ELSIF OLD.quote_id IS NOT NULL THEN
            UPDATE public.quotes
                SET comment_count = GREATEST(comment_count - 1, 0)
                WHERE id = OLD.quote_id;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- ============================================
-- 4. create_quote_comment RPC (公式名言へのコメント + 返信通知)
-- ============================================
CREATE OR REPLACE FUNCTION public.create_quote_comment(
    target_quote_id          uuid,
    comment_text             text,
    parent_comment_id_param  uuid DEFAULT NULL
)
RETURNS public.user_comments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id    uuid := auth.uid();
    parent_author_id   uuid;
    parent_quote_id    uuid;
    parent_grandparent uuid;
    new_row            public.user_comments;
    preview            text;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF comment_text IS NULL OR char_length(trim(comment_text)) = 0 THEN
        RAISE EXCEPTION 'Empty comment';
    END IF;

    IF char_length(comment_text) > 500 THEN
        RAISE EXCEPTION 'Comment too long';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.quotes WHERE id = target_quote_id) THEN
        RAISE EXCEPTION 'Quote not found: %', target_quote_id;
    END IF;

    -- 返信の場合は parent の整合性チェック (create_comment と同じ規則)
    IF parent_comment_id_param IS NOT NULL THEN
        SELECT author_user_id, quote_id, parent_comment_id
            INTO parent_author_id, parent_quote_id, parent_grandparent
        FROM public.user_comments
        WHERE id = parent_comment_id_param;

        IF parent_author_id IS NULL THEN
            RAISE EXCEPTION 'Parent comment not found';
        END IF;

        IF parent_quote_id IS DISTINCT FROM target_quote_id THEN
            RAISE EXCEPTION 'Parent comment belongs to different quote';
        END IF;

        -- ネスト1階層のみ: parent が既に子なら parent の parent に付け替え
        IF parent_grandparent IS NOT NULL THEN
            parent_comment_id_param := parent_grandparent;
            SELECT author_user_id INTO parent_author_id
                FROM public.user_comments WHERE id = parent_comment_id_param;
        END IF;
    END IF;

    INSERT INTO public.user_comments (quote_id, author_user_id, parent_comment_id, text)
        VALUES (target_quote_id, current_user_id, parent_comment_id_param, comment_text)
        RETURNING * INTO new_row;

    preview := left(comment_text, 80);

    -- 通知は返信のみ (公式偉人は users にいないので comment 通知は発生しない)
    IF parent_comment_id_param IS NOT NULL THEN
        PERFORM public.create_notification(
            p_recipient_user_id => parent_author_id,
            p_actor_user_id     => current_user_id,
            p_kind              => 'reply',
            p_target_quote_id   => target_quote_id,
            p_target_comment_id => new_row.id,
            p_preview_text      => preview
        );
    END IF;

    RETURN new_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_quote_comment(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_quote_comment(uuid, text, uuid) TO authenticated;

-- ============================================
-- 5. fetch_comments_for_quote RPC
-- ============================================
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
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_quote(uuid, integer) TO authenticated;

-- ============================================
-- 6. 3 フィード RPC: quote 側の comment_count を実値に (従来は 0 固定)
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
    background_id       integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
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
            NULL::integer AS background_id
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
        )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
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
    background_id       integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
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
            NULL::integer AS background_id
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE a.id IN (
            SELECT author_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND author_id IS NOT NULL
        )

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE u.id IN (
            SELECT followed_user_id FROM public.user_follows
            WHERE follower_id = auth.uid() AND followed_user_id IS NOT NULL
        )
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
    ) AS mixed
    ORDER BY created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.fetch_tag_feed(
    target_tag  text,
    limit_count integer DEFAULT 50
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
    background_id       integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM (
        SELECT
            'quote'::text AS kind,
            q.id          AS item_id,
            q.text_jp     AS body_jp,
            q.text_en     AS body_en,
            ARRAY[q.category] AS tags,
            q.like_count,
            q.comment_count,
            q.created_at,
            a.id          AS author_id,
            a.name        AS author_name,
            a.image_url   AS author_avatar_url,
            COALESCE(a.is_official, true) AS is_official_author,
            false         AS is_pro_author,
            NULL::integer AS background_id
        FROM public.quotes q
        JOIN public.authors a ON a.id = q.author_id
        WHERE q.category = target_tag

        UNION ALL

        SELECT
            'post'::text   AS kind,
            p.id           AS item_id,
            p.text_jp      AS body_jp,
            p.text_en      AS body_en,
            p.tags,
            p.like_count,
            p.comment_count,
            p.created_at,
            u.id           AS author_id,
            u.display_name AS author_name,
            u.avatar_url   AS author_avatar_url,
            false          AS is_official_author,
            COALESCE(u.is_pro, false) AS is_pro_author,
            p.background_id
        FROM public.user_posts p
        JOIN public.users u ON u.id = p.user_id
        WHERE target_tag = ANY(p.tags)
          AND p.user_id NOT IN (
            SELECT blocked_user_id
            FROM public.user_blocks
            WHERE blocker_id = auth.uid()
          )
    ) AS mixed
    ORDER BY random()
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;

-- ============================================
-- 7. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- コメント作成:
--   SELECT create_quote_comment('<quote_id>'::uuid, 'テストコメント');
-- コメント取得:
--   SELECT * FROM fetch_comments_for_quote('<quote_id>'::uuid);
-- comment_count 反映確認:
--   SELECT id, comment_count FROM quotes WHERE comment_count > 0;
