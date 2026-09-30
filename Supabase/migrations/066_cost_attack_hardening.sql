-- ============================================================================
-- 066_cost_attack_hardening.sql
-- Phase 1: stop cost attacks (2026-08-01)
-- ============================================================================
-- Design: Fable 5 / Implementation: Sonnet 5 / Review: Fable 5
-- Design doc: Docs/design_phase1_cost_attack_2026_08_01.md
-- Handoff: Docs/handoff_to_fable_2026_08_01.md #1-#4
--
-- Background:
--   The estimate says the Anthropic cost is fine even at 100k MAU (¥15,000-40,000 per month), but that
--   assumes "2 posts per user per month". As long as the holes below exist, one malicious user can burn
--   the moderation cost of 100k users in a single day:
--     #1 Moderation bypass by self-declaring moderation_status:'approved' (both INSERT and UPDATE)
--     #2 Disabling the rate limit by faking created_at, plus getting quota back by delete → re-post
--     #3 Unlimited firing of user_reports / user_appeals (Sonnet runs for every report/appeal)
--     #4 AI input inflation through the unlimited length of overlays / user_reports.detail
--   This file closes all 4 points together.
--
-- ★Most important: the exemption condition uses auth.uid() IS NULL (not rolbypassrls).
--   Existing triggers such as 037 lock_user_reports_insert use rolbypassrls for the exemption,
--   but reusing that approach for user_comments / user_appeals would disable the limits.
--   create_comment (014) / file_appeal (039) are both SECURITY DEFINER
--   (owned by postgres), so with a rolbypassrls check current_user always turns into postgres
--   and always falls into "exempt" = the limit is bypassed completely (the header comment of 046
--   records the same trap). auth.uid() reads the JWT claims of the session, so
--   even inside SECURITY DEFINER the ID of "the user who actually called" is kept
--   (unlike current_user, it does not turn into the owner). Backend operations from SQL Editor /
--   service_role have no JWT claims, so auth.uid() IS NULL and they are
--   exempted naturally (details in design doc §1).
--
-- Do not use DROP FUNCTION (all existing functions use CREATE OR REPLACE).
--   DROP resets the privileges. In 063 this actually created a ship blocker
--   (all posts became readable without auth. Fixed in 064).
-- ============================================================================

BEGIN;

-- ============================================================================
-- §2-1. user_posts: BEFORE INSERT column guard
-- (#1 moderation bypass + #2 faked created_at + other users' images)
-- ============================================================================
-- The skeleton is reused from lock_user_reports_insert in 037_moderation_visibility_fixes.sql.
-- For the path that only sends the actual INSERT columns confirmed in UserPostService.swift:301-318
-- (id, user_id, title, tags, image_path, image_count, overlays), the columns fixed here
-- (created_at, moderation_* and each counter) are never sent in the first place, so this is a
-- complete no-op. Behavior does not change.
--
-- ⚠️The trigger name user_posts_lock_insert sorts before user_posts_rate_limit
-- ('l' < 'r'). PostgreSQL fires BEFORE triggers in alphabetical order of their names, so
-- the column fixing runs before the rate limit (§3-3, reads the rate_events ledger).
-- (After the switch to the ledger approach, bypassing the rate limit by faking created_at no longer
-- works, but created_at can also be used for another attack, "pin a post to the top of the feed with a
-- future date", so the column fixing is needed on its own. The name order is also kept as the design
-- doc says)
CREATE OR REPLACE FUNCTION public.lock_user_posts_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    total_overlay_len integer;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;   -- service_role / SQL Editor / cron = backend operations (design doc §1)
    END IF;

    -- #1 + #2: forbid self-declaring/faking the moderation columns, counter columns and created_at.
    -- The client never sends these, so the normal path is not affected.
    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;
    NEW.comment_count      := 0;
    NEW.view_count         := 0;

    -- Closes the path of showing another user's image as your own post. Why NEW.user_id can be
    -- trusted: the INSERT policy (005_b_user_posts.sql:95-97) already enforces
    -- auth.uid() = user_id.
    IF NEW.image_path IS NOT NULL
       AND NEW.image_path NOT LIKE (NEW.user_id::text || '/%') THEN
        RAISE EXCEPTION 'image_path must be under your own folder';
    END IF;

    -- §4-1: length limit for overlays. Computing the total character count needs jsonb_array_elements
    -- (a subquery), so it cannot be written as a CHECK constraint. It is validated here as a trigger.
    -- On the UPDATE side, 037 protect_user_posts_content (extended in §2-3 of this file) forbids any
    -- change to overlays at all, so this check at INSERT time effectively covers every path.
    IF NEW.overlays IS NOT NULL THEN
        IF jsonb_array_length(NEW.overlays) > 30 THEN
            RAISE EXCEPTION 'overlays too long (max 30 elements)';
        END IF;

        SELECT COALESCE(sum(char_length(elem ->> 'text')), 0) INTO total_overlay_len
        FROM jsonb_array_elements(NEW.overlays) AS elem;

        -- The client already limits each item to 120 characters (StoryTextEditorView.swift:367).
        -- From 30 items × 120 characters = 3,600, with some margin, we use 3,000 (design doc §4-1).
        IF total_overlay_len > 3000 THEN
            RAISE EXCEPTION 'overlays text too long (max 3000 chars total)';
        END IF;
    END IF;

    -- §4-1: each element of tags is up to 30 characters
    -- (cardinality<=3 is already a CHECK in 005, but the elements themselves had no limit)
    IF NEW.tags IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM unnest(NEW.tags) AS t WHERE char_length(t) > 30) THEN
            RAISE EXCEPTION 'tag too long (max 30 chars per tag)';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- Postgres rejects direct calls to a RETURNS trigger function from anything other than a trigger
-- (same as notify_on_post_moderation etc. in 039_moderation_notifications_appeals.sql),
-- so REVOKE/GRANT is not needed (must-follow rule #3 is for "functions the client can execute
-- directly", and trigger functions structurally have no such path).
DROP TRIGGER IF EXISTS user_posts_lock_insert ON public.user_posts;
CREATE TRIGGER user_posts_lock_insert
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_user_posts_insert();

-- ============================================================================
-- §2-2. user_comments: BEFORE INSERT column guard
-- ============================================================================
-- The INSERT in the create_comment RPC (014_b_comments_notifications.sql:545) only uses 4 columns:
-- post_id/quote_id, author_user_id, parent_comment_id, text. It sends none of
-- created_at, moderation_* or like_count. The columns fixed here are a
-- complete no-op for the normal path.
-- ⚠️ user_comments can be INSERTed not only through the create_comment RPC (SECURITY DEFINER, owned by
-- postgres) but also directly by the client through the RLS policy user_comments_insert_own (which
-- only checks auth.uid() = author_user_id), so faked INSERTs that skip the RPC
-- (self-declared moderation_status='approved' or an inflated like_count) are also closed here.
CREATE OR REPLACE FUNCTION public.lock_user_comments_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;   -- service_role / SQL Editor / cron = backend operations
    END IF;

    NEW.created_at         := now();
    NEW.moderation_status  := 'pending';
    NEW.moderation_verdict := NULL;
    NEW.moderated_at       := NULL;
    NEW.like_count         := 0;

    RETURN NEW;
END;
$$;

-- The trigger name sorts before user_comments_rate_limit ('l' < 'r'). Same reason as for posts.
DROP TRIGGER IF EXISTS user_comments_lock_insert ON public.user_comments;
CREATE TRIGGER user_comments_lock_insert
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_user_comments_insert();

-- ============================================================================
-- §2-3. protect_user_posts_content (037): add created_at / user_id to the compared columns
-- ============================================================================
-- 037_moderation_visibility_fixes.sql:69-92 only froze the 8 body-like columns (text_jp/text_en/title/
-- image_path/overlays/image_count/tags/background_id), and created_at could be rewritten by UPDATE
-- ("post → move created_at to the past with UPDATE" could get around the INSERT guard in §2-1).
-- The existing 8 columns are not changed at all. Only the 2 columns
-- created_at and user_id are added.
--
-- ⚠️Decision: the exemption condition here stays rolbypassrls (it was not unified to auth.uid() IS NULL).
-- Reasons:
--   1. This function is an UPDATE-only immutability guard, which is different in nature from the
--      pattern §1 is about ("an INSERT through a SECURITY DEFINER RPC slips through with rolbypassrls")
--      (the target is UPDATE, and there is currently no SECURITY DEFINER path that rewrites these
--      columns = no risk of undefined behavior since 037).
--   2. 037 is a trigger already running in production, and also changing the exemption method would
--      go beyond the requested scope of this task (adding 2 columns). A minimal diff was preferred.
--   → Please check during review whether this decision is sound.
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
        OR NEW.background_id IS DISTINCT FROM OLD.background_id
        -- 066 addition: freeze created_at faking (the UPDATE path of #2) and reassigning user_id
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
        OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
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

-- ============================================================================
-- §3-1. rate_events: append-only ledger table (prevents #2, getting quota back by delete → re-post)
-- ============================================================================
-- The current enforce_post_rate_limit (057) counts existing rows in user_posts, so
-- post → delete → re-post restores the quota. The ledger rows remain even when the post is deleted,
-- so this no longer works.
--
-- Rejected alternatives (design doc §3):
--   - Soft delete: huge impact (all feed RPCs/profile/counters/delete UX)
--   - Cumulative counter column on users: one column cannot express a rolling 24h window
--   - Periodic purge with pg_cron: needs the extension enabled. The self-purge below is enough
CREATE TABLE IF NOT EXISTS public.rate_events (
    id         bigserial PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('post', 'comment', 'report', 'appeal')),
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.rate_events IS
    'レート制限用の追記専用台帳。post/comment/report/appeal の各 INSERT ごとに1行追加。'
    '対象コンテンツを削除しても行は残るため「削除→再投稿」で枠が戻らない。'
    '48時間より古い自分の行は各レート制限トリガーが呼び出しのついでに自己purgeする (cron不要)';

CREATE INDEX IF NOT EXISTS idx_rate_events_user_kind_created
    ON public.rate_events (user_id, kind, created_at DESC);

ALTER TABLE public.rate_events ENABLE ROW LEVEL SECURITY;
-- Creating no policies at all = authenticated/anon cannot read or write (default deny).
-- Only SECURITY DEFINER trigger functions (owned by postgres) write to it.
--
-- ⚠️ Include authenticated in the REVOKE ALL targets too (anon alone is not enough).
-- `ALTER DEFAULT PRIVILEGES ... REVOKE ALL ON TABLES FROM anon` in 065_close_anon_access.sql §3
-- only covers anon, so new tables created after this file still keep the Supabase default grants
-- to authenticated (SELECT through DELETE).
REVOKE ALL ON TABLE public.rate_events FROM anon, authenticated;

-- ============================================================================
-- §3-3. enforce_post_rate_limit / enforce_comment_rate_limit: switch to reading the ledger
-- ============================================================================
-- No DROP FUNCTION (CREATE OR REPLACE only). The signature is unchanged, so the existing
-- trigger bindings and privileges are kept, but following 046/065, DROP TRIGGER → CREATE TRIGGER is
-- also repeated here just in case.

-- ---- Posts: 5 per 24h (keeps the current value from 057) ----
CREATE OR REPLACE FUNCTION public.enforce_post_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- 066: backend operations by the operator (SQL Editor etc.) are exempt. auth.uid() reads the
    -- session's JWT claims, so even though this function is SECURITY DEFINER, the ID of the actual
    -- calling user is kept (rolbypassrls is not used. Reason: top of this file / design doc §1).
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    -- 066: count with the ledger (rate_events) instead of existing rows. The ledger rows remain even when
    -- a post is deleted, so "delete → re-post" does not restore the quota.
    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.user_id
      AND kind = 'post'
      AND created_at > now() - interval '24 hours';

    -- 057: 100 → 10 → 5 (per-user ceiling on AI moderation cost, user decision 2026-07-30)
    IF recent_count >= 5 THEN
        RAISE EXCEPTION 'daily post limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.user_id, 'post');

    -- 066 §3-2: self-purge. Deletes your own rows older than 48 hours (no cron needed, the work per call
    -- is bounded and the table does not grow forever). Cleans all kinds together without filtering by
    -- kind (as in design doc §3-2).
    DELETE FROM public.rate_events
     WHERE user_id = NEW.user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_rate_limit ON public.user_posts;
CREATE TRIGGER user_posts_rate_limit
    BEFORE INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_post_rate_limit();

-- ---- Comments: 300 per 24h (keeps the current value from 046) ----
CREATE OR REPLACE FUNCTION public.enforce_comment_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    -- 066: 046 added no role exemption at all, because "adding a rolbypassrls exemption lets posts
    -- made through create_comment (SECURITY DEFINER, owned by postgres) slip through completely".
    -- auth.uid() reads the session's JWT claims, so the ID of the actual calling user is kept even
    -- inside SECURITY DEFINER, and this trap is avoided (design doc §1).
    -- This also makes the workaround 046 described, "DISABLE TRIGGER when seeding", unnecessary
    -- (SQL Editor = auth.uid() IS NULL is exempted naturally).
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    -- The author column of user_comments is author_user_id (014 SQL. Not user_id)
    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.author_user_id
      AND kind = 'comment'
      AND created_at > now() - interval '24 hours';

    IF recent_count >= 300 THEN
        RAISE EXCEPTION 'daily comment limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.author_user_id, 'comment');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.author_user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_rate_limit ON public.user_comments;
CREATE TRIGGER user_comments_rate_limit
    BEFORE INSERT ON public.user_comments
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_comment_rate_limit();

-- ============================================================================
-- §3-3. user_reports / user_appeals: add new rate limit triggers (#3)
-- ============================================================================
-- Sonnet runs for every report and every appeal, but there was no limit.
-- The limit values are items to confirm with the user (design doc §7): reports 20/24h, appeals 10/24h.

-- ---- Reports: 20 per 24h ----
-- INSERTs into user_reports are direct client INSERTs through the RLS policy user_reports_insert_own
-- (006_b_moderation.sql:70-73). No SECURITY DEFINER RPC is involved, but writing to rate_events
-- needs elevated privileges, so this function itself is SECURITY DEFINER
-- (same structure as enforce_*_rate_limit in 046/057).
CREATE OR REPLACE FUNCTION public.enforce_report_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.reporter_id
      AND kind = 'report'
      AND created_at > now() - interval '24 hours';

    -- 20/24h: every report makes moderate-post run Sonnet (index.ts:615).
    -- Legitimate use is unlikely to go over 20 per day, and this also mitigates censorship attacks
    -- by mass reporting.
    IF recent_count >= 20 THEN
        RAISE EXCEPTION 'daily report limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.reporter_id, 'report');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.reporter_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

-- A BEFORE INSERT trigger, user_reports_lock_insert (037), already exists.
-- By name order ('l' < 'r') they fire as lock_insert → rate_limit, but the rate_limit side only
-- looks at NEW.reporter_id and rate_events, so there is no harmful order dependency.
DROP TRIGGER IF EXISTS user_reports_rate_limit ON public.user_reports;
CREATE TRIGGER user_reports_rate_limit
    BEFORE INSERT ON public.user_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_report_rate_limit();

-- ---- Appeals: 10 per 24h ----
-- INSERTs into user_appeals only come through the file_appeal RPC (039, SECURITY DEFINER, owned by
-- postgres) (a direct INSERT is rejected because no policy is defined). Here too, anything other than
-- an auth.uid() IS NULL check falls into the exemption (with rolbypassrls, file_appeal's owner
-- postgres is always bypass=true and the rate limit is bypassed completely).
CREATE OR REPLACE FUNCTION public.enforce_appeal_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    recent_count int;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO recent_count
    FROM public.rate_events
    WHERE user_id = NEW.user_id
      AND kind = 'appeal'
      AND created_at > now() - interval '24 hours';

    -- 10/24h: every appeal makes review-appeal run Sonnet. There is a one-appeal-per-target limit
    -- (user_appeals_unique_post/comment, 039), so the real ceiling is low, but it can still be abused by
    -- mass-producing targets, so this is limited independently too.
    IF recent_count >= 10 THEN
        RAISE EXCEPTION 'daily appeal limit reached';
    END IF;

    INSERT INTO public.rate_events (user_id, kind) VALUES (NEW.user_id, 'appeal');

    DELETE FROM public.rate_events
     WHERE user_id = NEW.user_id AND created_at < now() - interval '48 hours';

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_appeals_rate_limit ON public.user_appeals;
CREATE TRIGGER user_appeals_rate_limit
    BEFORE INSERT ON public.user_appeals
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_appeal_rate_limit();

-- ============================================================================
-- §4-1. Length limits (plain text columns use CHECK constraints):
-- user_appeals.reason / user_reports.detail
-- ============================================================================
ALTER TABLE public.user_appeals
    DROP CONSTRAINT IF EXISTS user_appeals_reason_length;
ALTER TABLE public.user_appeals
    ADD CONSTRAINT user_appeals_reason_length CHECK (char_length(reason) <= 1000);

ALTER TABLE public.user_reports
    DROP CONSTRAINT IF EXISTS user_reports_detail_length;
ALTER TABLE public.user_reports
    ADD CONSTRAINT user_reports_detail_length CHECK (detail IS NULL OR char_length(detail) <= 1000);

-- Add the same check to the file_appeal RPC (039) too (design doc §4-1: "add the same check
-- to file_appeal too"). The CHECK constraint applies naturally at INSERT, but rejecting early in the
-- RPC gives the client a clearer error message. The logic, signature and
-- REVOKE/GRANT are unchanged from the 039 definition (only one length check line is added).
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
    -- 066 addition: check the same limit as the user_appeals_reason_length CHECK here too
    IF char_length(p_reason) > 1000 THEN
        RAISE EXCEPTION 'reason too long (max 1000 chars)';
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
    '本人所有かつ moderation_status が rejected/flagged の場合のみ受理。1対象1件まで。'
    '066: reason は1000文字まで (user_appeals_reason_length CHECK と二重検証)';

-- The signature is unchanged from 039, but it is repeated here just in case
-- (same policy as the file_appeal definition in 039 itself)
REVOKE EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) TO authenticated;

COMMIT;

-- ============================================================================
-- §5-4. Verification queries (run these after applying and check the results. Same format as 065)
-- ============================================================================

-- (A) Do the new/changed triggers exist, and are they enabled (tgenabled='O')?
SELECT tgrelid::regclass AS table_name, tgname, tgenabled
FROM pg_trigger
WHERE tgname IN (
    'user_posts_lock_insert', 'user_posts_protect_content', 'user_posts_rate_limit',
    'user_comments_lock_insert', 'user_comments_rate_limit',
    'user_reports_lock_insert', 'user_reports_rate_limit',
    'user_appeals_rate_limit'
)
ORDER BY table_name, tgname;
-- Expected: 8 rows, all tgenabled = 'O' (enabled). If any 'D' is mixed in, investigate.

-- (B) Firing order of BEFORE triggers (visually check the alphabetical order of lock_insert / rate_limit)
SELECT tgrelid::regclass AS table_name, tgname
FROM pg_trigger
WHERE tgrelid IN ('public.user_posts'::regclass, 'public.user_comments'::regclass)
  AND NOT tgisinternal
ORDER BY table_name, tgname;
-- Expected: in each table, *_lock_insert comes in a row before *_rate_limit

-- (C) Are any anon/authenticated privileges left on rate_events?
SELECT table_name, grantee,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS privs
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'rate_events'
  AND grantee IN ('anon', 'authenticated')
GROUP BY table_name, grantee;
-- Expected: 0 rows (neither anon nor authenticated can touch rate_events)
