-- ============================================================
-- 051_drop_broken_delete_rpc.sql
-- 壊れていた delete_my_account RPC の撤去 (2026-07-25)
-- ============================================================
-- M8 実弾テストで発覚: 038 の delete_my_account は storage.objects への直接 DELETE を
-- 含むが、Supabase の storage.protect_delete() トリガーが SQL 直削除を禁止しているため
-- (ERROR 42501 "Direct deletion from storage tables is not allowed. Use the Storage API
-- instead")、必ず例外で失敗していた (トランザクションごとロールバック)。
--
-- 後継: Edge Function `delete-account` (Storage API + Auth Admin API)。
-- public データの削除は auth.users 削除の FK CASCADE (001: public.users.id REFERENCES
-- auth.users ON DELETE CASCADE) に一本化され、SQL 関数は不要になった。
-- ============================================================

DROP FUNCTION IF EXISTS public.delete_my_account();
