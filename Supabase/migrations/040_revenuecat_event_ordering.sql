-- ============================================================
-- 040_revenuecat_event_ordering.sql
-- Audit L24: ordering guarantee for RevenueCat webhook events (rc_last_event_ms)
-- ============================================================
-- Background: RevenueCat webhooks have no ordering guarantee. With retries during a DB outage,
-- a sequence can happen where an old EXPIRATION that arrives late wrongly overwrites is_pro=true set
-- by a newer INITIAL_PURCHASE that was processed after it.
-- Solved by guarding the monotonicity of event_timestamp_ms on the DB side.

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS rc_last_event_ms bigint;

COMMENT ON COLUMN public.users.rc_last_event_ms IS
    'RevenueCat webhookで最後に反映したevent.event_timestamp_ms。古いイベントの巻き戻り防止用';

-- SECURITY DEFINER function that updates is_pro while keeping event_timestamp_ms monotonic.
-- The protect_users_is_pro trigger from 015 lets rolbypassrls of service_role/postgres through, so
-- this function, as a postgres-owned SECURITY DEFINER, passes the same way.
-- If p_event_ms is NULL it updates as before without the guard (fallback for events without a
-- timestamp).
CREATE OR REPLACE FUNCTION public.set_is_pro_guarded(
    p_user_id  uuid,
    p_is_pro   boolean,
    p_event_ms bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated boolean;
BEGIN
    UPDATE public.users
    SET is_pro = p_is_pro,
        rc_last_event_ms = COALESCE(p_event_ms, rc_last_event_ms)
    WHERE id = p_user_id
      AND (
        p_event_ms IS NULL
        OR rc_last_event_ms IS NULL
        OR rc_last_event_ms < p_event_ms
      )
    RETURNING true INTO v_updated;

    RETURN COALESCE(v_updated, false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_is_pro_guarded(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated;
-- This function is called directly by the Edge Function via PostgREST /rpc as service_role.
-- Unlike "calls from inside a postgres-owned SECURITY DEFINER" such as create_notification,
-- the EXECUTE privilege check applies to service_role itself (rolbypassrls only bypasses
-- RLS, not function ACLs). GRANT explicitly instead of relying on Supabase default privileges
GRANT EXECUTE ON FUNCTION public.set_is_pro_guarded(uuid, boolean, bigint) TO service_role;

-- ============================================================
-- Column-level protection for rc_last_event_ms (found in review: a hole the L24 fix itself almost
-- created)
-- ============================================================
-- The users_update_own policy (003_a_rls_rpc.sql:70-73) allows UPDATE of the whole row where
-- auth.uid()=id, with no per-column restriction. If rc_last_event_ms were left unprotected,
-- an authenticated user could write a huge future value into this column directly with their own
-- JWT, and the monotonic guard of set_is_pro_guarded (rc_last_event_ms < p_event_ms) would then fail
-- forever for every real RevenueCat event that arrives. As a result, even when the subscription
-- actually expires, EXPIRATION is ignored and is_pro=true is fixed permanently
-- (this L24 fix itself was about to create a purchase bypass of the same kind as H12).
-- Solved by protecting it together with is_pro in the same trigger (015 protect_users_is_pro).
-- The trigger itself (users_protect_is_pro, BEFORE UPDATE, defined in 015) is reused as is,
-- and CREATE OR REPLACE of the function alone puts the new column under protection.
CREATE OR REPLACE FUNCTION public.protect_users_is_pro()
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
    IF NEW.is_pro IS DISTINCT FROM OLD.is_pro THEN
        RAISE EXCEPTION 'is_pro is read-only for users';
    END IF;
    IF NEW.rc_last_event_ms IS DISTINCT FROM OLD.rc_last_event_ms THEN
        RAISE EXCEPTION 'rc_last_event_ms is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;
