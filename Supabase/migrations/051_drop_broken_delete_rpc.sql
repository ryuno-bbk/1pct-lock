-- ============================================================
-- 051_drop_broken_delete_rpc.sql
-- Remove the broken delete_my_account RPC (2026-07-25)
-- ============================================================
-- Found in the M8 live test: delete_my_account in 038 includes a direct DELETE on storage.objects,
-- but Supabase's storage.protect_delete() trigger forbids direct SQL deletion, so
-- (ERROR 42501 "Direct deletion from storage tables is not allowed. Use the Storage API
-- instead"), it always failed with an exception (the whole transaction was rolled back).
--
-- Successor: Edge Function `delete-account` (Storage API + Auth Admin API).
-- Deleting public data now relies only on the FK CASCADE from deleting auth.users
-- (001: public.users.id REFERENCES auth.users ON DELETE CASCADE), so the SQL function is no longer
-- needed.
-- ============================================================

DROP FUNCTION IF EXISTS public.delete_my_account();
