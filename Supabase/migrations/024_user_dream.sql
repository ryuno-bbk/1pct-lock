-- ============================================================
-- 024_user_dream.sql (v2: 独立テーブル + RLS 方式)
-- プロフィールに「夢」(なりたい自分の一言宣言) を追加
-- ============================================================
-- 目的:
--   オンボーディング DreamStepView で入力させ、ProfileEditView で編集可能にする。
--   120文字以内、任意。is_public で「他人のプロフィールに公開するか」を制御 (既定 false)。
--
-- v1 からの設計変更 (2026-07-07 Fable レビュー指摘):
--   v1 は users.dream + users.dream_is_public 列を追加し、非公開制御を
--   「アプリ側の表示出し分けのみ」で行う設計だった。しかし users の SELECT
--   ポリシーは全員可のため、非公開の夢も PostgREST 経由で誰でも読めてしまい、
--   「非公開」トグルの約束を DB レベルで守れない。
--   → 夢を独立テーブル user_dreams に分離し、RLS の行レベル制御
--     「is_public = true の行 or 自分の行だけ SELECT 可」で守る方式に変更。
--   ※ v1 は未適用のまま差し替え (2026-07-07 時点で本番に dream 列は存在しない)
--
-- 適用方法:
--   019〜023 適用済みの環境に対し、Supabase Dashboard の SQL Editor で貼り付け実行、
--   または `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/024_user_dream.sql`
--
-- 実行順序: 023 の後。冪等 (IF NOT EXISTS / DROP ... IF EXISTS)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_dreams (
    user_id    uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    dream      text,
    is_public  boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_dreams
    DROP CONSTRAINT IF EXISTS user_dreams_length;

ALTER TABLE public.user_dreams
    ADD CONSTRAINT user_dreams_length CHECK (
        dream IS NULL OR char_length(dream) <= 120
    );

COMMENT ON TABLE public.user_dreams IS
    'なりたい自分を一言で表す宣言。120文字以内、任意。非公開 (is_public=false) の行は RLS で本人以外から見えない';

-- ============================================
-- RLS: 公開行 or 自分の行のみ SELECT 可。書き込みは自分の行のみ
-- ============================================
ALTER TABLE public.user_dreams ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_dreams_select_public_or_own" ON public.user_dreams;
DROP POLICY IF EXISTS "user_dreams_insert_own"           ON public.user_dreams;
DROP POLICY IF EXISTS "user_dreams_update_own"           ON public.user_dreams;
DROP POLICY IF EXISTS "user_dreams_delete_own"           ON public.user_dreams;

CREATE POLICY "user_dreams_select_public_or_own"
    ON public.user_dreams FOR SELECT
    USING (is_public OR auth.uid() = user_id);

CREATE POLICY "user_dreams_insert_own"
    ON public.user_dreams FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_dreams_update_own"
    ON public.user_dreams FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_dreams_delete_own"
    ON public.user_dreams FOR DELETE
    USING (auth.uid() = user_id);

-- ============================================
-- 動作確認用クエリ (実行不要、コメント)
-- ============================================
-- 自分の夢の upsert:
--   INSERT INTO user_dreams (user_id, dream, is_public)
--   VALUES (auth.uid(), 'テスト', false)
--   ON CONFLICT (user_id) DO UPDATE SET dream = EXCLUDED.dream, is_public = EXCLUDED.is_public;
-- 他人の非公開行が見えないこと (別アカウントで):
--   SELECT * FROM user_dreams WHERE user_id = '<相手のuid>';  -- 0 行になる
