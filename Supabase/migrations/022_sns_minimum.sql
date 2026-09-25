-- ============================================================
-- 022_sns_minimum.sql
-- SNS最低限パック: ハンドル(@handle) + ユーザー検索 + 新規投稿通知
-- ============================================================
-- 目的:
--   1. users.handle (@handle) の導入。フォーマット/予約語チェック + 一意制約
--      + 既存ユーザーへの自動バックフィル
--   2. is_handle_available(h) RPC: ハンドル編集画面のリアルタイム空き確認用
--   3. search_users(query, limit_count) RPC: ユーザー検索画面用
--   4. user_notifications.kind に 'new_post' を追加し、フォロー中ユーザーの
--      新規投稿を全フォロワーに通知するトリガーを追加
--
-- 適用対象: 019 / 020 / 021 が適用済みの環境。
-- 適用方法:
--   Supabase Dashboard の SQL Editor で貼り付け実行、または
--   `NEW_DB_URL=... bash apply_sql.sh supabase/migrations/022_sns_minimum.sql`
--
-- 実行順序: 021 完了後。何度実行しても安全
--   (IF NOT EXISTS / DROP ... IF EXISTS / ON CONFLICT パターンで冪等)
-- ============================================================

-- ============================================
-- 1. users.handle 列追加
-- ============================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS handle text;

COMMENT ON COLUMN public.users.handle IS
    '@handle。小文字英数字+ドット+アンダースコア、3〜20文字、一意。予約語は使用不可';

-- フォーマット制約 (小文字/数字/ドット/アンダースコアのみ、3〜20文字)
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_handle_format;

ALTER TABLE public.users
    ADD CONSTRAINT users_handle_format CHECK (
        handle IS NULL OR handle ~ '^[a-z0-9._]{3,20}$'
    );

-- 予約語制約 (公式アカウント / 運営関連ハンドルの詐称防止)
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_handle_not_reserved;

ALTER TABLE public.users
    ADD CONSTRAINT users_handle_not_reserved CHECK (
        handle IS NULL OR lower(handle) NOT IN (
            'onepercent', 'one_percent', '1percent',
            'official', 'admin', 'arete', 'support', 'moderator', 'system'
        )
    );

-- 一意インデックス (NULL は複数許容、値がある場合のみ一意)
CREATE UNIQUE INDEX IF NOT EXISTS users_handle_unique
    ON public.users (handle)
    WHERE handle IS NOT NULL;

-- ============================================
-- 2. 既存ユーザーへのバックフィル
-- ============================================
-- uuid 先頭 8 桁 (16進数) から機械的に生成。理論上の衝突確率は無視できる水準だが、
-- 冪等な再実行 + 万一の衝突に備えて桁数を伸ばしながら重複を回避する。
-- (フォーマット制約が {3,20} 文字までのため 'user_' プレフィックス込みで最大20文字 = 15桁まで)
DO $$
DECLARE
    r         RECORD;
    candidate text;
    hex_id    text;
BEGIN
    FOR r IN SELECT id FROM public.users WHERE handle IS NULL LOOP
        hex_id    := replace(r.id::text, '-', '');
        candidate := 'user_' || substr(hex_id, 1, 8);

        IF EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) THEN
            candidate := 'user_' || substr(hex_id, 1, 12);
        END IF;

        IF EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) THEN
            candidate := 'user_' || substr(hex_id, 1, 15);
        END IF;

        -- 最終フォールバック (天文学的に低確率): ランダム値で衝突が消えるまで再生成
        WHILE EXISTS (SELECT 1 FROM public.users WHERE handle = candidate) LOOP
            candidate := 'user_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
        END LOOP;

        UPDATE public.users SET handle = candidate WHERE id = r.id;
    END LOOP;
END $$;

-- ============================================
-- 3. is_handle_available RPC
-- ============================================
-- 形式合致 AND 予約語でない AND 他ユーザーに存在しない (自分自身の現ハンドルは利用可能扱い)
CREATE OR REPLACE FUNCTION public.is_handle_available(h text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    normalized text := lower(trim(h));
BEGIN
    IF normalized IS NULL OR normalized !~ '^[a-z0-9._]{3,20}$' THEN
        RETURN false;
    END IF;

    IF normalized IN (
        'onepercent', 'one_percent', '1percent',
        'official', 'admin', 'arete', 'support', 'moderator', 'system'
    ) THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.users
        WHERE handle = normalized
          AND id IS DISTINCT FROM auth.uid()
    ) THEN
        RETURN false;
    END IF;

    RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.is_handle_available(text) FROM PUBLIC;
-- anon にも許可する (意図的):
-- オンボーディングは nameInput (@handle 入力) → appleSignIn の順で、
-- 可用性チェックはサインイン前 = anon で実行される。anon を弾くと
-- 全新規ユーザーがオンボを通過できなくなる。この RPC が漏らすのは
-- 「その handle が既に存在するか」だけで、プロフィールは元々公開情報。
GRANT EXECUTE ON FUNCTION public.is_handle_available(text) TO anon;
GRANT EXECUTE ON FUNCTION public.is_handle_available(text) TO authenticated;

-- ============================================
-- 4. search_users RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.search_users(
    query       text,
    limit_count integer DEFAULT 30
)
RETURNS TABLE (
    id           uuid,
    display_name text,
    handle       text,
    avatar_url   text,
    is_pro       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        u.id,
        u.display_name,
        u.handle,
        u.avatar_url,
        COALESCE(u.is_pro, false) AS is_pro
    FROM public.users u
    WHERE query IS NOT NULL
      AND trim(query) <> ''
      AND (
        u.handle LIKE lower(query) || '%'
        OR u.display_name ILIKE '%' || query || '%'
      )
      AND u.id NOT IN (
        SELECT blocked_user_id FROM public.user_blocks WHERE blocker_id = auth.uid()
      )
    ORDER BY
        CASE WHEN u.handle LIKE lower(query) || '%' THEN 0 ELSE 1 END,
        u.handle
    LIMIT limit_count;
$$;

REVOKE EXECUTE ON FUNCTION public.search_users(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_users(text, integer) TO authenticated;

-- ============================================
-- 5. user_notifications.kind に 'new_post' を追加
-- ============================================
-- 014 で定義された無名 CHECK 制約の Postgres デフォルト命名 (user_notifications_kind_check) を差し替え
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN ('like', 'follow', 'comment', 'reply', 'comment_like', 'new_post')
    );

-- ============================================
-- 6. notify_followers_on_post トリガー (新規投稿 → フォロワー全員へ通知)
-- ============================================
-- 投稿者本人は対象外 (user_follows_no_self 制約で follower=poster は元々存在しない)。
-- 投稿者をブロックしているフォロワーは除外。
-- create_notification が自分発アクション弾き + 重複防止 (ON CONFLICT) を内部で処理する。
CREATE OR REPLACE FUNCTION public.notify_followers_on_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    follower RECORD;
BEGIN
    FOR follower IN
        SELECT uf.follower_id
        FROM public.user_follows uf
        WHERE uf.followed_user_id = NEW.user_id
          AND NOT EXISTS (
            SELECT 1 FROM public.user_blocks ub
            WHERE ub.blocker_id = uf.follower_id
              AND ub.blocked_user_id = NEW.user_id
          )
    LOOP
        PERFORM public.create_notification(
            p_recipient_user_id => follower.follower_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'new_post',
            p_target_post_id    => NEW.id
        );
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_notify_followers ON public.user_posts;
CREATE TRIGGER user_posts_notify_followers
    AFTER INSERT ON public.user_posts
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_followers_on_post();

-- ============================================
-- 7. 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- ハンドル空き確認:
--   SELECT is_handle_available('taro123');
-- ユーザー検索:
--   SELECT * FROM search_users('taro', 30);
-- バックフィル確認 (NULL が残っていないこと):
--   SELECT count(*) FROM users WHERE handle IS NULL;
