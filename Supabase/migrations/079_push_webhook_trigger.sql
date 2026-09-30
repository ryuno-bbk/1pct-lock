-- ============================================================
-- 079: Webhook trigger that sends INSERTs into user_notifications to send-push
--
-- ✅ Applied to production on 2026-08-28 (run with the real secret filled in).
--
-- 🔴 This file cannot be run as is.
--   Replace `__PUSH_WEBHOOK_SECRET__` with the real value before running it.
--   Do not write the value into this file and commit it (it would stay in Git in plain text).
--   The version actually in production can be checked with:
--     select pg_get_triggerdef(oid) from pg_trigger
--      where tgname = 'trg_user_notifications_push';
--
-- Why SQL and not a Database Webhook in the Dashboard:
--   The Dashboard's "Database Webhooks" only creates a trigger of this form anyway.
--   With SQL, the configuration stays in the repository and no manual clicking is needed.
--   The moderate-post side is still registered via the Dashboard, so be careful when touching it.
--
-- 🔴 Does not block the INSERT:
--   supabase_functions.http_request is an async request that uses pg_net internally.
--   The trigger returns immediately, so likes/comments/follows themselves are never
--   dragged into push send delays or failures.
--
-- 🔴 Existing unread notifications are not sent:
--   Because it is AFTER INSERT, past rows are out of scope. An accident where the backlog of
--   past notifications all goes out at once the moment it is enabled cannot happen by design.
--
-- To revert:
--   drop trigger if exists trg_user_notifications_push on public.user_notifications;
-- ============================================================

drop trigger if exists trg_user_notifications_push on public.user_notifications;

create trigger trg_user_notifications_push
    after insert on public.user_notifications
    for each row
    execute function supabase_functions.http_request(
        'https://uzhoghjgsjujergdzadt.supabase.co/functions/v1/send-push',
        'POST',
        '{"Content-Type":"application/json","x-push-secret":"__PUSH_WEBHOOK_SECRET__"}',
        '{}',
        '10000'
    );
