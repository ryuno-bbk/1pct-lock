// ============================================================
// delete-account / index.ts
// アカウント完全削除 Edge Function (2026-07-25)
// ============================================================
// 背景: 038 の delete_my_account RPC は storage.objects を直接 DELETE していたが、
// Supabase が storage.protect_delete() トリガーで SQL 直削除をプラットフォーム禁止に
// しており (ERROR 42501 "Use the Storage API instead")、必ず失敗していた
// (M8 実弾テストで発覚)。Storage API + Auth Admin API を使う正規構成に移行する。
//
// 流れ:
//   1. 呼び出しユーザーの JWT を検証して本人 uid を特定 (他人は消せない)
//   2. Storage API (service_role) で avatars / post-images の本人フォルダを全削除
//      — 公開バケットのため、消し忘れると削除後も画像が公開URLで残る (M32)
//   3. Auth Admin API で auth.users を削除
//      → public.users は FK CASCADE (001 SQL) で消え、投稿/コメント/いいね/通報/
//        申し立て/通知/セッション等の全データが連鎖削除される
//
// デプロイ: `supabase functions deploy delete-account`
//   (verify_jwt は既定の有効のまま = プラットフォームが JWT を一次検証する。
//    moderate-post のような --no-verify-jwt は付けないこと)
// クライアント: AccountDeletionService が functions.invoke("delete-account") で呼ぶ
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const USER_BUCKETS = ["avatars", "post-images"];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  // 1. 本人特定 (Authorization ヘッダの JWT を anon クライアントで検証)
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    console.error("認証失敗:", userError?.message);
    return new Response("unauthorized", { status: 401 });
  }
  const uid = userData.user.id;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // 2. Storage: 本人フォルダ ({uid}/...) を Storage API で全削除。
  //    auth 削除より先にやる (逆順だと storage 失敗時に孤児ファイルが公開URLで残る)。
  //    パス規約はフラット ("{uid}/{file}.jpg"、UserPostService/ProfileEditView 参照)
  for (const bucket of USER_BUCKETS) {
    const { data: files, error: listError } = await admin.storage
      .from(bucket)
      .list(uid, { limit: 1000 });
    if (listError) {
      console.error(`storage list 失敗 (${bucket}):`, listError.message);
      return new Response("storage list failed", { status: 500 });
    }
    if (files && files.length > 0) {
      const paths = files.map((f) => `${uid}/${f.name}`);
      const { error: removeError } = await admin.storage.from(bucket).remove(paths);
      if (removeError) {
        console.error(`storage remove 失敗 (${bucket}):`, removeError.message);
        return new Response("storage remove failed", { status: 500 });
      }
      console.log(`🗑 ${bucket}: ${paths.length} files removed for ${uid}`);
    }
  }

  // 3. auth.users 削除 → public.users 以下すべて CASCADE
  const { error: deleteError } = await admin.auth.admin.deleteUser(uid);
  if (deleteError) {
    console.error("auth deleteUser 失敗:", deleteError.message);
    return new Response("auth delete failed", { status: 500 });
  }

  console.log(`✅ account deleted: ${uid}`);
  return new Response("ok", { status: 200 });
});
