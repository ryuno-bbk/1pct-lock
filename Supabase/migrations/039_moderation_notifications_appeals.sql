-- ============================================================
-- 039_moderation_notifications_appeals.sql
-- Moderation result notifications + appeals (2026-07-20 real-device feedback #9)
-- ============================================================
-- Background:
--   Even when a post/comment became rejected/flagged by AI moderation, the author was not
--   notified at all, and there was no way to appeal (2026-07-20 real-device feedback #9).
--
-- Design decisions (confirmed by the user):
--   - System-generated notifications (moderation results, appeal results) are implemented with a
--     self-reference approach where "the user is the sender of the notification to themself"
--     (recipient_user_id = actor_user_id). No new sentinel account is created (public.users.id has
--     an FK constraint to auth.users(id), so a dummy account without a real user row would sit
--     outside the normal Auth flow and become too complex).
--   - Self-reference is consistent with the 3 existing constraints:
--       1. user_notifications.actor_user_id is NOT NULL + FK → always a valid user
--       2. The JOIN public.users u ON u.id = n.actor_user_id in fetch_notifications is an
--          INNER JOIN, but your own row always exists, so there is no problem
--       3. On the Swift side, UserNotification.actorUserId can still be decoded as a non-optional UUID
--     → Only the user_notifications_no_self CHECK and the self-action rejection guard of
--       create_notification() are relaxed to allow self-reference for system kinds.
--   - user_appeals: a new table where the author of a post/comment can appeal rejected/flagged
--     content. Created only via the file_appeal RPC (no direct INSERT). Resolution (approve/reject)
--     is done by the operator with a manual UPDATE in the SQL Editor (same as user_reports). On
--     approval, the resolve_user_appeal trigger sets the original content's moderation_status back
--     to 'approved'.
--
-- Current state check (confirmed by reading 014/015/017/018/022/027 before creating this file):
--   - Current allowed list of user_notifications.kind (the latest is 022, which added 'new_post'):
--       'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post'
--     The CHECK constraint has no name → Postgres default naming user_notifications_kind_check
--     (the exact name that 022 uses explicitly in
--     `DROP CONSTRAINT IF EXISTS user_notifications_kind_check`. 023-038 do not touch this constraint)
--   - user_notifications_no_self is unchanged from the 014 definition (no DROP/RENAME in 015-038)
--   - create_notification(p_recipient_user_id, p_actor_user_id, p_kind,
--     p_target_post_id DEFAULT NULL, p_target_quote_id DEFAULT NULL,
--     p_target_comment_id DEFAULT NULL, p_preview_text DEFAULT NULL) signature is unchanged from
--     the 014 definition (confirmed by the type list create_notification(uuid, uuid, text,
--     uuid, uuid, uuid, text) in the REVOKE statement of 015. It also matches the argument names
--     at the call sites in 017/022)
--   - Target columns of user_comments: post_id (nullable, NOT NULL dropped in 017) / quote_id
--     (nullable, added in 017). user_comments_target_xor forces exactly one of them to be
--     non-NULL at all times. The owner column is author_user_id (unchanged from the 014 definition).
--     → notify_on_comment_moderation passes both NEW.post_id and NEW.quote_id to
--     create_notification (the xor constraint means only one ever has a value, so no branching).
--   - The owner column of user_posts is user_id (unchanged from the 005 definition)
--   - The jsonb keys of moderation_verdict were confirmed in Supabase/functions/moderate-post/index.ts
--     as safety_reason / ethos_reason (read safety_reason when layer 1 rejected, and
--     ethos_reason when layer 2 flagged). The same Edge Function has both user_posts and
--     user_comments as webhook targets, so moderation result UPDATEs on the comment side
--     really happen too.
--   - protect_user_posts_moderation / protect_user_comments_moderation (027 definition) decide
--     whether to bypass by looking at pg_roles.rolbypassrls of current_user.
--     SECURITY DEFINER functions run as the owner (postgres, rolbypassrls=true), so the
--     UPDATE inside resolve_user_appeal passes straight through these triggers
--     (same behavior as existing SECURITY DEFINER RPCs such as delete_my_account).
--
-- Execution order: assumes an environment where 014 (user_notifications/create_notification) and
--   027 (moderation columns/protect trigger) are already applied. Safe to run any number of times
--   (DROP IF EXISTS → ADD / CREATE OR REPLACE / IF NOT EXISTS pattern). Applying/deploying is done
--   by the user (Supabase Dashboard → SQL Editor). Nothing runs automatically from this file alone.
-- ============================================================

-- ============================================================
-- 1. Add 4 system notification kinds to the allowed list of user_notifications.kind
-- ============================================================
-- Current allowed list (as of 022): like/follow/comment/reply/comment_like/new_post
-- The constraint name is user_notifications_kind_check, explicitly confirmed in 022 (it follows the
-- Postgres default naming rule for an unnamed CHECK)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN (
            'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post',
            'content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected'
        )
    );

COMMENT ON TABLE public.user_notifications IS
    'アプリ内通知。kind = like/follow/comment/reply/comment_like/new_post (対人通知) '
    '+ content_rejected/content_flagged/appeal_approved/appeal_rejected '
    '(システム通知、recipient_user_id = actor_user_id の自己参照)';

-- ============================================================
-- 2. Allow self-reference (system notification kinds only)
-- ============================================================
-- Relax the constraint user_notifications_no_self, which is unchanged since the 014 definition.
-- Self-reference with recipient=actor is allowed only for the 4 kinds content_rejected/content_flagged/
-- appeal_approved/appeal_rejected (other person-to-person notifications still cannot come from yourself).
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_no_self;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_no_self CHECK (
        recipient_user_id <> actor_user_id
        OR kind IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected')
    );

-- create_notification(): add an exception for system kinds to the self-action rejection guard.
-- The signature, NULL checks, INSERT statement and ON CONFLICT clause are kept exactly as in the 014
-- definition (the only change is the IF condition of the self-action check).
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
    IF p_recipient_user_id = p_actor_user_id
       AND p_kind NOT IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected') THEN
        RETURN;  -- Do not notify for your own actions (system notification kinds allow self-reference)
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
-- REVOKE/GRANT: 015 already REVOKEd it from all of PUBLIC/anon/authenticated (it is expected to be
-- called only from internal SECURITY DEFINER triggers/RPCs). CREATE OR REPLACE keeps the existing ACL
-- as long as the signature is unchanged, so there is no need to set it again here.

-- ============================================================
-- 3. Automatic notification of user_posts moderation results
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_on_post_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind   text;
    v_reason text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    v_reason := CASE NEW.moderation_status
        WHEN 'rejected' THEN NEW.moderation_verdict->>'safety_reason'
        ELSE NEW.moderation_verdict->>'ethos_reason'
    END;
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.user_id,
        p_actor_user_id     => NEW.user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.id,
        p_preview_text      => v_reason
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_notify_moderation ON public.user_posts;
CREATE TRIGGER user_posts_notify_moderation
    AFTER UPDATE ON public.user_posts
    FOR EACH ROW
    WHEN (OLD.moderation_status IS DISTINCT FROM NEW.moderation_status AND NEW.moderation_status IN ('rejected', 'flagged'))
    EXECUTE FUNCTION public.notify_on_post_moderation();
-- Postgres refuses direct calls to a function that RETURNS trigger (it can only run as a trigger), so
-- like the other trigger functions in 014/017/022/027, REVOKE/GRANT is not needed.

-- ============================================================
-- 4. Automatic notification of user_comments moderation results
-- ============================================================
-- In user_comments only one of post_id / quote_id is non-NULL
-- (user_comments_target_xor, 017 definition). create_notification accepts target_post_id /
-- target_quote_id as independent nullable arguments, so no branching is needed; just pass
-- NEW.post_id and NEW.quote_id as they are (only one of them ever has a value).
CREATE OR REPLACE FUNCTION public.notify_on_comment_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind   text;
    v_reason text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    v_reason := CASE NEW.moderation_status
        WHEN 'rejected' THEN NEW.moderation_verdict->>'safety_reason'
        ELSE NEW.moderation_verdict->>'ethos_reason'
    END;
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.author_user_id,
        p_actor_user_id     => NEW.author_user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.post_id,
        p_target_quote_id   => NEW.quote_id,
        p_target_comment_id => NEW.id,
        p_preview_text      => v_reason
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_notify_moderation ON public.user_comments;
CREATE TRIGGER user_comments_notify_moderation
    AFTER UPDATE ON public.user_comments
    FOR EACH ROW
    WHEN (OLD.moderation_status IS DISTINCT FROM NEW.moderation_status AND NEW.moderation_status IN ('rejected', 'flagged'))
    EXECUTE FUNCTION public.notify_on_comment_moderation();

-- ============================================================
-- 5. user_appeals table (appeals)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_appeals (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    target_post_id    uuid REFERENCES public.user_posts(id) ON DELETE CASCADE,
    target_comment_id uuid REFERENCES public.user_comments(id) ON DELETE CASCADE,
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'approved', 'rejected')),
    resolution_note   text,
    resolved_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_appeals_target_xor CHECK (
        (target_post_id IS NOT NULL AND target_comment_id IS NULL) OR
        (target_post_id IS NULL AND target_comment_id IS NOT NULL)
    )
);

COMMENT ON TABLE public.user_appeals IS
    '投稿/コメントのモデレーション結果 (rejected/flagged) に対する異議申し立て。'
    'file_appeal RPC 経由でのみ作成可能。解決 (承認/却下) は運営が SQL Editor で '
    '手動 UPDATE する運用 (user_reports と同じ)';

CREATE UNIQUE INDEX IF NOT EXISTS user_appeals_unique_post
    ON public.user_appeals(target_post_id) WHERE target_post_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS user_appeals_unique_comment
    ON public.user_appeals(target_comment_id) WHERE target_comment_id IS NOT NULL;

ALTER TABLE public.user_appeals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_appeals_select_own" ON public.user_appeals;
CREATE POLICY "user_appeals_select_own"
    ON public.user_appeals FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT/UPDATE/DELETE cannot be done directly by the client (no policy defined = denied by default).
-- Creation is only via the file_appeal RPC (SECURITY DEFINER checks ownership/status before the
-- INSERT). Resolution (approve/reject) is done by the operator with a manual UPDATE in the SQL Editor
-- (same operating pattern as resolving the status of user_reports).

-- ============================================================
-- 6. file_appeal RPC (submit an appeal)
-- ============================================================
CREATE OR REPLACE FUNCTION public.file_appeal(
    p_target_post_id    uuid,
    p_target_comment_id uuid,
    p_reason            text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_appeal_id uuid;
    v_owner_id  uuid;
    v_status    text;
BEGIN
    IF (p_target_post_id IS NOT NULL) = (p_target_comment_id IS NOT NULL) THEN
        RAISE EXCEPTION 'exactly one of target_post_id / target_comment_id required';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'reason is required';
    END IF;

    IF p_target_post_id IS NOT NULL THEN
        SELECT user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_posts WHERE id = p_target_post_id;
    ELSE
        SELECT author_user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_comments WHERE id = p_target_comment_id;
    END IF;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'target not found';
    END IF;
    IF v_owner_id <> auth.uid() THEN
        RAISE EXCEPTION 'not your content';
    END IF;
    IF v_status NOT IN ('rejected', 'flagged') THEN
        RAISE EXCEPTION 'only rejected/flagged content can be appealed';
    END IF;

    INSERT INTO public.user_appeals (user_id, target_post_id, target_comment_id, reason)
    VALUES (auth.uid(), p_target_post_id, p_target_comment_id, p_reason)
    RETURNING id INTO v_appeal_id;

    RETURN v_appeal_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'already appealed';
END;
$$;

COMMENT ON FUNCTION public.file_appeal(uuid, uuid, text) IS
    '投稿/コメント (post_id / comment_id のどちらか一方) の異議申し立てを送信。'
    '本人所有かつ moderation_status が rejected/flagged の場合のみ受理。1対象1件まで';

-- Follows the lesson of 015_security_audit.sql #4 ("REVOKE FROM anon alone leaves the function's
-- implicit PUBLIC grant, so anon is not fully blocked"), and revokes PUBLIC explicitly too.
REVOKE EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) TO authenticated;

-- ============================================================
-- 7. Appeal resolution trigger (restores the original content on approval)
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_user_appeal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.status = 'approved' THEN
        IF NEW.target_post_id IS NOT NULL THEN
            UPDATE public.user_posts
            SET moderation_status = 'approved', moderated_at = now()
            WHERE id = NEW.target_post_id;
        ELSIF NEW.target_comment_id IS NOT NULL THEN
            UPDATE public.user_comments
            SET moderation_status = 'approved', moderated_at = now()
            WHERE id = NEW.target_comment_id;
        END IF;
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_approved',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id
        );
    ELSIF NEW.status = 'rejected' THEN
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_rejected',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id,
            p_preview_text      => NEW.resolution_note
        );
    END IF;
    RETURN NEW;
END;
$$;

-- Note: this function runs as SECURITY DEFINER (owned by postgres), so the inner
-- UPDATE user_posts/user_comments naturally passes the protect_user_posts_moderation /
-- protect_user_comments_moderation triggers (027 definition, which decide whether to bypass by
-- looking at rolbypassrls of current_user). It is the same mechanism as existing SECURITY DEFINER
-- RPCs such as delete_my_account, so no extra workaround is needed.
-- Also, a transition to 'approved' does not match the WHEN clause of the
-- user_posts_notify_moderation / user_comments_notify_moderation triggers (they fire only on
-- rejected/flagged), so no double notification or loop happens.
DROP TRIGGER IF EXISTS user_appeals_resolve ON public.user_appeals;
CREATE TRIGGER user_appeals_resolve
    AFTER UPDATE ON public.user_appeals
    FOR EACH ROW
    WHEN (OLD.status = 'pending' AND NEW.status <> 'pending')
    EXECUTE FUNCTION public.resolve_user_appeal();

-- ============================================================
-- 8. Queries for checking behavior (no need to run, comments only)
-- ============================================================
-- Check the moderation result notification (right after a post changed to flagged/rejected):
--   SELECT * FROM fetch_notifications(20) WHERE kind IN ('content_rejected', 'content_flagged');
-- Submit an appeal (for your own rejected/flagged post):
--   SELECT file_appeal('<post_id>'::uuid, NULL, 'I think this was a misjudgment');
-- Operator approval (SQL Editor):
--   UPDATE user_appeals SET status = 'approved', resolved_at = now() WHERE id = '<appeal_id>';
-- Operator rejection (SQL Editor):
--   UPDATE user_appeals SET status = 'rejected', resolution_note = 'Rejected for violating the terms', resolved_at = now()
--   WHERE id = '<appeal_id>';
-- After approval, check that the target post's moderation_status is back to 'approved':
--   SELECT moderation_status FROM user_posts WHERE id = '<post_id>';
-- Check that the approval/rejection notification has arrived:
--   SELECT * FROM fetch_notifications(20) WHERE kind IN ('appeal_approved', 'appeal_rejected');
