-- ============================================================
-- 078: storage for push notification device tokens (user_push_tokens)
--
-- Background:
--   user_notifications works, but there was no delivery channel, so
--   most notifications died unread. The in-app bell was the only way to see them.
--   This is the base of that delivery path = a table that only holds "which devices to send to".
--
-- Delivery flow (same shape as moderate-post):
--   INSERT into user_notifications
--     → Supabase Database Webhook (registered in the Dashboard = user task)
--     → Edge Function `send-push`
--     → look up the recipient's device tokens in this table and send to APNs
--
-- 🔴 The existing 102 unread notifications are not sent:
--   The Webhook reacts only to INSERT events. Past rows are not included, so
--   an accident where 102 notifications go out at once on enabling it cannot happen by structure.
--
-- 🔴 Why environment is stored:
--   Development build = sandbox APNs / TestFlight and App Store = production APNs.
--   The hosts differ, so holding only the token leads to "works in development, silent in
--   production". The device reports which environment the token was registered in, and the sender
--   picks the host.
--
-- Apply: supabase db push (or ./apply_sql.sh)
-- To roll back:
--   drop function if exists public.delete_push_token(text);
--   drop function if exists public.upsert_push_token(text, text);
--   drop table if exists public.user_push_tokens;
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_push_tokens (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    -- APNs device token (64 hex characters). Changes on reinstall / new device
    token        text NOT NULL,
    platform     text NOT NULL DEFAULT 'ios'
                     CHECK (platform IN ('ios')),
    environment  text NOT NULL
                     CHECK (environment IN ('sandbox', 'production')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    -- The same device token is always one row. Handing the device to someone else / logging in again
    -- with another account changes the owner, so token alone is unique, not user_id
    CONSTRAINT user_push_tokens_token_unique UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS idx_user_push_tokens_user
    ON public.user_push_tokens (user_id);

-- ============================================
-- RLS: own tokens only
-- ============================================
ALTER TABLE public.user_push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_push_tokens_select_own" ON public.user_push_tokens;
CREATE POLICY "user_push_tokens_select_own"
    ON public.user_push_tokens FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT / UPDATE directly from the client is forbidden (only via the SECURITY DEFINER RPC below).
-- If direct upsert were allowed, the path "reassign a token someone else holds to yourself" could
-- not be closed (the INSERT WITH CHECK passes, but the ON CONFLICT UPDATE hits another user's row)

DROP POLICY IF EXISTS "user_push_tokens_delete_own" ON public.user_push_tokens;
CREATE POLICY "user_push_tokens_delete_own"
    ON public.user_push_tokens FOR DELETE
    USING (auth.uid() = user_id);

-- Same policy as 065: anon cannot touch it at all
REVOKE ALL ON TABLE public.user_push_tokens FROM anon;
GRANT SELECT, DELETE ON TABLE public.user_push_tokens TO authenticated;

-- ============================================
-- RPC: register a token (the device calls it on every launch / idempotent)
-- ============================================
-- Why SECURITY DEFINER:
--   When logging in again with another account on the same device, the user_id of the existing row
--   must be "taken over". An upsert under RLS cannot UPDATE another user's row and fails, so the
--   reassignment is done here. It is safe because the request comes from "the device that can
--   present that token right now" (only the device and APNs know the token).
CREATE OR REPLACE FUNCTION public.upsert_push_token(
    p_token       text,
    p_environment text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;

    IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
        RAISE EXCEPTION 'token is required';
    END IF;

    IF p_environment NOT IN ('sandbox', 'production') THEN
        RAISE EXCEPTION 'environment must be sandbox or production';
    END IF;

    INSERT INTO public.user_push_tokens (user_id, token, platform, environment)
    VALUES (v_uid, trim(p_token), 'ios', p_environment)
    ON CONFLICT ON CONSTRAINT user_push_tokens_token_unique DO UPDATE
        SET user_id     = EXCLUDED.user_id,
            environment = EXCLUDED.environment,
            updated_at  = now();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_push_token(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.upsert_push_token(text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.upsert_push_token(text, text) TO authenticated;

-- ============================================
-- RPC: delete a token (on sign-out)
-- ============================================
-- If the token remains after sign-out, the next person using that device gets
-- notifications meant for the previous owner. Always delete it on sign-out.
CREATE OR REPLACE FUNCTION public.delete_push_token(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RETURN;  -- If already signed out, do nothing (not an error)
    END IF;

    DELETE FROM public.user_push_tokens
    WHERE token = trim(p_token)
      AND user_id = v_uid;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_push_token(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_push_token(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.delete_push_token(text) TO authenticated;
