-- ============================================================
-- Phase B-1: authors.is_official 列追加
-- ============================================================
-- 目的:
--   公式（偉人）vs 一般ユーザー（将来 UGC の投稿者を authors として
--   扱う可能性も想定）を区別する is_official 列を追加
--
-- 注意:
--   現在の方針では UGC 投稿者は public.users に紐付け、authors は
--   公式偉人のみとする (A 案確定)。
--   将来運用判断で変わる可能性があるので列だけ用意しておく。
--
-- 実行順序:
--   Phase A 完了後、B フェーズの任意タイミングで実行可
-- ============================================================

-- ============================================
-- 1. is_official 列追加
-- ============================================
ALTER TABLE public.authors
    ADD COLUMN IF NOT EXISTS is_official boolean NOT NULL DEFAULT false;

-- 既存 58 件は全部偉人 → is_official = true
UPDATE public.authors SET is_official = true;

-- ============================================
-- 2. インデックス（フィードで公式マーク表示時に効く）
-- ============================================
CREATE INDEX IF NOT EXISTS idx_authors_official
    ON public.authors(is_official) WHERE is_official = true;

COMMENT ON COLUMN public.authors.is_official IS '公式偉人フラグ。UI ではこの true の author に青チェックバッジ表示';
