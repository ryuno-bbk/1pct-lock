-- ============================================================
-- 078: プッシュ通知のデバイストークン置き場 (user_push_tokens)
--
-- 背景:
--   user_notifications は動いているのに配信手段が無く、
--   通知の大半が未読のまま死んでいた。アプリ内ベルしか導線が無いため。
--   ここはその配信経路の土台 = 「どの端末に送るか」を持つだけのテーブル。
--
-- 配信の流れ (moderate-post と同じ形に揃えてある):
--   user_notifications へ INSERT
--     → Supabase Database Webhook (Dashboard で登録 = ユーザー作業)
--     → Edge Function `send-push`
--     → このテーブルから受信者の端末トークンを引いて APNs へ
--
-- 🔴 既存の未読102件は飛ばない:
--   Webhook は INSERT イベントにしか反応しない。過去行は対象外なので、
--   有効化した瞬間に102通が一斉送信される事故は構造的に起きない。
--
-- 🔴 environment を持つ理由:
--   開発ビルド = サンドボックス APNs / TestFlight・App Store = 本番 APNs。
--   ホストが違うので、トークンだけ持っていても「開発では届くが本番で無音」を踏む。
--   どちらで登録されたトークンかを端末側に申告させ、送信側がホストを選ぶ。
--
-- 適用: supabase db push (または ./apply_sql.sh)
-- 戻すとき:
--   drop function if exists public.delete_push_token(text);
--   drop function if exists public.upsert_push_token(text, text);
--   drop table if exists public.user_push_tokens;
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_push_tokens (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    -- APNs のデバイストークン (16進64文字)。再インストール/機種変で別物になる
    token        text NOT NULL,
    platform     text NOT NULL DEFAULT 'ios'
                     CHECK (platform IN ('ios')),
    environment  text NOT NULL
                     CHECK (environment IN ('sandbox', 'production')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    -- 同じ端末トークンは常に1行。端末を人に渡す/別アカウントでログインし直すと
    -- 持ち主が変わるため、user_id ではなく token 単体を一意にする
    CONSTRAINT user_push_tokens_token_unique UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS idx_user_push_tokens_user
    ON public.user_push_tokens (user_id);

-- ============================================
-- RLS: 自分のトークンだけ
-- ============================================
ALTER TABLE public.user_push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_push_tokens_select_own" ON public.user_push_tokens;
CREATE POLICY "user_push_tokens_select_own"
    ON public.user_push_tokens FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT / UPDATE はクライアント直接禁止 (下の SECURITY DEFINER RPC 経由のみ)。
-- 直 upsert を許すと「他人が持っているトークンを自分に付け替える」経路が塞げない
-- (INSERT の WITH CHECK は通るが ON CONFLICT の UPDATE が他人の行に当たるため)

DROP POLICY IF EXISTS "user_push_tokens_delete_own" ON public.user_push_tokens;
CREATE POLICY "user_push_tokens_delete_own"
    ON public.user_push_tokens FOR DELETE
    USING (auth.uid() = user_id);

-- 065 と同じ方針: anon は一切触れない
REVOKE ALL ON TABLE public.user_push_tokens FROM anon;
GRANT SELECT, DELETE ON TABLE public.user_push_tokens TO authenticated;

-- ============================================
-- RPC: トークン登録 (端末が起動のたびに呼ぶ / 冪等)
-- ============================================
-- SECURITY DEFINER にする理由:
--   同じ端末で別アカウントにログインし直すと、既存行の user_id を「奪う」必要がある。
--   RLS 下の upsert では他人の行を UPDATE できず失敗するため、ここで付け替える。
--   付け替えは「そのトークンを今まさに提示できている端末」からの要求なので安全
--   (トークンは端末と APNs しか知らない)。
CREATE OR REPLACE FUNCTION public.upsert_push_token(
    p_token       text,
    p_environment text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;

    IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
        RAISE EXCEPTION 'token is required';
    END IF;

    IF p_environment NOT IN ('sandbox', 'production') THEN
        RAISE EXCEPTION 'environment must be sandbox or production';
    END IF;

    INSERT INTO public.user_push_tokens (user_id, token, platform, environment)
    VALUES (v_uid, trim(p_token), 'ios', p_environment)
    ON CONFLICT ON CONSTRAINT user_push_tokens_token_unique DO UPDATE
        SET user_id     = EXCLUDED.user_id,
            environment = EXCLUDED.environment,
            updated_at  = now();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_push_token(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.upsert_push_token(text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.upsert_push_token(text, text) TO authenticated;

-- ============================================
-- RPC: トークン削除 (サインアウト時)
-- ============================================
-- サインアウト後もトークンが残っていると、次にその端末を使う人に
-- 前の持ち主宛ての通知が飛ぶ。サインアウトで必ず消す。
CREATE OR REPLACE FUNCTION public.delete_push_token(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RETURN;  -- 既にサインアウト済みなら何もしない (エラーにしない)
    END IF;

    DELETE FROM public.user_push_tokens
    WHERE token = trim(p_token)
      AND user_id = v_uid;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_push_token(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_push_token(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.delete_push_token(text) TO authenticated;
