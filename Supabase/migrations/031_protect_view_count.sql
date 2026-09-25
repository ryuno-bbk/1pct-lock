-- ============================================================
-- 031_protect_view_count.sql
-- 【致命度: 中】user_posts.view_count の投稿者による自己改ざん防止
-- ============================================================
-- 発見の経緯:
--   028_bereal_ui.sql で user_posts.view_count を plain int 列として追加。
--   user_posts_update_own ポリシー (005_b_user_posts.sql:100-103) は
--   投稿者による行全体の UPDATE を許可する。like_count / comment_count は
--   015_security_audit.sql の protect_user_posts_like_count trigger で、
--   moderation_status / moderation_verdict は 027_ai_moderation.sql の
--   protect_user_posts_moderation trigger で読み取り専用化済みだが、
--   view_count には同種のガードが一切ない。
--   → 投稿者が PostgREST 経由で
--       PATCH /user_posts?id=eq.<own_post> { "view_count": 999999 }
--     を叩くと成功する。view_count は全ユーザーに表示され、かつ
--     029_recommend_feed.sql の fetch_mixed_feed_random スコアリングの
--     入力にもなるため、閲覧数の水増しがそのままフィード露出の水増しに直結する。
--
-- 修正方針 (015 の protect_user_posts_like_count と全く同じ機構を流用):
--   - protect_user_posts_like_count trigger 関数を CREATE OR REPLACE し、
--     like_count / comment_count に加えて view_count のガード条件を追加する。
--     既存の DROP TRIGGER IF EXISTS + CREATE TRIGGER の対 (005/015 で作成済み、
--     関数名 protect_user_posts_like_count / trigger 名
--     user_posts_protect_like_count) はそのまま再利用する。新しい trigger は作らない。
--   - 判定ロジックは 015/027 と同じ rolbypassrls パターン:
--       SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolbypassrls
--     を満たすロール (service_role, SECURITY DEFINER 関数の所有者 postgres) は
--     素通りさせ、それ以外の一般 authenticated ロールの直接 UPDATE のみ拒否する。
--
-- record_post_view (028) が引き続き動作することの確認 (コードトレース):
--   - toggle_post_like (005/015) は SECURITY DEFINER 関数で、関数所有者は
--     postgres。postgres ロールは rolbypassrls = true のため、関数内から実行される
--     `UPDATE user_posts SET like_count = ...` は protect trigger の
--     「rolbypassrls なら RETURN NEW」の分岐に入り、ガードを素通りする。
--     current_user は「関数を呼び出したセッションのロール」ではなく
--     「SECURITY DEFINER 関数の実行時ロール = 所有者」になる点がポイント
--     (015 のコメントにある通り current_setting('role') ではなく rolbypassrls で
--     判定するのはこのため)。
--   - record_post_view (028_bereal_ui.sql:56-94) も同じく
--     `LANGUAGE plpgsql SECURITY DEFINER` かつ所有者は postgres。
--     関数内の `UPDATE public.user_posts SET view_count = view_count + 1
--     WHERE id = target_post_id;` (028行目 90-92) は toggle_post_like の
--     like_count 更新と全く同じ経路 (SECURITY DEFINER → postgres →
--     rolbypassrls=true → trigger 素通り) を通るため、本 migration 適用後も
--     record_post_view による view_count 加算は変更なく成功する。
--   - 一方、投稿者が PostgREST 経由で直接
--     `UPDATE user_posts SET view_count = ... WHERE id = own_post` を叩く場合は
--     current_user が authenticated ロール (rolbypassrls=false) のままなので
--     trigger のガードに掛かり拒否される。
--
-- 実行順序: 015・027・028 適用後。何度実行しても安全 (CREATE OR REPLACE のみ、
-- 新規オブジェクト作成なし)
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_user_posts_like_count()
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
    IF NEW.like_count <> OLD.like_count THEN
        RAISE EXCEPTION 'like_count is read-only for users (use toggle_post_like)';
    END IF;
    IF NEW.comment_count <> OLD.comment_count THEN
        RAISE EXCEPTION 'comment_count is read-only for users';
    END IF;
    IF NEW.view_count <> OLD.view_count THEN
        RAISE EXCEPTION 'view_count is read-only for users (use record_post_view)';
    END IF;
    RETURN NEW;
END;
$$;

-- 既存 trigger (005/015 で作成済み) はそのまま。関数の中身だけが差し替わる。
-- 念のため存在確認して未作成なら張り直す (015 未適用のまま本 migration だけ
-- 走らせるケースへの保険。通常は既に存在しているため NOTICE も出ない)
DROP TRIGGER IF EXISTS user_posts_protect_columns   ON public.user_posts; -- 旧トリガー名 (S1 草案)
DROP TRIGGER IF EXISTS user_posts_protect_like_count ON public.user_posts;
CREATE TRIGGER user_posts_protect_like_count
    BEFORE UPDATE ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_posts_like_count();

-- ============================================
-- 動作確認用クエリ (実行不要、コメント / verify_026_028.sql と同じ貼り付け形式)
-- ============================================
-- (a) 自分の投稿の view_count を直接書き換えようとして拒否されることの確認
--     (authenticated として実行 → エラーになること: "view_count is read-only for users")
--   UPDATE user_posts SET view_count = 999999
--     WHERE id = '<自分が所有する post の id>' AND user_id = auth.uid();
--
-- (b) record_post_view が引き続き view_count を加算できることの確認
--     (authenticated として、自分以外が所有する post に対して実行)
--   SELECT view_count FROM user_posts WHERE id = '<他人の post の id>'; -- 実行前の値を確認
--   SELECT record_post_view('<他人の post の id>');
--   SELECT view_count FROM user_posts WHERE id = '<他人の post の id>'; -- +1 されていること
--
-- (c) 適用確認 (verify_026_028.sql スタイル、SQL Editor に貼って ok=true を確認)
--   SELECT * FROM (
--       SELECT '031' AS mig, 'trigger user_posts_protect_like_count guards view_count' AS object,
--              EXISTS(
--                  SELECT 1 FROM pg_proc
--                  WHERE proname = 'protect_user_posts_like_count'
--                    AND prosrc LIKE '%view_count%'
--              ) AS ok
--   ) t;
