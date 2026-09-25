-- ============================================================
-- 082_block_ranking.sql
-- ランキング (累計ロック時間) + 上位% の母数を「全実ユーザー」へ変更
-- ============================================================
-- ユーザー決定 (2026-09-05):
--
--   1. 🔴 上位% の母数に「一度もロックしていない人」も入れる。
--      016 では母数 = total_block_seconds > 0 の人だけだった。
--      → 全実ユーザーに変える。
--      理由: 0時間の人より上なのは事実であり嘘ではない。母数が増えるほど
--            「上位◯%」の見え方が良くなり、TOP10%バッジを持てる人数も増える。
--
--      🔴 ただし本人が 0 秒の場合は has_data=false のまま。
--        ロックしたことがない人に「上位28%」と出すと、何もしないことを
--        称える表示になってしまう。
--
--   2. 🔴 種アカウント (`%@seed.invalid`) は母数からも一覧からも外す。
--      ランキングに名前が並ぶ画面を作る以上、実在しない人を混ぜない。
--
--   3. ⚠️ チート対策は入れない (ユーザー判断)。
--      `block_sessions` は端末申告なので、順位は改ざんに強くない。
--      016 の設計メモの警告は生きているが、「ユーザーが増えてから対策する。
--      変な稼ぎ方をする人が居ても、周りを引き立ててくれるならそれでいい」との判断。
--      🔴 順位を強く見せる機能を足すときは、この判断を再検討すること。
--
-- 実行順序: 081 の後。何度実行しても安全
-- 戻すとき: 016 の get_block_percentile 定義を再適用し、
--           drop function if exists public.get_block_ranking(integer);
-- ============================================================

-- ============================================
-- 1. 実ユーザー判定のヘルパー
-- ============================================
-- auth.users を参照するので SECURITY DEFINER が要る。
-- 🔴 公開しない (誰がどの認証情報を持つかを推測させないため)
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
-- 2. get_block_percentile を母数変更版に差し替え (シグネチャ不変)
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

    -- 🔴 本人にロック実績が無い場合は今までどおり非表示。
    --    母数に入れることと、本人に順位を見せることは別 (何もしない人を称えない)
    IF my_total IS NULL OR my_total = 0 THEN
        RETURN jsonb_build_object('has_data', false);
    END IF;

    -- 母数 = 全実ユーザー (0秒の人も含む / 種アカは除く)
    SELECT count(*) INTO active_count
    FROM public.users u
    JOIN auth.users a ON a.id = u.id
    WHERE a.email IS NULL OR a.email NOT LIKE '%@seed.invalid';

    -- 自分より多い実ユーザーの数
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
-- 3. ランキング一覧 RPC
-- ============================================
-- 🔴 出すのは「上位10%に入っている人」だけ (ユーザー決定)。
--    母数が増えるほど掲載人数も増える。
--    自分の順位はプロフィールから見られるので、圏外の人をここに出す必要はない。
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

    -- 上位10% (最低でも10人は出す。母数が小さいうちに1〜2人しか出ないと画面が成立しない)
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
-- 4. 動作確認用 (実行不要)
-- ============================================
-- select public.get_block_ranking(50);
-- select public.get_block_percentile((select id from public.users order by total_block_seconds desc limit 1));
