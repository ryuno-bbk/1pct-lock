// ============================================================
// delete-account / index.ts
// Edge Function for full account deletion (2026-07-25)
// ============================================================
// Background: the delete_my_account RPC in 038 deleted storage.objects directly, but
// Supabase forbids direct SQL deletion at the platform level with the storage.protect_delete()
// trigger (ERROR 42501 "Use the Storage API instead"), so it always failed
// (found in the M8 live test). Moving to the proper setup using the Storage API + Auth Admin API.
//
// Flow:
//   1. Verify the calling user's JWT and identify their uid (cannot delete others)
//   2. Delete all of the user's folders in avatars / post-images with the Storage API (service_role).
//      These are public buckets, so anything missed stays reachable by public URL after deletion (M32)
//   3. Delete auth.users with the Auth Admin API
//      → public.users is deleted by FK CASCADE (001 SQL), and all data (posts/comments/likes/
//        reports/appeals/notifications/sessions etc.) is deleted in cascade
//
// Deploy: `supabase functions deploy delete-account`
//   (verify_jwt stays at the default, enabled = the platform does the first JWT check.
//    Do not add --no-verify-jwt like moderate-post)
// Client: AccountDeletionService calls it with functions.invoke("delete-account")
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

  // 1. Identify the user (verify the JWT in the Authorization header with an anon client)
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

  // 2. Storage: delete all of the user's folders ({uid}/...) with the Storage API.
  //    Do this before deleting auth (in reverse order, if storage fails, orphan files stay at public
  //    URLs). The path convention is flat ("{uid}/{file}.jpg", see UserPostService/ProfileEditView)
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

  // 3. Delete auth.users → everything under public.users is deleted by CASCADE
  const { error: deleteError } = await admin.auth.admin.deleteUser(uid);
  if (deleteError) {
    console.error("auth deleteUser 失敗:", deleteError.message);
    return new Response("auth delete failed", { status: 500 });
  }

  console.log(`✅ account deleted: ${uid}`);
  return new Response("ok", { status: 200 });
});
