-- ============================================================
-- Phase B-1: add the authors.is_official column
-- ============================================================
-- Purpose:
--   Add an is_official column that distinguishes official (great historical figures) vs regular users
--   (also considering the possibility of treating UGC authors as authors in the future)
--
-- Note:
--   Under the current policy, UGC authors are linked to public.users, and authors holds only the
--   official great figures (plan A confirmed).
--   This may change with future operating decisions, so only the column is prepared.
--
-- Execution order:
--   After Phase A is done, can run at any time during phase B
-- ============================================================

-- ============================================
-- 1. Add the is_official column
-- ============================================
ALTER TABLE public.authors
    ADD COLUMN IF NOT EXISTS is_official boolean NOT NULL DEFAULT false;

-- The existing 58 rows are all great figures → is_official = true
UPDATE public.authors SET is_official = true;

-- ============================================
-- 2. Index (helps when showing the official badge in the feed)
-- ============================================
CREATE INDEX IF NOT EXISTS idx_authors_official
    ON public.authors(is_official) WHERE is_official = true;

COMMENT ON COLUMN public.authors.is_official IS '公式偉人フラグ。UI ではこの true の author に青チェックバッジ表示';
