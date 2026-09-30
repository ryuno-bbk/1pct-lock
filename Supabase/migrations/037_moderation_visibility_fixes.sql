-- ============================================================
-- 037_moderation_visibility_fixes.sql
-- Batch fix of moderation visibility and RLS loopholes (H7/H13/H14/M31/L26)
-- ============================================================
-- Source:
--   Of the items confirmed in the final full audit (2026-07-20, Docs/final_audit_2026_07_20.md),
--   this closes 5 at once, limited to the moderation visibility of user_posts / user_comments and
--   the surrounding RLS loopholes. Continuation of audit batch 1 (d10d5be, covering C1/C2/H2/H3/H12).
--
-- Purpose:
--   1. H7:  the SELECT policy of user_posts is still USING (true), so posts already judged rejected
--      stay visible via other people's profile lists and single fetches (notification taps etc.).
--      Change it to owner-or-not-rejected (the author can still see their own rejected posts,
--      for a future appeal feature).
--   2. H13: the body-like columns of user_posts (text_jp/text_en/title/image_path/overlays/
--      image_count/tags/background_id) can still be rewritten without limit by an UPDATE from the
--      author, even though the moderate-post Edge Function checks only INSERT and ignores UPDATE.
--      There is no edit UI, so all writes after approval can be rejected. Make them immutable after
--      write.
--   3. H14: user_comments has a moderation_status column (added in 027), but there is no filter at
--      all in the 3 comment fetch RPCs (fetch_comments_for_post / fetch_comments_for_quote /
--      fetch_feed_extras) or in the SELECT policy of user_comments. Apply the same filter as the
--      post side (027) to comments too (rejected is always excluded, flagged is excluded only while
--      moderation_config.ethos_enforce is true).
--   4. M31: the app only INSERTs into block_sessions, but the update/delete policies are still
--      open, so users can tamper with their own total lock time and erase history. Remove both
--      policies (account deletion works via ON DELETE CASCADE to auth.users and does not depend on
--      RLS, so removing the DELETE policy has no effect on it).
--   5. L26: the INSERT policy of user_reports only checks reporter_id, so the client can INSERT
--      any values for status / resolved_at / ai_severity / ai_summary. Force fixed values with a
--      BEFORE INSERT trigger.
--
-- Design decisions:
--   - No new approach is invented; existing patterns are followed as they are:
--     the protect trigger uses the same rolbypassrls check as protect_user_posts_moderation in
--     027_ai_moderation.sql / 031_protect_view_count.sql (service_role and the SECURITY DEFINER
--     function owner postgres pass through; only direct UPDATE/INSERT from normal authenticated
--     users is rejected).
--   - The 3 comment fetch RPCs follow 027's policy "the returned columns do not change, so CREATE OR
--     REPLACE is enough" as is, and the RETURNS TABLE column lists and REVOKE/GRANT statements are
--     not changed at all from the original definitions (014_b_comments_notifications.sql /
--     017_b_quote_comments.sql / 028_bereal_ui.sql). Only filters are added to the WHERE clauses.
--
-- Execution order:
--   After 027 (moderation_status column + moderation_config table). Safe to run any number of
--   times (only DROP POLICY IF EXISTS → CREATE POLICY / CREATE OR REPLACE FUNCTION /
--   DROP TRIGGER IF EXISTS → CREATE TRIGGER patterns, no new destructive operations).
-- ============================================================

-- ============================================
-- 1. H7: change the SELECT policy of user_posts to owner-or-not-rejected
-- ============================================
-- Currently (005_b_user_posts.sql:90-92) it is USING (true), so even rejected posts are visible to
-- everyone. The owner needs to be able to see their own rejected posts (for a future appeal feature).
DROP POLICY IF EXISTS "user_posts_select_all" ON public.user_posts;

CREATE POLICY "user_posts_select_all"
    ON public.user_posts FOR SELECT
    USING (auth.uid() = user_id OR moderation_status <> 'rejected');

-- ============================================
-- 2. H13: make the content columns of user_posts immutable after write
-- ============================================
-- The user_posts_update_own policy (005_b_user_posts.sql:100-103) still allows UPDATE of the whole
-- row. There is no edit UI, yet if an approved post is swapped from harmless content to other content
-- (hate etc.) by calling PostgREST directly, no re-check happens because moderate-post only handles
-- INSERT. With exactly the same skeleton as protect_user_posts_moderation in 027_ai_moderation.sql,
-- make the body-like columns immutable after write.
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
-- 3. H14: exclude rejected/flagged comments from the comment fetch functions
-- ============================================
-- Filter user_comments.moderation_status (added in 027) with the same 2 conditions as the post side
-- (rejected is always excluded / flagged is excluded only while ethos_enforce=true).
-- Targets: the 3 existing RPCs + the SELECT policy of user_comments. The RETURNS TABLE column lists
-- and REVOKE/GRANT statements are not changed from the original definitions.

-- ---- 3-1. fetch_comments_for_post (base: 014_b_comments_notifications.sql:704-763) ----
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
        -- Reply-target user name (the display_name of the parent's author, if a parent exists)
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

-- ---- 3-2. fetch_comments_for_quote (base: 017_b_quote_comments.sql:176-234) ----
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

-- ---- 3-3. fetch_feed_extras (base: 028_bereal_ui.sql:106-190, only the comment_rows CTE is changed) ----
CREATE OR REPLACE FUNCTION public.fetch_feed_extras(
    post_ids  uuid[] DEFAULT '{}',
    quote_ids uuid[] DEFAULT '{}'
)
RETURNS TABLE (
    kind     text,
    item_id  uuid,
    likers   jsonb,   -- [{user_id, display_name, avatar_url}] newest first ≤3
    comments jsonb    -- [{id, author_name, text}] latest 3, oldest first
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
            -- Pick the latest 3, then reorder them oldest first
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

-- ---- 3-4. SELECT policy of user_comments (base: 014_b_comments_notifications.sql:113-116) ----
DROP POLICY IF EXISTS "user_comments_select_all" ON public.user_comments;

CREATE POLICY "user_comments_select_all"
    ON public.user_comments FOR SELECT
    USING (auth.uid() = author_user_id OR moderation_status <> 'rejected');

-- ============================================
-- 4. M31: remove the UPDATE/DELETE policies of block_sessions
-- ============================================
-- The app only INSERTs into block_sessions. If the update/delete policies stay open, users can reset or
-- inflate the total lock time of their own account, so they are removed.
-- Account deletion works via ON DELETE CASCADE to auth.users and does not depend on RLS, so removing
-- the DELETE policy has no effect on it.
DROP POLICY IF EXISTS "block_sessions_update_own" ON public.block_sessions;
DROP POLICY IF EXISTS "block_sessions_delete_own" ON public.block_sessions;

-- ============================================
-- 5. L26: the problem that the client can set status/ai columns freely on user_reports INSERT
-- ============================================
-- The user_reports_insert_own policy (006_b_moderation.sql:70-73) only checks reporter_id, so the
-- client can INSERT any values for status / resolved_at / ai_severity / ai_summary. Force fixed
-- values with a BEFORE INSERT trigger (the rolbypassrls check follows the same pattern as the
-- existing protect triggers).
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
