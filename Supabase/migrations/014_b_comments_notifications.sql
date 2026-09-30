-- ============================================================
-- 014_b_comments_notifications.sql
-- S16 comments feature + notifications feature (in-app)
-- ============================================================
-- Purpose:
--   1. user_comments table + comment likes + replies (1 level of nesting)
--   2. user_posts.comment_count denormalized column
--   3. user_notifications table + related RPCs
--   4. Notification INSERT on each like / follow / comment / reply / comment_like event
--   5. Extend the 3 feed RPCs (mixed / following / tag) to return comment_count
--   6. fetch_comments_for_post RPC that fetches comments
--
-- Design decisions (S16 final):
--   - Comments: text 1-500 characters, no status column (delete only, no soft delete)
--   - Replies: parent_comment_id (1 level of nesting, ON DELETE CASCADE also deletes replies when the
--     parent is deleted)
--   - Comment reports: not adopted (covered because the post author can delete them; no
--     user_reports.target_comment_id column)
--   - Notification grouping: none, one by one. Your own actions are not notified
--     (recipient_user_id != actor_user_id check)
--   - Notification targets:
--       like      = like on a post/quote → to the author
--       follow    = someone follows you
--       comment   = comment on your post
--       reply     = reply to your comment
--       comment_like = like on your comment (best-effort)
--
-- Impact on existing toggle RPCs:
--   - toggle_quote_like / toggle_post_like / toggle_comment_like do the matching notification INSERT
--     inside SECURITY DEFINER (ON CONFLICT DO NOTHING prevents duplicates on re-like)
--   - The INSERT into user_follows is SECURITY INVOKER (direct client INSERT). A trigger creates the
--     notification
--
-- Execution order:
--   After 013 (avatar storage) is done. Safe to run any number of times (IF NOT EXISTS + DROP IF
--   EXISTS pattern)
-- ============================================================

-- ============================================
-- 0. Fix the existing protect_user_posts_like_count (critical bug found in S16)
-- ============================================
-- The `current_setting('role') = 'service_role'` check defined in 005 was wrong:
--   even in a SECURITY DEFINER RPC, the `role` GUC stays as the caller's 'authenticated' and
--   does not switch → the UPDATE in toggle_post_like always hits RAISE EXCEPTION → every like
--   transaction is rolled back and nothing is saved.
-- Correct check: use pg_roles.rolbypassrls (true for postgres / supabase_admin).
--   The owner of a SECURITY DEFINER function is postgres (bypass), so it passes.
--   A direct UPDATE by a normal user is authenticated (bypass=false), so tampering with like_count
--   is rejected.
CREATE OR REPLACE FUNCTION public.protect_user_posts_like_count()
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
    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only for users (use toggle_post_like)';
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================
-- 1. user_posts.comment_count denormalized column
-- ============================================
ALTER TABLE public.user_posts
    ADD COLUMN IF NOT EXISTS comment_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.user_posts.comment_count IS 'コメント数 (denormalize、trigger で同期)';

-- ============================================
-- 2. user_comments table
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_comments (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id           uuid NOT NULL REFERENCES public.user_posts(id) ON DELETE CASCADE,
    author_user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    parent_comment_id uuid REFERENCES public.user_comments(id) ON DELETE CASCADE,
    text              text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 500),
    like_count        integer NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_comments IS 'UGC: 投稿へのコメント。parent_comment_id で 1 階層返信';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_user_comments_post_created
    ON public.user_comments (post_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_user_comments_parent
    ON public.user_comments (parent_comment_id)
    WHERE parent_comment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_comments_author
    ON public.user_comments (author_user_id, created_at DESC);

-- Auto-update updated_at
DROP TRIGGER IF EXISTS user_comments_set_updated_at ON public.user_comments;
CREATE TRIGGER user_comments_set_updated_at
    BEFORE UPDATE ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ============================================
-- 3. user_comments RLS
-- ============================================
ALTER TABLE public.user_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_comments_select_all"          ON public.user_comments;
DROP POLICY IF EXISTS "user_comments_insert_own"          ON public.user_comments;
DROP POLICY IF EXISTS "user_comments_delete_own_or_owner" ON public.user_comments;

-- SELECT: everyone (comments by blocked users are filtered in the app, or in the RPC below)
CREATE POLICY "user_comments_select_all"
    ON public.user_comments FOR SELECT
    USING (true);

-- INSERT: only your own author_user_id
CREATE POLICY "user_comments_insert_own"
    ON public.user_comments FOR INSERT
    WITH CHECK (auth.uid() = author_user_id);

-- UPDATE: not allowed (no editing. like_count only through the trigger)
-- DELETE: your own comment OR the author of the post it is on
CREATE POLICY "user_comments_delete_own_or_owner"
    ON public.user_comments FOR DELETE
    USING (
        auth.uid() = author_user_id
        OR auth.uid() IN (
            SELECT user_id FROM public.user_posts WHERE id = user_comments.post_id
        )
    );

-- ============================================
-- 4. comment_count sync trigger (user_posts.comment_count)
-- ============================================
CREATE OR REPLACE FUNCTION public.sync_post_comment_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.user_posts
            SET comment_count = comment_count + 1
            WHERE id = NEW.post_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.user_posts
            SET comment_count = GREATEST(comment_count - 1, 0)
            WHERE id = OLD.post_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_sync_count_ins ON public.user_comments;
CREATE TRIGGER user_comments_sync_count_ins
    AFTER INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_post_comment_count();

DROP TRIGGER IF EXISTS user_comments_sync_count_del ON public.user_comments;
CREATE TRIGGER user_comments_sync_count_del
    AFTER DELETE ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_post_comment_count();

-- ============================================
-- 5. Trigger that prevents tampering with like_count
-- ============================================
-- rolbypassrls check: allow inside a SECURITY DEFINER RPC (current_user=postgres),
-- reject like_count changes by a direct UPDATE from a normal user (current_user=authenticated)
CREATE OR REPLACE FUNCTION public.protect_user_comments_like_count()
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
    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only (use toggle_comment_like)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_protect_like_count ON public.user_comments;
CREATE TRIGGER user_comments_protect_like_count
    BEFORE UPDATE ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_comments_like_count();

-- ============================================
-- 6. user_comment_likes table (comment likes)
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_comment_likes (
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    comment_id uuid NOT NULL REFERENCES public.user_comments(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, comment_id)
);

CREATE INDEX IF NOT EXISTS idx_user_comment_likes_comment
    ON public.user_comment_likes (comment_id);

ALTER TABLE public.user_comment_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_comment_likes_select_own" ON public.user_comment_likes;
DROP POLICY IF EXISTS "user_comment_likes_insert_own" ON public.user_comment_likes;
DROP POLICY IF EXISTS "user_comment_likes_delete_own" ON public.user_comment_likes;

-- SELECT: can only see your own like relations (to compute is_liked_by_me in fetch_comments_for_post)
CREATE POLICY "user_comment_likes_select_own"
    ON public.user_comment_likes FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT / DELETE: only yourself (going through the RPC is recommended)
CREATE POLICY "user_comment_likes_insert_own"
    ON public.user_comment_likes FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_comment_likes_delete_own"
    ON public.user_comment_likes FOR DELETE
    USING (auth.uid() = user_id);

-- ============================================
-- 7. user_notifications table
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_notifications (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    actor_user_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    kind              text NOT NULL
                          CHECK (kind IN ('like', 'follow', 'comment', 'reply', 'comment_like')),
    target_post_id    uuid REFERENCES public.user_posts(id) ON DELETE CASCADE,
    target_quote_id   uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
    target_comment_id uuid REFERENCES public.user_comments(id) ON DELETE CASCADE,
    preview_text      text,
    read_at           timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- Do not notify your own actions (INSERT forbidden if recipient and actor are the same)
    CONSTRAINT user_notifications_no_self CHECK (recipient_user_id <> actor_user_id),
    -- Unique constraint to prevent duplicate like / comment_like (only 1 row if kind + actor + target are
    -- the same)
    CONSTRAINT user_notifications_unique_like
        UNIQUE NULLS NOT DISTINCT (
            recipient_user_id, actor_user_id, kind, target_post_id, target_quote_id, target_comment_id
        )
);

CREATE INDEX IF NOT EXISTS idx_user_notifications_recipient
    ON public.user_notifications (recipient_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_notifications_unread
    ON public.user_notifications (recipient_user_id, created_at DESC)
    WHERE read_at IS NULL;

COMMENT ON TABLE public.user_notifications IS 'アプリ内通知。kind = like/follow/comment/reply/comment_like';

ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_notifications_select_own" ON public.user_notifications;
DROP POLICY IF EXISTS "user_notifications_update_own" ON public.user_notifications;
DROP POLICY IF EXISTS "user_notifications_delete_own" ON public.user_notifications;

-- SELECT: only notifications addressed to you
CREATE POLICY "user_notifications_select_own"
    ON public.user_notifications FOR SELECT
    USING (auth.uid() = recipient_user_id);

-- INSERT: direct client insert is forbidden (only through SECURITY DEFINER RPC / trigger)
-- No policy = DENY

-- UPDATE: can only update your own read_at (going through the RPC is recommended, this is a fallback)
CREATE POLICY "user_notifications_update_own"
    ON public.user_notifications FOR UPDATE
    USING (auth.uid() = recipient_user_id)
    WITH CHECK (auth.uid() = recipient_user_id);

-- DELETE: can delete notifications addressed to you
CREATE POLICY "user_notifications_delete_own"
    ON public.user_notifications FOR DELETE
    USING (auth.uid() = recipient_user_id);

-- ============================================
-- 8. Helper function that creates notifications (internal, SECURITY DEFINER)
-- ============================================
-- Rejects self-actions + ON CONFLICT DO NOTHING prevents duplicates
CREATE OR REPLACE FUNCTION public.create_notification(
    p_recipient_user_id uuid,
    p_actor_user_id     uuid,
    p_kind              text,
    p_target_post_id    uuid DEFAULT NULL,
    p_target_quote_id   uuid DEFAULT NULL,
    p_target_comment_id uuid DEFAULT NULL,
    p_preview_text      text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_recipient_user_id IS NULL OR p_actor_user_id IS NULL THEN
        RETURN;
    END IF;
    IF p_recipient_user_id = p_actor_user_id THEN
        RETURN;  -- Do not notify your own actions
    END IF;
    INSERT INTO public.user_notifications (
        recipient_user_id, actor_user_id, kind,
        target_post_id, target_quote_id, target_comment_id, preview_text
    ) VALUES (
        p_recipient_user_id, p_actor_user_id, p_kind,
        p_target_post_id, p_target_quote_id, p_target_comment_id, p_preview_text
    )
    ON CONFLICT ON CONSTRAINT user_notifications_unique_like DO NOTHING;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_notification(uuid, uuid, text, uuid, uuid, uuid, text) FROM PUBLIC;

-- ============================================
-- 9. Override the toggle_quote_like RPC (with notifications)
-- ============================================
CREATE OR REPLACE FUNCTION public.toggle_quote_like(target_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id  uuid := auth.uid();
    existing_like_id uuid;
    new_count        integer;
    result_is_liked  boolean;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.quotes WHERE id = target_quote_id) THEN
        RAISE EXCEPTION 'Quote not found: %', target_quote_id;
    END IF;

    SELECT id INTO existing_like_id
    FROM public.user_likes
    WHERE user_id = current_user_id AND quote_id = target_quote_id;

    IF existing_like_id IS NOT NULL THEN
        DELETE FROM public.user_likes WHERE id = existing_like_id;
        UPDATE public.quotes
            SET like_count = GREATEST(like_count - 1, 0)
            WHERE id = target_quote_id
            RETURNING like_count INTO new_count;
        result_is_liked := false;
    ELSE
        INSERT INTO public.user_likes (user_id, quote_id)
            VALUES (current_user_id, target_quote_id);
        UPDATE public.quotes
            SET like_count = like_count + 1
            WHERE id = target_quote_id
            RETURNING like_count INTO new_count;
        result_is_liked := true;
        -- A quote's author is in the authors table (= official historical figures), not in users, so no
        -- notification → by design, quote likes do not create notifications (official historical figures =
        -- deceased/great figures)
    END IF;

    RETURN jsonb_build_object(
        'is_liked',   result_is_liked,
        'like_count', new_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.toggle_quote_like(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.toggle_quote_like(uuid) TO authenticated;

-- ============================================
-- 10. Override the toggle_post_like RPC (with notifications)
-- ============================================
CREATE OR REPLACE FUNCTION public.toggle_post_like(target_post_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id  uuid := auth.uid();
    existing_like_id uuid;
    new_count        integer;
    result_is_liked  boolean;
    post_owner_id    uuid;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT user_id INTO post_owner_id
    FROM public.user_posts
    WHERE id = target_post_id;

    IF post_owner_id IS NULL THEN
        RAISE EXCEPTION 'Post not found: %', target_post_id;
    END IF;

    SELECT id INTO existing_like_id
    FROM public.user_likes
    WHERE user_id = current_user_id AND post_id = target_post_id;

    IF existing_like_id IS NOT NULL THEN
        DELETE FROM public.user_likes WHERE id = existing_like_id;
        UPDATE public.user_posts
            SET like_count = GREATEST(like_count - 1, 0)
            WHERE id = target_post_id
            RETURNING like_count INTO new_count;
        result_is_liked := false;
    ELSE
        INSERT INTO public.user_likes (user_id, post_id)
            VALUES (current_user_id, target_post_id);
        UPDATE public.user_posts
            SET like_count = like_count + 1
            WHERE id = target_post_id
            RETURNING like_count INTO new_count;
        result_is_liked := true;
        -- Create a notification (only when the post author != yourself)
        PERFORM public.create_notification(
            p_recipient_user_id => post_owner_id,
            p_actor_user_id     => current_user_id,
            p_kind              => 'like',
            p_target_post_id    => target_post_id
        );
    END IF;

    RETURN jsonb_build_object(
        'is_liked',   result_is_liked,
        'like_count', new_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.toggle_post_like(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.toggle_post_like(uuid) TO authenticated;

-- ============================================
-- 11. Create a follow notification in the user_follows INSERT trigger
-- ============================================
-- Following a historical figure (author_id) needs no notification. Only user follows
-- (followed_user_id)
CREATE OR REPLACE FUNCTION public.notify_on_follow()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.followed_user_id IS NOT NULL THEN
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.followed_user_id,
            p_actor_user_id     => NEW.follower_id,
            p_kind              => 'follow'
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_follows_notify ON public.user_follows;
CREATE TRIGGER user_follows_notify
    AFTER INSERT ON public.user_follows
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_on_follow();

-- ============================================
-- 12. create_comment RPC (post a comment + notification)
-- ============================================
-- Reply by passing parent_comment_id (1 level only; rejected if the parent's parent_comment_id is not
-- NULL)
CREATE OR REPLACE FUNCTION public.create_comment(
    target_post_id           uuid,
    comment_text             text,
    parent_comment_id_param  uuid DEFAULT NULL
)
RETURNS public.user_comments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id   uuid := auth.uid();
    post_owner_id     uuid;
    parent_author_id  uuid;
    parent_post_id    uuid;
    parent_grandparent uuid;
    new_row           public.user_comments;
    preview           text;
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

    SELECT user_id INTO post_owner_id
    FROM public.user_posts
    WHERE id = target_post_id;

    IF post_owner_id IS NULL THEN
        RAISE EXCEPTION 'Post not found: %', target_post_id;
    END IF;

    -- For a reply, check the parent's consistency
    IF parent_comment_id_param IS NOT NULL THEN
        SELECT author_user_id, post_id, parent_comment_id
            INTO parent_author_id, parent_post_id, parent_grandparent
        FROM public.user_comments
        WHERE id = parent_comment_id_param;

        IF parent_post_id IS NULL THEN
            RAISE EXCEPTION 'Parent comment not found';
        END IF;

        IF parent_post_id <> target_post_id THEN
            RAISE EXCEPTION 'Parent comment belongs to different post';
        END IF;

        -- 1 level of nesting only: if the parent is already a child, use the parent's parent (Twitter style)
        IF parent_grandparent IS NOT NULL THEN
            parent_comment_id_param := parent_grandparent;
            SELECT author_user_id INTO parent_author_id
                FROM public.user_comments WHERE id = parent_comment_id_param;
        END IF;
    END IF;

    INSERT INTO public.user_comments (post_id, author_user_id, parent_comment_id, text)
        VALUES (target_post_id, current_user_id, parent_comment_id_param, comment_text)
        RETURNING * INTO new_row;

    -- The preview is the first 80 characters
    preview := left(comment_text, 80);

    -- Notification 1: for a reply → reply notification to the parent comment's author
    IF parent_comment_id_param IS NOT NULL THEN
        PERFORM public.create_notification(
            p_recipient_user_id => parent_author_id,
            p_actor_user_id     => current_user_id,
            p_kind              => 'reply',
            p_target_post_id    => target_post_id,
            p_target_comment_id => new_row.id,
            p_preview_text      => preview
        );
    END IF;

    -- Notification 2: comment notification to the post author (the post author is notified even for a
    --        reply. However, if the reply's parent comment author == the post author, the
    --        create_notification duplicate constraint does not skip it automatically, and since the kind
    --        differs (reply vs comment), both may be inserted.
    --        Here, for a reply, the post author notification is skipped → if the reply's parent is the post
    --        author, that notification is enough)
    IF parent_comment_id_param IS NULL OR parent_author_id <> post_owner_id THEN
        PERFORM public.create_notification(
            p_recipient_user_id => post_owner_id,
            p_actor_user_id     => current_user_id,
            p_kind              => 'comment',
            p_target_post_id    => target_post_id,
            p_target_comment_id => new_row.id,
            p_preview_text      => preview
        );
    END IF;

    RETURN new_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_comment(uuid, text, uuid) TO authenticated;

-- ============================================
-- 13. toggle_comment_like RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.toggle_comment_like(target_comment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id  uuid := auth.uid();
    existing_count   integer;
    new_count        integer;
    result_is_liked  boolean;
    comment_owner_id uuid;
    comment_post_id  uuid;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT author_user_id, post_id INTO comment_owner_id, comment_post_id
    FROM public.user_comments
    WHERE id = target_comment_id;

    IF comment_owner_id IS NULL THEN
        RAISE EXCEPTION 'Comment not found: %', target_comment_id;
    END IF;

    SELECT count(*) INTO existing_count
    FROM public.user_comment_likes
    WHERE user_id = current_user_id AND comment_id = target_comment_id;

    IF existing_count > 0 THEN
        DELETE FROM public.user_comment_likes
            WHERE user_id = current_user_id AND comment_id = target_comment_id;
        UPDATE public.user_comments
            SET like_count = GREATEST(like_count - 1, 0)
            WHERE id = target_comment_id
            RETURNING like_count INTO new_count;
        result_is_liked := false;
    ELSE
        INSERT INTO public.user_comment_likes (user_id, comment_id)
            VALUES (current_user_id, target_comment_id);
        UPDATE public.user_comments
            SET like_count = like_count + 1
            WHERE id = target_comment_id
            RETURNING like_count INTO new_count;
        result_is_liked := true;
        -- Notify the comment author
        PERFORM public.create_notification(
            p_recipient_user_id => comment_owner_id,
            p_actor_user_id     => current_user_id,
            p_kind              => 'comment_like',
            p_target_post_id    => comment_post_id,
            p_target_comment_id => target_comment_id
        );
    END IF;

    RETURN jsonb_build_object(
        'is_liked',   result_is_liked,
        'like_count', new_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.toggle_comment_like(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.toggle_comment_like(uuid) TO authenticated;

-- ============================================
-- 14. delete_all_comments_on_post RPC (bulk delete by the post author)
-- ============================================
CREATE OR REPLACE FUNCTION public.delete_all_comments_on_post(target_post_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id uuid := auth.uid();
    post_owner_id   uuid;
    deleted_count   integer;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT user_id INTO post_owner_id
    FROM public.user_posts
    WHERE id = target_post_id;

    IF post_owner_id IS NULL THEN
        RAISE EXCEPTION 'Post not found';
    END IF;

    IF post_owner_id <> current_user_id THEN
        RAISE EXCEPTION 'Not authorized: only post owner can delete all comments';
    END IF;

    WITH deleted AS (
        DELETE FROM public.user_comments
        WHERE post_id = target_post_id
        RETURNING 1
    )
    SELECT count(*) INTO deleted_count FROM deleted;

    RETURN COALESCE(deleted_count, 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.delete_all_comments_on_post(uuid) TO authenticated;

-- ============================================
-- 15. fetch_comments_for_post RPC
-- ============================================
-- Returns: parent comments + the replies tied to each parent, flattened together
-- (the app groups them by parent_comment_id to draw them)
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
        -- Name of the user being replied to (the display_name of the parent's author, if the parent exists)
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
    ORDER BY
        COALESCE(c.parent_comment_id, c.id) ASC,
        (c.parent_comment_id IS NOT NULL) ASC,
        c.created_at ASC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_comments_for_post(uuid, integer) TO authenticated;

-- ============================================
-- 16. fetch_notifications RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_notifications(limit_count integer DEFAULT 50)
RETURNS TABLE (
    id                uuid,
    kind              text,
    actor_user_id     uuid,
    actor_name        text,
    actor_avatar_url  text,
    is_pro_actor      boolean,
    target_post_id    uuid,
    target_comment_id uuid,
    preview_text      text,
    read_at           timestamptz,
    created_at        timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        n.id,
        n.kind,
        n.actor_user_id,
        u.display_name      AS actor_name,
        u.avatar_url        AS actor_avatar_url,
        COALESCE(u.is_pro, false) AS is_pro_actor,
        n.target_post_id,
        n.target_comment_id,
        n.preview_text,
        n.read_at,
        n.created_at
    FROM public.user_notifications n
    JOIN public.users u ON u.id = n.actor_user_id
    WHERE n.recipient_user_id = auth.uid()
      AND n.actor_user_id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY n.created_at DESC
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_notifications(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_notifications(integer) TO authenticated;

-- ============================================
-- 17. fetch_unread_notification_count RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.fetch_unread_notification_count()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT count(*)::integer
    FROM public.user_notifications
    WHERE recipient_user_id = auth.uid()
      AND read_at IS NULL
      AND actor_user_id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      );
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_unread_notification_count() FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_unread_notification_count() TO authenticated;

-- ============================================
-- 18. mark_notifications_read RPC (all, or a given set of IDs)
-- ============================================
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id uuid := auth.uid();
    updated_count   integer;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    WITH updated AS (
        UPDATE public.user_notifications
            SET read_at = now()
            WHERE recipient_user_id = current_user_id
              AND read_at IS NULL
            RETURNING 1
    )
    SELECT count(*) INTO updated_count FROM updated;

    RETURN COALESCE(updated_count, 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mark_all_notifications_read() FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;

-- ============================================
-- 19. Rewrite fetch_mixed_feed_random to add comment_count
-- ============================================
DROP FUNCTION IF EXISTS public.fetch_mixed_feed_random(integer);

CREATE FUNCTION public.fetch_mixed_feed_random(limit_count integer DEFAULT 50)
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
            0             AS comment_count,
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

REVOKE EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_mixed_feed_random(integer) TO authenticated;

-- ============================================
-- 20. Rewrite fetch_following_feed to add comment_count
-- ============================================
DROP FUNCTION IF EXISTS public.fetch_following_feed(integer);

CREATE FUNCTION public.fetch_following_feed(limit_count integer DEFAULT 50)
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
            0             AS comment_count,
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

REVOKE EXECUTE ON FUNCTION public.fetch_following_feed(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_following_feed(integer) TO authenticated;

-- ============================================
-- 21. Rewrite fetch_tag_feed to add comment_count
-- ============================================
DROP FUNCTION IF EXISTS public.fetch_tag_feed(text, integer);

CREATE FUNCTION public.fetch_tag_feed(
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
            0             AS comment_count,
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

REVOKE EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fetch_tag_feed(text, integer) TO authenticated;

-- ============================================
-- 22. Initialize the existing user_posts.comment_count with the actual count
-- ============================================
UPDATE public.user_posts p
    SET comment_count = COALESCE((
        SELECT count(*)::integer
        FROM public.user_comments c
        WHERE c.post_id = p.id
    ), 0);

-- ============================================
-- 23. Queries for checking behavior (no need to run, comments only)
-- ============================================
-- Check notifications addressed to you:
--   SELECT * FROM fetch_notifications(20);
-- Unread count:
--   SELECT fetch_unread_notification_count();
-- Comments on a post:
--   SELECT * FROM fetch_comments_for_post('<post_id>'::uuid);
-- Mark all as read:
--   SELECT mark_all_notifications_read();
