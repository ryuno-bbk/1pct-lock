-- ============================================================
-- 017_b_quote_comments.sql
-- Support comments on official quotes (quotes)
-- ============================================================
-- Design decisions (2026-07-05 Fable5):
--   - The S16 policy "do not add comments on official quotes" is formally changed by user
--     instruction. Now that UGC was reset by the Tokyo migration, official quotes become the main
--     place for comments
--   - Extend user_comments to the same XOR pattern as user_likes
--     (exactly one of post_id / quote_id is required)
--   - Comments on official quotes do not trigger a "comment notification to the poster"
--     (the authors are historical figures who are not in users). Reply notifications work as before
--   - Comment delete permission: official quotes have no "poster", so
--     only your own comments can be deleted (the post owner branch of the existing RLS is
--     naturally empty for quotes, so no change is needed)
--
-- Run order: after 016. Safe to run any number of times
-- ============================================

-- ============================================
-- 1. Extend user_comments to support quotes
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
-- 2. quotes.comment_count denormalized column
-- ============================================
ALTER TABLE public.quotes
    ADD COLUMN IF NOT EXISTS comment_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.quotes.comment_count IS 'コメント数 (denormalize、trigger で同期)';

-- ============================================
-- 3. Extend the comment_count sync trigger to support quotes
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
-- 4. create_quote_comment RPC (comment on an official quote + reply notification)
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

    -- For a reply, check the parent's consistency (same rules as create_comment)
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

        -- Only 1 level of nesting: if the parent is already a child, attach to the parent's parent instead
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

    -- Notify only for replies (official historical figures are not in users, so no comment notification)
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
-- 6. 3 feed RPCs: use the real comment_count on the quote side (was fixed at 0 before)
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
-- 7. Queries for checking behavior (no need to run, comments)
-- ============================================
-- Create a comment:
--   SELECT create_quote_comment('<quote_id>'::uuid, 'test comment');
-- Fetch comments:
--   SELECT * FROM fetch_comments_for_quote('<quote_id>'::uuid);
-- Check that comment_count is updated:
--   SELECT id, comment_count FROM quotes WHERE comment_count > 0;
