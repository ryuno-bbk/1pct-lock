-- ============================================================
-- 054_appeal_unsure_operator_notify.sql
-- Operator notification for unsure appeals (2026-07-30 user request:
-- "when unsure comes up, do not tell the user; notify me, and I will look and decide")
-- ============================================================
-- How it works: right after review-appeal v4 writes decision='unsure', it creates an in-app
-- notification (bell) of kind='appeal_unsure' addressed to moderation_config.operator_user_id with
-- the create_notification RPC.
-- Nothing is sent to the person who appealed (their display stays "審査中" ("Under review")).
--
-- ⚠️ One user task after applying: set your own account in operator_user_id
--   (see "Operator account setup" below). While unset, notifications are simply not created and
--   nothing else is affected (fail-soft).
--
-- Idempotent: DROP IF EXISTS → ADD / IF NOT EXISTS / CREATE OR REPLACE pattern.
-- Rollback: set operator_user_id to NULL and the notifications stop.
-- ============================================================

-- 1. Add appeal_unsure to the kind allow list (the 10 kinds in 039 + 1)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN (
            'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post',
            'content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
            'appeal_unsure'
        )
    );

-- 2. Also add it to the self-reference allow list
--    (normally recipient=operator ≠ actor=appellant, but when testing with the operator's own post,
--     recipient=actor)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_no_self;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_no_self CHECK (
        recipient_user_id <> actor_user_id
        OR kind IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
                    'appeal_unsure')
    );

-- 3. Add the same exception to the self-action filter of create_notification
--    (the only change from the 039 definition is the kind list in the IF condition)
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
       AND p_kind NOT IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
                          'appeal_unsure') THEN
        RETURN;  -- Do not notify about your own actions (system notification kinds allow self-reference)
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

-- 4. Setting column for the operator account
ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS operator_user_id uuid
        REFERENCES public.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.moderation_config.operator_user_id IS
    'unsure 申し立ての通知先 (運営アカウントの users.id)。NULL なら通知しない。'
    'review-appeal v4 が参照';

-- ============================================================
-- Operator account setup (user task, only once after applying):
--   ① Check your own id:
--        SELECT id, handle, display_name FROM public.users
--        ORDER BY created_at LIMIT 10;
--   ② Set it:
--        UPDATE public.moderation_config SET operator_user_id = '<your_id>';
-- ============================================================
