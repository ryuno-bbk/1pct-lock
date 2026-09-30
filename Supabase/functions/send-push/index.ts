// ============================================================
// send-push / index.ts
// Edge Function (Deno) that turns INSERTs into user_notifications into APNs push notifications
// ============================================================
// Background:
//   user_notifications was working but had no delivery channel,
//   so most notifications died unread. Not a new feature but "wiring that had been cut".
//
// Role:
//   Receives the Supabase Database Webhook (INSERT into public.user_notifications),
//   looks up the recipient's device tokens (078: user_push_tokens) and sends to APNs one by one.
//
// 🔴 The existing 102 unread notifications are not sent:
//   The webhook only reacts to INSERT events, so past rows are out of scope.
//   An accident where 102 notifications go out at once the moment it is enabled cannot happen by
//   design.
//
// 🔴 Sandbox / production APNs:
//   Development builds = sandbox, TestFlight / App Store = production. The hosts are different, so
//   the host is chosen by the environment the device declared at registration (the environment
//   column in 078). Getting this wrong hits "delivered in development but silent in production".
//   As insurance, if one host returns BadDeviceToken, resend once to the other host, and
//   correct environment to the side that succeeded (self-healing when a device moves between
//   Debug/Release).
//
// Language:
//   Like 075/076, the body text switches by users.lang ('ja' / 'en').
//   ⚠️ Wording awaiting user review (Claude does not invent the brand voice).
//
// Badge:
//   Count the recipient's unread notifications every time and put the number in aps.badge. The
//   number shows on the icon even without opening the app, which removes the very state where 102
//   of them die unseen.
//
// Error handling:
//   Only a secret mismatch returns 401. Everything else always returns 200, the same policy as
//   moderate-post (failing the webhook with 4xx/5xx makes Supabase fire a storm of retries).
//   Push is best-effort by nature, so if one notification fails, swallow it and log it.
//
// Environment variables (set with `supabase secrets set` = user task):
//   APNS_KEY_ID       - Key ID (10 chars) of the APNs key created in Apple Developer → Keys
//   APNS_TEAM_ID      - Apple Developer Team ID (10 chars)
//   APNS_PRIVATE_KEY  - contents of that key's .p8 (all of it, including -----BEGIN PRIVATE KEY-----)
//   APNS_BUNDLE_ID    - com.jeimii.AppBlocker
//   PUSH_WEBHOOK_SECRET - same string as the x-push-secret header of the Database Webhook.
//                         While unset, every request gets 401 (fail-closed)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY - auto-injected by the runtime
//
// Deploy: `supabase functions deploy send-push --no-verify-jwt`
//   ⚠️ --no-verify-jwt is required. If forgotten, every Database Webhook call fails and it silently
//      stops (the same accident already happened with moderate-post)
// Webhook registration: in Dashboard → Database → Webhooks, point the INSERT on
//   public.user_notifications to this Function's URL, and add to HTTP Headers
//   x-push-secret: <same value as PUSH_WEBHOOK_SECRET> (user task)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.jeimii.AppBlocker";
const PUSH_WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";

const APNS_HOST = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

type Environment = keyof typeof APNS_HOST;

// ============================================================
// APNs provider token (JWT / ES256)
// ============================================================
// An APNs token lasts at most 60 minutes. Recreating it too often in a short time gets rejected
// with TooManyProviderTokenUpdates, so it is cached in the instance and reused for only 50 minutes.
let cachedToken: { jwt: string; issuedAt: number } | null = null;
let cachedKey: CryptoKey | null = null;

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeString(text: string): string {
  return base64UrlEncode(new TextEncoder().encode(text));
}

/// Turn the .p8 (PKCS#8 PEM) into a WebCrypto key.
/// Via `supabase secrets set`, newlines can arrive as the 2 characters \n, so convert them back to
/// real newlines.
async function importPrivateKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;

  const pem = APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);

  cachedKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return cachedKey;
}

async function apnsProviderToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 50 * 60) return cachedToken.jwt;

  const key = await importPrivateKey();
  const header = base64UrlEncodeString(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
  const claims = base64UrlEncodeString(JSON.stringify({ iss: APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${claims}`;

  // WebCrypto ECDSA signing returns raw r||s (64 bytes).
  // That is exactly the format JWS ES256 requires, so no conversion is needed (do not wrap it in DER)
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  const jwt = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
  cachedToken = { jwt, issuedAt: now };
  return jwt;
}

// ============================================================
// Wording (⚠️ awaiting user review)
// ============================================================
// Claude does not invent the brand voice, so this is a functional placeholder.
// actor = display name of the person who acted. If empty, fall back to "誰か" ("someone") (a
// display name may be unset)
function buildMessage(
  kind: string,
  lang: string,
  actor: string,
  preview: string | null,
): { title: string; body: string } | null {
  const ja = lang !== "en";
  const who = actor.trim().length > 0 ? actor.trim() : (ja ? "誰か" : "Someone");
  const snippet = (preview ?? "").trim();
  const withSnippet = (base: string) =>
    snippet.length > 0 ? `${base}: ${snippet.slice(0, 80)}` : base;

  switch (kind) {
    case "like":
      return { title: "1%", body: ja ? `${who}があなたの投稿にいいねしました` : `${who} liked your post` };
    case "comment_like":
      return { title: "1%", body: ja ? `${who}があなたのコメントにいいねしました` : `${who} liked your comment` };
    case "follow":
      return { title: "1%", body: ja ? `${who}があなたをフォローしました` : `${who} followed you` };
    case "comment":
      return {
        title: "1%",
        body: withSnippet(ja ? `${who}がコメントしました` : `${who} commented`),
      };
    case "reply":
      return {
        title: "1%",
        body: withSnippet(ja ? `${who}が返信しました` : `${who} replied`),
      };
    case "new_post":
      return { title: "1%", body: ja ? `${who}が新しく投稿しました` : `${who} shared a new post` };

    // For moderation types, the actor is the operator. Do not show a name
    case "content_rejected":
      return { title: "1%", body: ja ? "投稿が公開できませんでした" : "Your post couldn't be published" };
    case "content_flagged":
      return { title: "1%", body: ja ? "投稿が確認中です" : "Your post is under review" };
    case "appeal_approved":
      return { title: "1%", body: ja ? "異議申し立てが認められました" : "Your appeal was approved" };
    case "appeal_rejected":
      return { title: "1%", body: ja ? "異議申し立ての結果が出ました" : "Your appeal was reviewed" };

    // Weekly report (081). preview_text holds that week's lock seconds.
    // The body is built here (not fixed on the SQL side, so it can switch between Japanese and English
    // by users.lang)
    // ⚠️ Wording awaiting user review
    case "weekly_report": {
      const secs = Math.max(0, Number(preview ?? "0") || 0);
      const h = Math.floor(secs / 3600);
      const m = Math.floor((secs % 3600) / 60);
      const dur = ja
        ? (h > 0 ? `${h}時間${m}分` : `${m}分`)
        : (h > 0 ? `${h}h ${m}m` : `${m}m`);

      // 🔴 Also sent to people with 0 seconds (user decision 2026-09-05). However,
      //    saying only "it was 0 minutes" would become a regular "you failed" message, so the text is
      //    different
      if (secs === 0) {
        return {
          title: "1%",
          body: ja
            ? "先週のレポートができました"
            : "Your weekly report is ready",
        };
      }
      return {
        title: "1%",
        body: ja
          ? `先週のレポートができました。ロックした時間は${dur}`
          : `Your weekly report is ready. You locked ${dur}`,
      };
    }

    // Internal notification for the operator. Not sent to users
    case "appeal_unsure":
      return null;

    default:
      // Do not silently drop kinds added in the future (log them)
      console.warn(`send-push: unknown kind ${kind}`);
      return null;
  }
}

// ============================================================
// APNs send
// ============================================================
interface SendResult {
  status: number;
  reason: string | null;
}

async function sendToApns(
  token: string,
  environment: Environment,
  payload: unknown,
): Promise<SendResult> {
  const jwt = await apnsProviderToken();
  const res = await fetch(`${APNS_HOST[environment]}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (res.status === 200) return { status: 200, reason: null };

  let reason: string | null = null;
  try {
    const text = await res.text();
    reason = text.length > 0 ? (JSON.parse(text).reason ?? text) : null;
  } catch {
    reason = null;
  }
  return { status: res.status, reason };
}

// ============================================================
// Entry point
// ============================================================
Deno.serve(async (req) => {
  // Authorization: confirm with the secret that the call comes from the Database Webhook.
  // If unset, always 401 (fail-closed). Same policy as moderate-post
  if (PUSH_WEBHOOK_SECRET.length === 0) {
    console.error("send-push: PUSH_WEBHOOK_SECRET is not set");
    return new Response("unauthorized", { status: 401 });
  }
  if (req.headers.get("x-push-secret") !== PUSH_WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    const payload = await req.json();
    const record = payload?.record;
    if (!record?.recipient_user_id || !record?.kind) {
      console.warn("send-push: payload has no usable record");
      return new Response("ok", { status: 200 });
    }

    const recipientId: string = record.recipient_user_id;
    const actorId: string | null = record.actor_user_id ?? null;

    // Fetch the recipient's devices and language and the actor's name together
    const [tokensRes, recipientRes, actorRes, unreadRes] = await Promise.all([
      admin.from("user_push_tokens").select("token, environment").eq("user_id", recipientId),
      admin.from("users").select("lang").eq("id", recipientId).maybeSingle(),
      actorId
        ? admin.from("users").select("display_name, handle").eq("id", actorId).maybeSingle()
        : Promise.resolve({ data: null, error: null }),
      admin
        .from("user_notifications")
        .select("id", { count: "exact", head: true })
        .eq("recipient_user_id", recipientId)
        .is("read_at", null),
    ]);

    const tokens = tokensRes.data ?? [];
    if (tokens.length === 0) {
      // Someone who has not allowed push yet. This is a normal case, so finish quietly
      return new Response("ok", { status: 200 });
    }

    const lang = recipientRes.data?.lang ?? "ja";
    const actorName = actorRes.data?.display_name ?? actorRes.data?.handle ?? "";
    const badge = unreadRes.count ?? 0;

    const message = buildMessage(record.kind, lang, actorName, record.preview_text ?? null);
    if (!message) return new Response("ok", { status: 200 });

    const apsPayload = {
      aps: {
        alert: { title: message.title, body: message.body },
        sound: "default",
        badge,
      },
      // Passed so that a tap can jump to the notification list (used on the client side)
      notification_id: record.id ?? null,
      kind: record.kind,
    };

    for (const row of tokens) {
      const declared = (row.environment === "sandbox" ? "sandbox" : "production") as Environment;
      let result = await sendToApns(row.token, declared, apsPayload);

      // When a device moves between Debug/Release, the declared environment and the real one diverge.
      // Only on BadDeviceToken, try the other host once to self-heal
      if (result.status === 400 && result.reason === "BadDeviceToken") {
        const other: Environment = declared === "production" ? "sandbox" : "production";
        const retry = await sendToApns(row.token, other, apsPayload);
        if (retry.status === 200) {
          await admin
            .from("user_push_tokens")
            .update({ environment: other, updated_at: new Date().toISOString() })
            .eq("token", row.token);
          console.log(`send-push: corrected environment to ${other}`);
          continue;
        }
        result = retry;
      }

      if (result.status === 200) continue;

      // The device deleted the app / the token is invalid → clean it up.
      // If kept, every send would hit APNs and keep failing for nothing
      if (result.status === 410 || result.reason === "Unregistered" || result.reason === "BadDeviceToken") {
        await admin.from("user_push_tokens").delete().eq("token", row.token);
        console.log(`send-push: removed dead token (${result.reason ?? result.status})`);
        continue;
      }

      console.error(`send-push: APNs ${result.status} ${result.reason ?? ""}`);
    }

    return new Response("ok", { status: 200 });
  } catch (e) {
    // To avoid a retry storm, internal errors are always swallowed with 200
    console.error("send-push: unhandled error", e);
    return new Response("ok", { status: 200 });
  }
});
