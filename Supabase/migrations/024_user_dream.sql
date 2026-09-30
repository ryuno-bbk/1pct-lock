-- ============================================================
-- 024_user_dream.sql (v2: separate table + RLS approach)
-- Adds a "dream" (a one-line declaration of the person you want to become) to the profile
-- ============================================================
-- Purpose:
--   Entered in the onboarding DreamStepView, editable in ProfileEditView.
--   120 characters max, optional. is_public controls "whether to show it on your profile to others"
--   (default false).
--
-- Design change from v1 (2026-07-07 Fable review finding):
--   v1 added users.dream + users.dream_is_public columns and handled privacy
--   "only by choosing what to display in the app". But the users SELECT
--   policy allows everyone, so even private dreams could be read by anyone through PostgREST,
--   and the promise of the "private" toggle could not be kept at the DB level.
--   → Moved dreams to a separate table user_dreams, protected by RLS row-level control:
--     "only rows with is_public = true or your own rows can be SELECTed".
--   * v1 was replaced without ever being applied (as of 2026-07-07 there is no dream column in
--     production)
--
-- How to apply:
--   On an environment with 019 to 023 applied, paste and run it in the SQL Editor of the Supabase
--   Dashboard, or `NEW_DB_URL=... bash apply_sql.sh Supabase/migrations/024_user_dream.sql`
--
-- Run order: after 023. Idempotent (IF NOT EXISTS / DROP ... IF EXISTS)
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
-- RLS: only public rows or your own rows can be SELECTed. Writes only to your own row
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
-- Queries for checking behavior (no need to run, comments only)
-- ============================================
-- upsert your own dream:
--   INSERT INTO user_dreams (user_id, dream, is_public)
--   VALUES (auth.uid(), 'test', false)
--   ON CONFLICT (user_id) DO UPDATE SET dream = EXCLUDED.dream, is_public = EXCLUDED.is_public;
-- Other people's private rows must not be visible (with another account):
--   SELECT * FROM user_dreams WHERE user_id = '<other user uid>';  -- returns 0 rows
