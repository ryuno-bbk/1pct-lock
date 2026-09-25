-- ============================================================
-- Phase B-3: モデレーション (user_reports / user_blocks)
-- ============================================================
-- 目的:
--   1. user_reports: 通報レコード（post / user / quote が対象）
--   2. user_blocks:  ブロック関係（一方向、Twitter 方式）
--
-- 設計判断:
--   - 通報対象は post / user / quote の 3 種（公式名言も通報可）
--   - 同じ人が同じ post/quote を 2 回通報できない（嫌がらせ通報スパム防止）
--   - ブロックは一方向、相手に通知しない（Twitter 方式）
--   - 自分自身をブロックできない
--
-- 通報通知の運用（Phase C で実装、このファイルでは構造のみ）:
--   - Database Webhook → Edge Function → メール (運営宛)
--   - もしくは Web 管理画面で status='pending' を定期確認
--
-- 実行順序:
--   005 完了後（user_posts 参照のため）
-- ============================================================

-- ============================================
-- 1. user_reports テーブル
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

    -- 対象は少なくとも 1 つ必須
    CONSTRAINT user_reports_target_required CHECK (
        target_post_id IS NOT NULL
        OR target_user_id IS NOT NULL
        OR target_quote_id IS NOT NULL
    ),

    -- 同一投稿の重複通報禁止（NULL は NULL と区別、重複なし扱い）
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

-- SELECT: 自分の通報のみ閲覧可
DROP POLICY IF EXISTS "user_reports_select_own" ON public.user_reports;
CREATE POLICY "user_reports_select_own"
    ON public.user_reports FOR SELECT
    USING (auth.uid() = reporter_id);

-- INSERT: 自分の reporter_id で通報
DROP POLICY IF EXISTS "user_reports_insert_own" ON public.user_reports;
CREATE POLICY "user_reports_insert_own"
    ON public.user_reports FOR INSERT
    WITH CHECK (auth.uid() = reporter_id);

-- UPDATE: 不可（status 変更は service_role/モデレーション RPC）
-- DELETE: 不可（通報の取り消しは認めない、運営側で dismiss）

-- ============================================
-- 3. user_blocks テーブル
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

-- SELECT: 自分がブロックしてる関係のみ閲覧可
-- ブロックされた側は誰がブロックしてるかわからない
DROP POLICY IF EXISTS "user_blocks_select_own" ON public.user_blocks;
CREATE POLICY "user_blocks_select_own"
    ON public.user_blocks FOR SELECT
    USING (auth.uid() = blocker_id);

-- INSERT: 自分の blocker_id でブロック追加
DROP POLICY IF EXISTS "user_blocks_insert_own" ON public.user_blocks;
CREATE POLICY "user_blocks_insert_own"
    ON public.user_blocks FOR INSERT
    WITH CHECK (auth.uid() = blocker_id);

-- DELETE: 自分のブロック解除のみ
DROP POLICY IF EXISTS "user_blocks_delete_own" ON public.user_blocks;
CREATE POLICY "user_blocks_delete_own"
    ON public.user_blocks FOR DELETE
    USING (auth.uid() = blocker_id);

-- UPDATE: 不可

-- ============================================
-- 5. ブロック時にフォロー関係も双方向解除する trigger
-- ============================================
-- ユーザーが他人をブロックしたら、お互いのフォロー関係は強制解除
CREATE OR REPLACE FUNCTION public.unfollow_on_block()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- 自分 → 相手のフォロー削除
    DELETE FROM public.user_follows
    WHERE follower_id = NEW.blocker_id
      AND followed_user_id = NEW.blocked_user_id;
    -- 相手 → 自分のフォロー削除
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
