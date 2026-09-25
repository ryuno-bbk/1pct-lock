-- ============================================================
-- 054_appeal_unsure_operator_notify.sql
-- unsure 申し立ての運営向け通知 (2026-07-30 ユーザー要望
-- 「unsureが出たら本人には知らせず俺に通知、俺が見て判断する」)
-- ============================================================
-- 仕組み: review-appeal v4 が decision='unsure' を書いた直後に
-- create_notification RPC で moderation_config.operator_user_id 宛に
-- kind='appeal_unsure' のアプリ内通知 (ベル) を作る。
-- 申し立て本人には何も送られない (本人の表示は「審査中」のまま)。
--
-- ⚠️ 適用後にユーザー作業が1つ: operator_user_id に自分のアカウントを設定
--   (下の「運営アカウント設定」参照)。未設定の間は通知が作られないだけで
--   他の動作に影響なし (fail-soft)。
--
-- 冪等: DROP IF EXISTS → ADD / IF NOT EXISTS / CREATE OR REPLACE パターン。
-- ロールバック: operator_user_id を NULL にすれば通知は止まる。
-- ============================================================

-- 1. kind 許可リストに appeal_unsure を追加 (039 の10種 + 1)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN (
            'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post',
            'content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
            'appeal_unsure'
        )
    );

-- 2. 自己参照の許可リストにも追加
--    (通常は recipient=運営 ≠ actor=申し立て者 だが、運営自身の投稿で
--     テストする場合に recipient=actor になるため)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_no_self;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_no_self CHECK (
        recipient_user_id <> actor_user_id
        OR kind IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
                    'appeal_unsure')
    );

-- 3. create_notification の自己アクション弾きにも同じ例外を追加
--    (039 定義から変更箇所は IF 条件の kind リストのみ)
CREATE OR REPLACE FUNCTION public.create_notification(
    p_recipient_user_id uuid,
    p_actor_user_id     uuid,
    p_kind              text,
    p_target_post_id    uuid DEFAULT NULL,
    p_target_quote_id   uuid DEFAULT NULL,
    p_target_comment_id uuid DEFAULT NULL,
    p_preview_text      text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_recipient_user_id IS NULL OR p_actor_user_id IS NULL THEN
        RETURN;
    END IF;
    IF p_recipient_user_id = p_actor_user_id
       AND p_kind NOT IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected',
                          'appeal_unsure') THEN
        RETURN;  -- 自分発は通知しない (システム通知系 kind は自己参照を許可)
    END IF;
    INSERT INTO public.user_notifications (
        recipient_user_id, actor_user_id, kind,
        target_post_id, target_quote_id, target_comment_id, preview_text
    ) VALUES (
        p_recipient_user_id, p_actor_user_id, p_kind,
        p_target_post_id, p_target_quote_id, p_target_comment_id, p_preview_text
    )
    ON CONFLICT ON CONSTRAINT user_notifications_unique_like DO NOTHING;
END;
$$;

-- 4. 運営アカウントの設定列
ALTER TABLE public.moderation_config
    ADD COLUMN IF NOT EXISTS operator_user_id uuid
        REFERENCES public.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.moderation_config.operator_user_id IS
    'unsure 申し立ての通知先 (運営アカウントの users.id)。NULL なら通知しない。'
    'review-appeal v4 が参照';

-- ============================================================
-- 運営アカウント設定 (ユーザー作業、適用後に1回だけ):
--   ① 自分の id を確認:
--        SELECT id, handle, display_name FROM public.users
--        ORDER BY created_at LIMIT 10;
--   ② 設定:
--        UPDATE public.moderation_config SET operator_user_id = '<自分のid>';
-- ============================================================
