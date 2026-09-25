-- ============================================================
-- 079: user_notifications の INSERT を send-push へ流す Webhook トリガ
--
-- ✅ 2026-08-28 に本番適用済み (実際のシークレットを埋めて実行した)。
--
-- 🔴 このファイルはそのまま流せない。
--   `__PUSH_WEBHOOK_SECRET__` を実際の値に置換してから実行すること。
--   値をこのファイルに書き込んで commit しないこと (Git に平文で残るため)。
--   本番に入っている現物は下記で確認できる:
--     select pg_get_triggerdef(oid) from pg_trigger
--      where tgname = 'trg_user_notifications_push';
--
-- なぜ Dashboard の Database Webhook ではなく SQL なのか:
--   Dashboard の「Database Webhooks」は結局この形のトリガを作るだけ。
--   SQL にしておけば構成がリポジトリに残り、手作業のポチポチが要らない。
--   moderate-post 側は Dashboard 登録のままなので、そちらを触るときは注意。
--
-- 🔴 INSERT をブロックしない:
--   supabase_functions.http_request は内部で pg_net を使う非同期リクエスト。
--   トリガは即座に戻るので、いいね/コメント/フォロー自体が
--   プッシュ送信の遅延や失敗に巻き込まれることはない。
--
-- 🔴 既存の未読は飛ばない:
--   AFTER INSERT のため過去行は対象外。有効化した瞬間に
--   溜まっていた過去の通知が一斉送信される事故は構造的に起きない。
--
-- 戻すとき:
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
