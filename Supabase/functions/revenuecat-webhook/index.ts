// ============================================================
// revenuecat-webhook / index.ts
// RevenueCat Webhook → users.is_pro 同期 Edge Function (Deno)
// ============================================================
// 設計: Fable 5 (2026-07-16 統合設計メモ → 2026-07-18 実装)
// 2026-08-01: TRANSFER 分岐の監査ブロッカー対応。L23 で「誤剥奪の方が to 付与漏れより
//   重大」としていた判断が、実際には entitlement を一切確認せず is_pro=true を書く穴
//   だったため修正 (詳細は下記 TRANSFER の項と本文コメント参照)
//
// 役割:
//   RevenueCat の Webhook イベントを受けて public.users.is_pro を更新する。
//   is_pro は 015/016 の protect trigger でクライアント直 UPDATE 禁止のため、
//   ここ (service_role = rolbypassrls) が唯一の書き込み経路。
//
// 前提:
//   - クライアントは Purchases.logIn(<Supabase user UUID>) を呼ぶため、
//     app_user_id = users.id (UUID) になる。匿名ID ($RCAnonymousID:...) は
//     ログイン前のイベントなので何もしない (ログイン時に TRANSFER が来る)
//   - entitlement は "pro" 1本 (monthly / yearly / lifetime 全てが付与する)
//
// イベント → is_pro の対応:
//   true  : INITIAL_PURCHASE / RENEWAL / UNCANCELLATION / NON_RENEWING_PURCHASE
//           (買い切り) / PRODUCT_CHANGE (ただし entitlement_ids に PRO_ENTITLEMENT を
//           含む場合のみ付与。L22 監査対応)
//   false : EXPIRATION (アクセス権が実際に切れた時のみ)
//   無視  : CANCELLATION (自動更新オフにしただけ。期限まで pro 継続)、
//           BILLING_ISSUE (猶予期間中は pro 継続。切れれば EXPIRATION が来る)、TEST
//   TRANSFER: transferred_to / transferred_from の両方が対象。TRANSFER の payload には
//             entitlement_ids も expiration も含まれないため
//             (出典: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields)、
//             RevenueCat REST API (GET /v1/subscribers/{id}, 出典:
//             https://www.revenuecat.com/docs/api-v1) で実際の entitlement 状態を
//             都度確認してから is_pro を true/false に反映する。判定不能なら is_pro を
//             書かずに 500 でリトライさせる (fail-closed)。詳細は TRANSFER 分岐本文の
//             コメント参照
//
// イベント順序保証 (L24 監査対応):
//   webhook の到着順序は保証されない。event_timestamp_ms を rc_last_event_ms
//   (040 migration) と突き合わせ、古いイベントによる is_pro の巻き戻りを防ぐ
//
// エラー処理:
//   認証失敗のみ 401 (RevenueCat 側でリトライされる)。それ以外の内部エラーは
//   ログを残して 200 (moderate-post と同じ「リトライの嵐を起こさない」方針。
//   ただし DB 更新失敗と TRANSFER の entitlement 判定不能 (API未設定/取得失敗) は
//   500 を返してリトライに乗せる — 前者は is_pro の同期漏れ、後者は誤った is_pro の
//   反映のリスクが、それぞれ「リトライの嵐」より重大なため)
//
// 環境変数:
//   REVENUECAT_WEBHOOK_AUTH   - `supabase secrets set` で設定 (ユーザー作業)。
//                               RevenueCat Dashboard → Integrations → Webhooks の
//                               Authorization header value と同じ文字列にする
//   REVENUECAT_SECRET_API_KEY - (optional) TRANSFER イベントで entitlement の実状態を
//                               RevenueCat REST API から確認するために使う。
//                               RevenueCat Dashboard → Project Settings → API keys の
//                               secret key を
//                               `supabase secrets set REVENUECAT_SECRET_API_KEY=...`
//                               で設定する (ユーザー作業)。未設定の間は TRANSFER
//                               イベントを 500 で保留し続ける (fail-closed。上記
//                               TRANSFER の項と本文コメント参照)
//   RC_ALLOW_SANDBOX          - "true" の時のみ SANDBOX イベントも処理する
//                               (課金導線のサンドボックス検証用。テスト後は必ず unset。
//                               未設定/それ以外の値なら非本番イベントは全て無視)
//   SUPABASE_URL              - ランタイム自動注入
//   SUPABASE_SERVICE_ROLE_KEY - ランタイム自動注入
//
// デプロイ: `supabase functions deploy revenuecat-webhook --no-verify-jwt`
//   (--no-verify-jwt 必須: RevenueCat は Supabase の JWT を持たないため)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTH")!;
// H12: SANDBOX/TestFlight の無料購入が本番 is_pro=true を立てる課金バイパス防止。
// サンドボックス検証時のみ `supabase secrets set RC_ALLOW_SANDBOX=true` で一時的に通す
const ALLOW_SANDBOX = Deno.env.get("RC_ALLOW_SANDBOX") === "true";
// 2026-08-01: TRANSFER の entitlement 実状態確認用 (optional)。WEBHOOK_AUTH と違い `!`
// を付けない — 未設定でも起動時に落とさず、TRANSFER 処理側で fail-closed (500 で
// リトライさせる) にするため、ここでは "" にフォールバックするだけに留める
const REVENUECAT_SECRET_API_KEY = Deno.env.get("REVENUECAT_SECRET_API_KEY") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// RevenueCat ダッシュボードの実識別子 (作成後変更不可)。RevenueCatConfig.swift と一致させること
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
  event_timestamp_ms?: number; // イベント発生時刻 (ms epoch)。順序保証用 (L24 監査対応)
  environment?: string; // "PRODUCTION" | "SANDBOX" (RevenueCat が全イベントに付与)
  app_user_id?: string;
  entitlement_ids?: string[] | null;
  transferred_to?: string[] | null;
  transferred_from?: string[] | null;
}

// RevenueCat REST API `GET /v1/subscribers/{app_user_id}` のレスポンス形。
// 出典: https://www.revenuecat.com/docs/api-v1
// (買い切り/lifetime では expires_date が null になる)
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
  // L24: is_pro の更新は set_is_pro_guarded RPC (040 migration) 経由に一本化。
  // event_timestamp_ms が rc_last_event_ms より古い場合は DB 側で更新をスキップする
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
  return true; // 古いイベントによるスキップは「正しく無視できた」ので成功(200)として扱う。errorの時だけfalse
}

// 2026-08-01: TRANSFER イベント対応。payload に entitlement_ids も expiration も
// 含まれないため
// (出典: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields)、
// RevenueCat REST API (出典: https://www.revenuecat.com/docs/api-v1) から現在の
// PRO_ENTITLEMENT ("1% Pro") entitlement の実状態を都度取得する。
// 戻り値: true=有効 / false=無効 / null=判定不能（ネットワーク・認証・パースの失敗）
async function fetchProStateFromRevenueCat(appUserId: string): Promise<boolean | null> {
  let res: Response;
  try {
    res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      {
        headers: { Authorization: `Bearer ${REVENUECAT_SECRET_API_KEY}` },
        // RevenueCat は webhook レスポンスを60秒でタイムアウト扱いにする
        // (出典: https://www.revenuecat.com/docs/integrations/webhooks)。
        // それより十分短い期限で自ら諦めて null (判定不能) を返す
        signal: AbortSignal.timeout(10_000),
      },
    );
  } catch (e) {
    // API キーそのものはログに出さない。ネットワークエラー/タイムアウトのみ記録
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
    // 買い切り (lifetime) は expires_date が null → 無期限で有効
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

// L25: webhook 認証の定数時間比較 (タイミング攻撃対策)
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
  // RevenueCat Dashboard で設定した Authorization header と突き合わせる (定数時間比較)。
  // WEBHOOK_AUTH が空文字列 (未設定/設定ミス) の場合は無条件に fail-closed する —
  // でないと timingSafeEqual("", "") が true になり誤って認証成功してしまう
  const gotAuth = req.headers.get("Authorization");
  if (WEBHOOK_AUTH.length === 0 || !timingSafeEqual(gotAuth ?? "", WEBHOOK_AUTH)) {
    // 値そのものはログに残さない (秘密)。長さと Bearer 前置の有無だけで原因を切り分ける
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
    return new Response("ok", { status: 200 }); // 壊れた payload はリトライしても直らない
  }

  // H12: 非本番イベントは本番 DB に反映しない。environment が欠けている場合も
  // 安全側 (無視) に倒す。RC_ALLOW_SANDBOX=true の時だけ検証用に通す
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
    // TRANSFER: 匿名ID→ログインID等の付け替え、または別 Apple ID への引き継ぎ。
    // payload には transferred_from/transferred_to の UUID 一覧しか入っておらず、
    // entitlement_ids も expiration も含まれない
    // (出典: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields)。
    // そのため to/from 双方について RevenueCat REST API で実際の entitlement 状態を
    // 確認してから is_pro を反映する (fetchProStateFromRevenueCat 参照)。
    //
    // 旧実装は transferred_to に無条件で is_pro=true を書き、
    // 「transferred_from は誤剥奪が怖いので EXPIRATION に一任する」としていた (L23)。
    // だが RevenueCat 公式ドキュメントいわく "The webhook is sent only for the
    // destination user" — EXPIRATION は移転先 (to 側の app_user_id) にしか届かず、
    // 転出元 (from) 目線では永久に来ないため、その一任は最初から成立していなかった
    // (出典は上記 URL)。今回 API で実状態を都度確認するようになったので、
    // from 側も安全に剥奪できるようになった。
    if (event.type === "TRANSFER") {
      if (REVENUECAT_SECRET_API_KEY.length === 0) {
        // fail-closed: シークレット未設定のまま憶測で is_pro を書き換えるくらいなら
        // 何もせず 500 を返してリトライさせる方が安全。RevenueCat は最大 5 回
        // (5/10/20/40/80分の増加ディレイ、合計約2.5時間) リトライするので
        // (出典: https://www.revenuecat.com/docs/integrations/webhooks)、
        // その間に `supabase secrets set REVENUECAT_SECRET_API_KEY=...` を設定すれば
        // 次のリトライで自動的に正しく処理される
        console.error("❌ REVENUECAT_SECRET_API_KEY が未設定のため TRANSFER を保留した");
        return new Response("ok", { status: 500 });
      }

      // 同じ UUID が to/from 両方に現れても二重処理しないよう Set で重複排除
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
          // 判定不能: 憶測で is_pro を書かず、500 でリトライに回す (fail-closed)
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
      // 匿名ID ($RCAnonymousID:...) など。ログイン後の TRANSFER で拾う
      console.log(`↩️ skip non-uuid app_user_id (${event.type})`);
      return new Response("ok", { status: 200 });
    }

    const ents = event.entitlement_ids;

    if (GRANT_EVENTS.has(event.type)) {
      // L22: ents が配列で PRO_ENTITLEMENT を含む場合のみ付与する
      // (以前は ents が NULL/空の GRANT イベントでも無条件に true にしていた)
      if (!Array.isArray(ents) || !ents.includes(PRO_ENTITLEMENT)) {
        console.log(`↩️ skip GRANT without ${PRO_ENTITLEMENT} entitlement (type=${event.type}, ents=${JSON.stringify(ents)})`);
        return new Response("ok", { status: 200 });
      }
      const ok = await setIsPro(userId, true, event.event_timestamp_ms);
      return new Response("ok", { status: ok ? 200 : 500 });
    }
    if (REVOKE_EVENTS.has(event.type)) {
      // EXPIRATION も pro 以外の entitlement の失効では剥奪しない (将来 entitlement を
      // 追加した時の誤剥奪防止)。ents が欠落/空の場合は安全側 = 剥奪を実行する
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
