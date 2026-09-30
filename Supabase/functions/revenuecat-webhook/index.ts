// ============================================================
// revenuecat-webhook / index.ts
// RevenueCat Webhook → Edge Function (Deno) that syncs users.is_pro
// ============================================================
// Design: Fable 5 (2026-07-16 integrated design memo → 2026-07-18 implementation)
// 2026-08-01: fix for the audit blocker in the TRANSFER branch. The judgment in L23 that "a wrong
//   revoke is worse than missing a grant to `to`" was in fact a hole that wrote is_pro=true without
//   checking the entitlement at all, so it was fixed (details in the TRANSFER item below and in the
//   comments in the body)
//
// Role:
//   Receives RevenueCat Webhook events and updates public.users.is_pro.
//   is_pro cannot be UPDATEd directly by clients because of the protect trigger in 015/016,
//   so this (service_role = rolbypassrls) is the only write path.
//
// Assumptions:
//   - The client calls Purchases.logIn(<Supabase user UUID>), so
//     app_user_id = users.id (UUID). Anonymous IDs ($RCAnonymousID:...) are events from
//     before login, so nothing is done (a TRANSFER arrives on login)
//   - There is one entitlement, "pro" (monthly / yearly / lifetime all grant it)
//
// Mapping of event → is_pro:
//   true  : INITIAL_PURCHASE / RENEWAL / UNCANCELLATION / NON_RENEWING_PURCHASE
//           (one-time purchase) / PRODUCT_CHANGE (granted only if entitlement_ids contains
//           PRO_ENTITLEMENT. L22 audit fix)
//   false : EXPIRATION (only when access has actually ended)
//   ignore: CANCELLATION (only turned off auto-renew. Stays pro until the end of the period),
//           BILLING_ISSUE (stays pro during the grace period. If it lapses, EXPIRATION arrives), TEST
//   TRANSFER: both transferred_to and transferred_from are handled. The TRANSFER payload contains
//             neither entitlement_ids nor expiration
//             (source: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields),
//             so the actual entitlement state is checked each time with the RevenueCat REST API
//             (GET /v1/subscribers/{id}, source:
//             https://www.revenuecat.com/docs/api-v1) before writing is_pro as true/false. If it
//             cannot be determined, is_pro is not written and 500 is returned so it is retried
//             (fail-closed). See the comments in the TRANSFER branch body for details
//
// Event order guarantee (L24 audit fix):
//   The arrival order of webhooks is not guaranteed. event_timestamp_ms is compared with
//   rc_last_event_ms (040 migration) to prevent is_pro from being rolled back by an old event
//
// Error handling:
//   Only authentication failures return 401 (RevenueCat retries them). Other internal errors are
//   logged and return 200 (same policy as moderate-post: "do not cause a retry storm".
//   However, a DB update failure and an undeterminable TRANSFER entitlement (API not configured / fetch
//   failed) return 500 so they are retried. The risk of the former (is_pro not synced) and the latter
//   (a wrong is_pro written) is each worse than a "retry storm")
//
// Environment variables:
//   REVENUECAT_WEBHOOK_AUTH   - set with `supabase secrets set` (user task).
//                               Must be the same string as the Authorization header value in
//                               RevenueCat Dashboard → Integrations → Webhooks
//   REVENUECAT_SECRET_API_KEY - (optional) used for TRANSFER events to check the actual
//                               entitlement state via the RevenueCat REST API.
//                               Set the secret key from RevenueCat Dashboard → Project
//                               Settings → API keys with
//                               `supabase secrets set REVENUECAT_SECRET_API_KEY=...`
//                               (user task). While it is not set, TRANSFER events keep being
//                               held with 500 (fail-closed. See the TRANSFER item above and
//                               the comments in the body)
//   RC_ALLOW_SANDBOX          - SANDBOX events are processed only when this is "true"
//                               (for sandbox testing of the purchase flow. Always unset it after
//                               testing. If unset or any other value, all non-production events
//                               are ignored)
//   SUPABASE_URL              - injected automatically by the runtime
//   SUPABASE_SERVICE_ROLE_KEY - injected automatically by the runtime
//
// Deploy: `supabase functions deploy revenuecat-webhook --no-verify-jwt`
//   (--no-verify-jwt is required: RevenueCat does not have a Supabase JWT)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTH")!;
// H12: prevents a purchase bypass where free SANDBOX/TestFlight purchases set is_pro=true in production.
// Only during sandbox testing, let them through temporarily with
// `supabase secrets set RC_ALLOW_SANDBOX=true`
const ALLOW_SANDBOX = Deno.env.get("RC_ALLOW_SANDBOX") === "true";
// 2026-08-01: for checking the actual TRANSFER entitlement state (optional). Unlike WEBHOOK_AUTH, no `!`
// is added. Even if unset, it should not crash at startup; the TRANSFER handling is fail-closed (returns
// 500 to trigger a retry), so here it only falls back to ""
const REVENUECAT_SECRET_API_KEY = Deno.env.get("REVENUECAT_SECRET_API_KEY") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// The real identifier in the RevenueCat dashboard (cannot be changed after creation). Must match
// RevenueCatConfig.swift
const PRO_ENTITLEMENT = "1% Pro";

const GRANT_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "PRODUCT_CHANGE",
]);

const REVOKE_EVENTS = new Set(["EXPIRATION"]);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RCEvent {
  type: string;
  event_timestamp_ms?: number; // Time the event occurred (ms epoch). Used for ordering (L24 audit fix)
  environment?: string; // "PRODUCTION" | "SANDBOX" (RevenueCat attaches it to every event)
  app_user_id?: string;
  entitlement_ids?: string[] | null;
  transferred_to?: string[] | null;
  transferred_from?: string[] | null;
}

// Response shape of the RevenueCat REST API `GET /v1/subscribers/{app_user_id}`.
// Source: https://www.revenuecat.com/docs/api-v1
// (for one-time purchase/lifetime, expires_date is null)
interface RCEntitlement {
  expires_date?: string | null;
  grace_period_expires_date?: string | null;
  product_identifier?: string;
  purchase_date?: string;
}

interface RCSubscriberResponse {
  subscriber?: {
    entitlements?: Record<string, RCEntitlement>;
  };
}

async function setIsPro(userId: string, isPro: boolean, eventTimestampMs?: number): Promise<boolean> {
  // L24: all is_pro updates go through the set_is_pro_guarded RPC (040 migration).
  // If event_timestamp_ms is older than rc_last_event_ms, the DB side skips the update
  const { data, error } = await supabase.rpc("set_is_pro_guarded", {
    p_user_id: userId,
    p_is_pro: isPro,
    p_event_ms: eventTimestampMs ?? null,
  });
  if (error) {
    console.error(`❌ is_pro update failed (${userId} → ${isPro}):`, error);
    return false;
  }
  if (data === false) {
    console.log(`↩️ is_pro update skipped (stale event, ${userId} → ${isPro}, event_ms=${eventTimestampMs})`);
  } else {
    console.log(`✅ is_pro = ${isPro} (${userId})`);
  }
  return true; // A skip due to an old event was "correctly ignored", so it counts as success (200). false only on error
}

// 2026-08-01: TRANSFER event support. The payload contains neither entitlement_ids nor expiration
// (source: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields),
// so the actual state of the PRO_ENTITLEMENT ("1% Pro") entitlement is fetched each time from the
// RevenueCat REST API (source: https://www.revenuecat.com/docs/api-v1).
// Return value: true=active / false=inactive / null=cannot determine (network, auth or parse failure)
async function fetchProStateFromRevenueCat(appUserId: string): Promise<boolean | null> {
  let res: Response;
  try {
    res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      {
        headers: { Authorization: `Bearer ${REVENUECAT_SECRET_API_KEY}` },
        // RevenueCat treats a webhook response as timed out after 60 seconds
        // (source: https://www.revenuecat.com/docs/integrations/webhooks).
        // Give up on our own with a much shorter deadline and return null (cannot determine)
        signal: AbortSignal.timeout(10_000),
      },
    );
  } catch (e) {
    // Never log the API key itself. Only record network errors/timeouts
    console.error(`❌ RevenueCat API fetch failed (${appUserId}):`, e);
    return null;
  }

  if (!res.ok) {
    const bodyText = await res.text().catch(() => "");
    console.error(
      `❌ RevenueCat API returned ${res.status} (${appUserId}): ${bodyText.slice(0, 300)}`,
    );
    return null;
  }

  let json: RCSubscriberResponse;
  try {
    json = await res.json();
  } catch (e) {
    console.error(`❌ RevenueCat API response parse failed (${appUserId}):`, e);
    return null;
  }

  const ent = json?.subscriber?.entitlements?.[PRO_ENTITLEMENT];
  if (!ent) {
    return false;
  }

  const expiresDateRaw = ent.expires_date;
  if (expiresDateRaw === null || expiresDateRaw === undefined) {
    // One-time purchase (lifetime) has expires_date null → active with no end date
    return true;
  }

  const expiresMs = Date.parse(expiresDateRaw);
  if (Number.isNaN(expiresMs)) {
    console.error(`❌ RevenueCat API unparsable expires_date (${appUserId}): ${expiresDateRaw}`);
    return null;
  }

  let effectiveExpiresMs = expiresMs;
  const graceRaw = ent.grace_period_expires_date;
  if (graceRaw !== null && graceRaw !== undefined) {
    const graceMs = Date.parse(graceRaw);
    if (Number.isNaN(graceMs)) {
      console.error(`❌ RevenueCat API unparsable grace_period_expires_date (${appUserId}): ${graceRaw}`);
      return null;
    }
    effectiveExpiresMs = Math.max(effectiveExpiresMs, graceMs);
  }

  return effectiveExpiresMs > Date.now();
}

// L25: constant-time comparison for webhook authentication (protects against timing attacks)
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }
  // Compare with the Authorization header set in the RevenueCat Dashboard (constant-time comparison).
  // If WEBHOOK_AUTH is an empty string (not set / misconfigured), fail closed unconditionally.
  // Otherwise timingSafeEqual("", "") would be true and authentication would wrongly succeed
  const gotAuth = req.headers.get("Authorization");
  if (WEBHOOK_AUTH.length === 0 || !timingSafeEqual(gotAuth ?? "", WEBHOOK_AUTH)) {
    // Do not log the value itself (secret). Narrow down the cause using only the length and whether it has
    // a Bearer prefix
    console.error(
      `❌ auth mismatch: got len=${gotAuth?.length ?? 0} expected len=${WEBHOOK_AUTH.length} bearerPrefix=${gotAuth?.startsWith("Bearer ") ?? false}`,
    );
    return new Response("unauthorized", { status: 401 });
  }

  let event: RCEvent;
  try {
    const body = await req.json();
    event = body?.event ?? {};
  } catch (e) {
    console.error("❌ payload parse failed:", e);
    return new Response("ok", { status: 200 }); // A broken payload will not be fixed by retrying
  }

  // H12: do not apply non-production events to the production DB. If environment is missing, also fall
  // to the safe side (ignore). Let them through for testing only when RC_ALLOW_SANDBOX=true
  if (event.environment !== "PRODUCTION") {
    if (!ALLOW_SANDBOX) {
      console.log(
        `↩️ skip non-production event (env=${event.environment ?? "unknown"}, type=${event.type})`,
      );
      return new Response("ok", { status: 200 });
    }
    console.warn(
      `⚠️ RC_ALLOW_SANDBOX=true — processing non-production event (env=${event.environment}, type=${event.type})`,
    );
  }

  try {
    // TRANSFER: reassignment such as anonymous ID → login ID, or a handover to another Apple ID.
    // The payload only contains the UUID lists transferred_from/transferred_to, and contains neither
    // entitlement_ids nor expiration
    // (source: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields).
    // So for both to and from, the actual entitlement state is checked with the RevenueCat REST API before
    // writing is_pro (see fetchProStateFromRevenueCat).
    //
    // The old implementation wrote is_pro=true to transferred_to unconditionally, and said
    // "leave transferred_from to EXPIRATION because a wrong revoke is scary" (L23).
    // But the official RevenueCat docs say "The webhook is sent only for the
    // destination user": EXPIRATION only reaches the destination (the `to` app_user_id), and from the
    // point of view of the source (from) it never arrives, so that delegation never worked from the start
    // (source: the URL above). Now that the real state is checked through the API each time,
    // the `from` side can also be revoked safely.
    if (event.type === "TRANSFER") {
      if (REVENUECAT_SECRET_API_KEY.length === 0) {
        // fail-closed: rather than rewriting is_pro based on a guess while the secret is not set,
        // it is safer to do nothing and return 500 so it is retried. RevenueCat retries up to 5 times
        // (increasing delays of 5/10/20/40/80 minutes, about 2.5 hours in total)
        // (source: https://www.revenuecat.com/docs/integrations/webhooks),
        // so if `supabase secrets set REVENUECAT_SECRET_API_KEY=...` is set during that time,
        // the next retry processes it correctly automatically
        console.error("❌ REVENUECAT_SECRET_API_KEY が未設定のため TRANSFER を保留した");
        return new Response("ok", { status: 500 });
      }

      // Deduplicate with a Set so the same UUID is not processed twice even if it appears in both to/from
      const targetIds = new Set<string>();
      for (const id of event.transferred_to ?? []) {
        if (UUID_RE.test(id)) targetIds.add(id);
      }
      for (const id of event.transferred_from ?? []) {
        if (UUID_RE.test(id)) targetIds.add(id);
      }

      let allOk = true;
      for (const id of targetIds) {
        const state = await fetchProStateFromRevenueCat(id);
        if (state === null) {
          // Cannot determine: do not write is_pro based on a guess, return 500 to trigger a retry (fail-closed)
          console.error(`❌ RevenueCat entitlement 判定不能のため is_pro を書かなかった (${id})`);
          allOk = false;
          continue;
        }
        allOk = (await setIsPro(id, state, event.event_timestamp_ms)) && allOk;
      }
      return new Response("ok", { status: allOk ? 200 : 500 });
    }

    const userId = event.app_user_id ?? "";
    if (!UUID_RE.test(userId)) {
      // Anonymous IDs ($RCAnonymousID:...) etc. Picked up by the TRANSFER after login
      console.log(`↩️ skip non-uuid app_user_id (${event.type})`);
      return new Response("ok", { status: 200 });
    }

    const ents = event.entitlement_ids;

    if (GRANT_EVENTS.has(event.type)) {
      // L22: grant only if ents is an array that contains PRO_ENTITLEMENT
      // (before, even GRANT events with NULL/empty ents unconditionally set true)
      if (!Array.isArray(ents) || !ents.includes(PRO_ENTITLEMENT)) {
        console.log(`↩️ skip GRANT without ${PRO_ENTITLEMENT} entitlement (type=${event.type}, ents=${JSON.stringify(ents)})`);
        return new Response("ok", { status: 200 });
      }
      const ok = await setIsPro(userId, true, event.event_timestamp_ms);
      return new Response("ok", { status: ok ? 200 : 500 });
    }
    if (REVOKE_EVENTS.has(event.type)) {
      // EXPIRATION also does not revoke when an entitlement other than pro expires (prevents a wrong revoke
      // if entitlements are added in the future). If ents is missing/empty, take the safe side = revoke
      if (Array.isArray(ents) && ents.length > 0 && !ents.includes(PRO_ENTITLEMENT)) {
        console.log(`↩️ skip REVOKE without ${PRO_ENTITLEMENT} entitlement (type=${event.type}, ents=${JSON.stringify(ents)})`);
        return new Response("ok", { status: 200 });
      }
      const ok = await setIsPro(userId, false, event.event_timestamp_ms);
      return new Response("ok", { status: ok ? 200 : 500 });
    }

    console.log(`↩️ ignored event type: ${event.type}`);
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error("❌ handler error:", e);
    return new Response("ok", { status: 200 });
  }
});
