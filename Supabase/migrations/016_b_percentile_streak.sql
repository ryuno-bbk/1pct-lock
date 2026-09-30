-- ============================================================
-- 016_b_percentile_streak.sql
-- Step 3: DB base for the "上位◯%" ("Top ◯%") display + streak (consecutive lock days)
-- ============================================================
-- Design decisions (2026-07-04 Fable5):
--   1. The root fix for tampering (server-side timestamps via RPC) is [NOT ADOPTED]
--      Reason: it is incompatible with the offline-first design finalized in S8: "do not keep
--      active sessions in the DB; queue them in the App Group and flush them all on next launch".
--      schedule mode is recorded offline by the Extension, so server timestamps are impossible.
--      v1 only rejects obvious cheating with the validity trigger from 015 (reject future times /
--      duration consistency / 7-day cap), and it will be revisited after scaling
--   2. Denormalize users.total_block_seconds with a trigger
--      The percentile calculation becomes an index scan on the users table alone instead of a
--      full scan of block_sessions. get_total_block_seconds is replaced to read it too
--   3. Definition of top percentile: pool = users with a lock record (total > 0),
--      top X% = (number of people with a larger total than you + 1) / pool × 100.
--      Users with no lock record get has_data=false and the app hides it
--   4. Streak = number of consecutive "days with at least 1 second of lock".
--      The time zone is a parameter (default Asia/Tokyo, the client passes
--      TimeZone.current.identifier). Even if you have not locked yet today,
--      the streak continues if it was alive through yesterday (common streak UX)
--
-- Run order: after 015. Safe to run any number of times
-- ============================================

-- ============================================
-- 1. users.total_block_seconds denormalized column
-- ============================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS total_block_seconds bigint NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_total_block_seconds
    ON public.users (total_block_seconds DESC)
    WHERE total_block_seconds > 0;

COMMENT ON COLUMN public.users.total_block_seconds
    IS '累計ロック秒数 (block_sessions から trigger で同期。直接更新禁止)';

-- ============================================
-- 2. block_sessions → users.total_block_seconds sync trigger
-- ============================================
CREATE OR REPLACE FUNCTION public.sync_user_total_block_seconds()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.users
            SET total_block_seconds = total_block_seconds + COALESCE(NEW.duration_seconds, 0)
            WHERE id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.users
            SET total_block_seconds = GREATEST(
                total_block_seconds
                - COALESCE(OLD.duration_seconds, 0)
                + COALESCE(NEW.duration_seconds, 0), 0)
            WHERE id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.users
            SET total_block_seconds = GREATEST(total_block_seconds - COALESCE(OLD.duration_seconds, 0), 0)
            WHERE id = OLD.user_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS block_sessions_sync_total ON public.block_sessions;
CREATE TRIGGER block_sessions_sync_total
    AFTER INSERT OR UPDATE OR DELETE ON public.block_sessions
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_total_block_seconds();

-- Backfill from existing data
UPDATE public.users u
    SET total_block_seconds = COALESCE((
        SELECT SUM(s.duration_seconds)
        FROM public.block_sessions s
        WHERE s.user_id = u.id AND s.duration_seconds IS NOT NULL
    ), 0);

-- ============================================
-- 3. Extend the read-only column protection on users to total_block_seconds
-- ============================================
-- Overwrites protect_users_is_pro from 015 (the trigger wiring is reused as is).
-- In addition to is_pro, direct user UPDATE of total_block_seconds is also rejected
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
    IF NEW.total_block_seconds IS DISTINCT FROM OLD.total_block_seconds THEN
        RAISE EXCEPTION 'total_block_seconds is read-only for users';
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================
-- 4. Replace get_total_block_seconds to read the denormalized column (signature unchanged)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_total_block_seconds(target_user_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT LEAST(COALESCE(
        (SELECT total_block_seconds FROM public.users WHERE id = target_user_id),
        0), 2147483647)::integer;
$$;

REVOKE EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_total_block_seconds(uuid) TO authenticated;

-- ============================================
-- 5. get_block_percentile RPC (headline feature "あなたは上位◯%" ("You are in the top ◯%"))
-- ============================================
CREATE OR REPLACE FUNCTION public.get_block_percentile(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    my_total     bigint;
    higher_count integer;
    active_count integer;
BEGIN
    SELECT total_block_seconds INTO my_total
    FROM public.users WHERE id = target_user_id;

    IF my_total IS NULL OR my_total = 0 THEN
        RETURN jsonb_build_object('has_data', false);
    END IF;

    SELECT count(*) INTO active_count
    FROM public.users WHERE total_block_seconds > 0;

    SELECT count(*) INTO higher_count
    FROM public.users WHERE total_block_seconds > my_total;

    RETURN jsonb_build_object(
        'has_data',    true,
        'top_percent', ROUND((higher_count + 1)::numeric / active_count * 100, 1),
        'rank',        higher_count + 1,
        'total_users', active_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_block_percentile(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_block_percentile(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_block_percentile(uuid)
    IS '累計ロック時間の全ユーザー内順位。top_percent は「上位X%」表示にそのまま使う (アプリ側で max(1, round) 推奨)';

-- ============================================
-- 6. get_streak_days RPC (consecutive lock days)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_streak_days(
    target_user_id uuid,
    tz             text DEFAULT 'Asia/Tokyo'
)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    today    date;
    expected date;
    streak   integer := 0;
    d        record;
BEGIN
    -- An invalid time zone name falls back to UTC
    BEGIN
        PERFORM now() AT TIME ZONE tz;
    EXCEPTION WHEN OTHERS THEN
        tz := 'UTC';
    END;

    today := (now() AT TIME ZONE tz)::date;
    expected := today;

    FOR d IN
        SELECT DISTINCT (started_at AT TIME ZONE tz)::date AS day
        FROM public.block_sessions
        WHERE user_id = target_user_id
          AND duration_seconds IS NOT NULL
        ORDER BY day DESC
        LIMIT 400
    LOOP
        IF d.day = expected THEN
            streak := streak + 1;
            expected := expected - 1;
        ELSIF streak = 0 AND d.day = today - 1 THEN
            -- Case where you have not locked yet today but the streak through yesterday is still alive
            streak := 1;
            expected := d.day - 1;
        ELSE
            EXIT;
        END IF;
    END LOOP;

    RETURN streak;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_streak_days(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_streak_days(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.get_streak_days(uuid, text)
    IS '連続ロック日数。今日未ロックでも昨日までの連続は継続扱い。tz はクライアントの TimeZone.current.identifier';

-- ============================================
-- 7. Queries for checking behavior (no need to run, comments)
-- ============================================
-- SELECT get_block_percentile(auth.uid());
-- SELECT get_streak_days(auth.uid(), 'Asia/Tokyo');
-- SELECT get_total_block_seconds(auth.uid());
-- Check that direct updates are rejected (run as authenticated → error):
--   UPDATE users SET total_block_seconds = 99999999 WHERE id = auth.uid();
