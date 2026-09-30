-- ============================================================
-- Phase B-3: moderation (user_reports / user_blocks)
-- ============================================================
-- Purpose:
--   1. user_reports: report records (targets: post / user / quote)
--   2. user_blocks:  block relationships (one-way, Twitter style)
--
-- Design decisions:
--   - 3 report target types: post / user / quote (official quotes can also be reported)
--   - The same person cannot report the same post/quote twice (prevents harassment report spam)
--   - Blocking is one-way and the other side is not notified (Twitter style)
--   - You cannot block yourself
--
-- Handling report notifications (implemented in Phase C; this file only has the structure):
--   - Database Webhook → Edge Function → email (to the operator)
--   - or periodically check status='pending' in a web admin screen
--
-- Execution order:
--   After 005 is done (because it references user_posts)
-- ============================================================

-- ============================================
-- 1. user_reports table
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_reports (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    target_post_id  uuid REFERENCES public.user_posts(id) ON DELETE CASCADE,
    target_user_id  uuid REFERENCES public.users(id) ON DELETE CASCADE,
    target_quote_id uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
    reason          text NOT NULL
                      CHECK (reason IN ('spam', 'harassment', 'hate', 'nudity', 'violence', 'other')),
    detail          text,
    status          text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'reviewing', 'resolved', 'dismissed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz,

    -- At least 1 target is required
    CONSTRAINT user_reports_target_required CHECK (
        target_post_id IS NOT NULL
        OR target_user_id IS NOT NULL
        OR target_quote_id IS NOT NULL
    ),

    -- No duplicate reports on the same post (NULL is distinct from NULL, so treated as no duplicate)
    CONSTRAINT user_reports_unique_per_post
        UNIQUE NULLS NOT DISTINCT (reporter_id, target_post_id),
    CONSTRAINT user_reports_unique_per_quote
        UNIQUE NULLS NOT DISTINCT (reporter_id, target_quote_id)
);

CREATE INDEX IF NOT EXISTS idx_user_reports_pending
    ON public.user_reports(created_at DESC) WHERE status = 'pending';

COMMENT ON TABLE public.user_reports IS '通報。target_post_id/target_user_id/target_quote_id のいずれか必須';

-- ============================================
-- 2. user_reports RLS
-- ============================================
ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

-- SELECT: only your own reports are visible
DROP POLICY IF EXISTS "user_reports_select_own" ON public.user_reports;
CREATE POLICY "user_reports_select_own"
    ON public.user_reports FOR SELECT
    USING (auth.uid() = reporter_id);

-- INSERT: report with your own reporter_id
DROP POLICY IF EXISTS "user_reports_insert_own" ON public.user_reports;
CREATE POLICY "user_reports_insert_own"
    ON public.user_reports FOR INSERT
    WITH CHECK (auth.uid() = reporter_id);

-- UPDATE: not allowed (status changes go through service_role / moderation RPC)
-- DELETE: not allowed (withdrawing a report is not permitted; the operator dismisses it)

-- ============================================
-- 3. user_blocks table
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_blocks (
    blocker_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    blocked_user_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (blocker_id, blocked_user_id),
    CONSTRAINT user_blocks_no_self CHECK (blocker_id <> blocked_user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocker
    ON public.user_blocks(blocker_id);

COMMENT ON TABLE public.user_blocks IS 'ブロック関係。一方向、相手に通知しない (Twitter 方式)';

-- ============================================
-- 4. user_blocks RLS
-- ============================================
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

-- SELECT: only block relationships you created are visible
-- The blocked side cannot see who is blocking them
DROP POLICY IF EXISTS "user_blocks_select_own" ON public.user_blocks;
CREATE POLICY "user_blocks_select_own"
    ON public.user_blocks FOR SELECT
    USING (auth.uid() = blocker_id);

-- INSERT: add a block with your own blocker_id
DROP POLICY IF EXISTS "user_blocks_insert_own" ON public.user_blocks;
CREATE POLICY "user_blocks_insert_own"
    ON public.user_blocks FOR INSERT
    WITH CHECK (auth.uid() = blocker_id);

-- DELETE: only removing your own blocks
DROP POLICY IF EXISTS "user_blocks_delete_own" ON public.user_blocks;
CREATE POLICY "user_blocks_delete_own"
    ON public.user_blocks FOR DELETE
    USING (auth.uid() = blocker_id);

-- UPDATE: not allowed

-- ============================================
-- 5. Trigger that also removes follow relationships in both directions on block
-- ============================================
-- When a user blocks someone, the follow relationships between them are forcibly removed
CREATE OR REPLACE FUNCTION public.unfollow_on_block()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Delete the follow from you → them
    DELETE FROM public.user_follows
    WHERE follower_id = NEW.blocker_id
      AND followed_user_id = NEW.blocked_user_id;
    -- Delete the follow from them → you
    DELETE FROM public.user_follows
    WHERE follower_id = NEW.blocked_user_id
      AND followed_user_id = NEW.blocker_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_blocks_unfollow ON public.user_blocks;
CREATE TRIGGER user_blocks_unfollow
    AFTER INSERT ON public.user_blocks
    FOR EACH ROW
    EXECUTE FUNCTION public.unfollow_on_block();
