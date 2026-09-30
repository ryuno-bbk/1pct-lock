-- ============================================================
-- 082_block_ranking.sql
-- Ranking (total lock time) + change the top percentile population to "all real users"
-- ============================================================
-- User decisions (2026-09-05):
--
--   1. 🔴 The top percentile population also includes "people who have never locked".
--      In 016 the population was only people with total_block_seconds > 0.
--      → Changed to all real users.
--      Reason: being above people with 0 hours is a fact, not a lie. The larger the population,
--            the better "top ◯%" looks, and the more people can hold the TOP10% badge.
--
--      🔴 However, if the user themselves has 0 seconds, has_data stays false.
--        Showing "top 28%" to someone who has never locked would be a display that praises
--        doing nothing.
--
--   2. 🔴 Seed accounts (`%@seed.invalid`) are excluded from both the population and the list.
--      Since we are building a screen that lists names in a ranking, we do not mix in people who do
--      not exist.
--
--   3. ⚠️ No anti-cheat measures are added (user's decision).
--      `block_sessions` is self-reported by the device, so the ranking is not robust against tampering.
--      The warning in 016's design memo still stands, but the decision was: "we'll add measures once
--      there are more users. Even if someone games it, that's fine as long as it makes the others
--      look good".
--      🔴 When adding features that show the rank more prominently, reconsider this decision.
--
-- Run order: after 081. Safe to run any number of times
-- To revert: re-apply the get_block_percentile definition from 016, and
--           drop function if exists public.get_block_ranking(integer);
-- ============================================================

-- ============================================
-- 1. Helper that checks for a real user
-- ============================================
-- It reads auth.users, so SECURITY DEFINER is needed.
-- 🔴 Not public (so nobody can infer who has which credentials)
CREATE OR REPLACE FUNCTION public.is_real_user(target_user_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM auth.users a
         WHERE a.id = target_user_id
           AND (a.email IS NULL OR a.email NOT LIKE '%@seed.invalid')
    );
$$;

REVOKE EXECUTE ON FUNCTION public.is_real_user(uuid) FROM PUBLIC, anon, authenticated;

-- ============================================
-- 2. Replace get_block_percentile with the version with the new population (signature unchanged)
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

    -- 🔴 If the user themselves has no lock record, keep it hidden as before.
    --    Including them in the population and showing them a rank are separate things (we do not praise
    --    people who do nothing)
    IF my_total IS NULL OR my_total = 0 THEN
        RETURN jsonb_build_object('has_data', false);
    END IF;

    -- Population = all real users (including people with 0 seconds / excluding seed accounts)
    SELECT count(*) INTO active_count
    FROM public.users u
    JOIN auth.users a ON a.id = u.id
    WHERE a.email IS NULL OR a.email NOT LIKE '%@seed.invalid';

    -- Number of real users with more than you
    SELECT count(*) INTO higher_count
    FROM public.users u
    JOIN auth.users a ON a.id = u.id
    WHERE u.total_block_seconds > my_total
      AND (a.email IS NULL OR a.email NOT LIKE '%@seed.invalid');

    RETURN jsonb_build_object(
        'has_data',    true,
        'top_percent', ROUND((higher_count + 1)::numeric / GREATEST(active_count, 1) * 100, 1),
        'rank',        higher_count + 1,
        'total_users', active_count
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_block_percentile(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_block_percentile(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_block_percentile(uuid)
    IS '累計ロック時間の順位。母数=全実ユーザー(0秒含む/種除く)。本人が0秒なら has_data=false (082)';

-- ============================================
-- 3. Ranking list RPC
-- ============================================
-- 🔴 Only "people in the top 10%" are shown (user's decision).
--    The larger the population, the more people are listed.
--    Users can see their own rank from their profile, so there is no need to show people outside the
--    range here.
CREATE OR REPLACE FUNCTION public.get_block_ranking(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total  integer;
    v_cutoff integer;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;

    SELECT count(*) INTO v_total
    FROM public.users u
    JOIN auth.users a ON a.id = u.id
    WHERE a.email IS NULL OR a.email NOT LIKE '%@seed.invalid';

    -- Top 10% (show at least 10 people. While the population is small, showing only 1 or 2 people would
    -- not make a usable screen)
    v_cutoff := GREATEST(10, CEIL(v_total * 0.10)::integer);
    v_cutoff := LEAST(v_cutoff, v_limit);

    SELECT COALESCE(jsonb_agg(row_json ORDER BY rnk), '[]'::jsonb)
      INTO v_result
      FROM (
          SELECT rnk,
                 jsonb_build_object(
                     'rank',          rnk,
                     'user_id',       id,
                     'handle',        handle,
                     'display_name',  display_name,
                     'avatar_url',    avatar_url,
                     'is_pro',        is_pro,
                     'is_official',   is_official,
                     'total_seconds', total_block_seconds,
                     'is_me',         (id = auth.uid())
                 ) AS row_json
            FROM (
                SELECT u.id, u.handle, u.display_name, u.avatar_url,
                       u.is_pro, u.is_official, u.total_block_seconds,
                       row_number() OVER (ORDER BY u.total_block_seconds DESC, u.id) AS rnk
                  FROM public.users u
                  JOIN auth.users a ON a.id = u.id
                 WHERE u.total_block_seconds > 0
                   AND (a.email IS NULL OR a.email NOT LIKE '%@seed.invalid')
            ) ranked
           WHERE rnk <= v_cutoff
      ) q;

    RETURN jsonb_build_object(
        'total_users', v_total,
        'shown',       v_cutoff,
        'rows',        v_result
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_block_ranking(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_block_ranking(integer) TO authenticated;

COMMENT ON FUNCTION public.get_block_ranking(integer)
    IS '累計ロック時間の上位10% (最低10人)。種アカウントは除外。自分の順位は get_block_percentile 側';

-- ============================================
-- 4. For checking behavior (no need to run)
-- ============================================
-- select public.get_block_ranking(50);
-- select public.get_block_percentile((select id from public.users order by total_block_seconds desc limit 1));
