// ============================================================
// send-push / index.ts
// user_notifications の INSERT を APNs のプッシュ通知に変換する Edge Function (Deno)
// ============================================================
// 背景:
//   user_notifications は動いているのに配信手段が無く、
//   通知の大半が未読のまま死んでいた。新機能ではなく「切れていた配線」。
//
// 役割:
//   Supabase Database Webhook (public.user_notifications の INSERT) を受け、
//   受信者の端末トークン (078: user_push_tokens) を引いて APNs へ1通ずつ送る。
//
// 🔴 既存の未読102件は飛ばない:
//   Webhook は INSERT イベントにしか反応しないため、過去行は対象外。
//   有効化した瞬間に102通が一斉送信される事故は構造的に起きない。
//
// 🔴 サンドボックス / 本番 APNs:
//   開発ビルド = サンドボックス、TestFlight・App Store = 本番。ホストが別物なので、
//   端末が登録時に申告した environment でホストを選ぶ (078 の environment 列)。
//   ここを誤ると「開発では届くが本番で無音」を踏む。
//   保険として、片方のホストが BadDeviceToken を返したらもう片方に1回だけ再送し、
//   成功した側に environment を訂正する (端末が Debug/Release を跨いだ場合の自己修復)。
//
// 言語:
//   075/076 と同じく users.lang ('ja' / 'en') で本文を出し分ける。
//   ⚠️ 文言はユーザー添削待ち (ブランドの声は Claude が発明しない)。
//
// バッジ:
//   受信者の未読件数を毎回数えて aps.badge に入れる。アプリを開かなくても
//   アイコンに数字が出るので、102件が見えないまま死ぬ状態そのものが解消する。
//
// エラー処理:
//   シークレット照合失敗のみ 401。それ以外は moderate-post と同じ方針で常に 200
//   (Webhook を 4xx/5xx で落とすと Supabase 側がリトライの嵐を起こすため)。
//   プッシュは本質的にベストエフォートなので、1通落ちても握りつぶしてログを残す。
//
// 環境変数 (`supabase secrets set` で設定 = ユーザー作業):
//   APNS_KEY_ID       - Apple Developer → Keys で作った APNs キーの Key ID (10文字)
//   APNS_TEAM_ID      - Apple Developer の Team ID (10文字)
//   APNS_PRIVATE_KEY  - 同キーの .p8 の中身 (-----BEGIN PRIVATE KEY----- ごと全部)
//   APNS_BUNDLE_ID    - com.jeimii.AppBlocker
//   PUSH_WEBHOOK_SECRET - Database Webhook の x-push-secret ヘッダと同じ文字列。
//                         未設定の間は全リクエスト 401 (fail-closed)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY - ランタイム自動注入
//
// デプロイ: `supabase functions deploy send-push --no-verify-jwt`
//   ⚠️ --no-verify-jwt 必須。忘れると Database Webhook が全滅して無音で止まる
//      (moderate-post で同じ事故を踏んでいる)
// Webhook 登録: Dashboard → Database → Webhooks で public.user_notifications の
//   INSERT をこの Function の URL に向け、HTTP Headers に
//   x-push-secret: <PUSH_WEBHOOK_SECRET と同じ値> を追加する (ユーザー作業)
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
// APNs プロバイダトークン (JWT / ES256)
// ============================================================
// APNs のトークンは最長60分。かつ短時間に作り直すと TooManyProviderTokenUpdates で
// 弾かれるため、インスタンス内でキャッシュして50分だけ使い回す。
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

/// .p8 (PKCS#8 PEM) を WebCrypto の鍵にする。
/// `supabase secrets set` 経由だと改行が \n という2文字で入ることがあるので実改行に戻す。
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

  // WebCrypto の ECDSA 署名は raw の r||s (64バイト) を返す。
  // JWS の ES256 が要求する形式そのものなので変換不要 (DER に包んではいけない)
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
// 文言 (⚠️ ユーザー添削待ち)
// ============================================================
// ブランドの声は Claude が発明しない方針のため、ここは機能的な仮置き。
// actor = 行動した人の表示名。空なら「誰か」に落とす (表示名は未設定があり得る)
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

    // モデレーション系は actor が運営。名前を出さない
    case "content_rejected":
      return { title: "1%", body: ja ? "投稿が公開できませんでした" : "Your post couldn't be published" };
    case "content_flagged":
      return { title: "1%", body: ja ? "投稿が確認中です" : "Your post is under review" };
    case "appeal_approved":
      return { title: "1%", body: ja ? "異議申し立てが認められました" : "Your appeal was approved" };
    case "appeal_rejected":
      return { title: "1%", body: ja ? "異議申し立ての結果が出ました" : "Your appeal was reviewed" };

    // 週次レポート (081)。preview_text にその週のロック秒数が入っている。
    // 本文はここで組む (users.lang で日英を出し分けるため SQL 側では確定させない)
    // ⚠️ 文言はユーザー添削待ち
    case "weekly_report": {
      const secs = Math.max(0, Number(preview ?? "0") || 0);
      const h = Math.floor(secs / 3600);
      const m = Math.floor((secs % 3600) / 60);
      const dur = ja
        ? (h > 0 ? `${h}時間${m}分` : `${m}分`)
        : (h > 0 ? `${h}h ${m}m` : `${m}m`);

      // 🔴 0秒の人にも送る (2026-09-05 ユーザー判断)。ただし
      //    「0分でした」とだけ言うと「あなたは失敗した」の定期送信になるため文面を分ける
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

    // 運営宛ての内部通知。ユーザーには送らない
    case "appeal_unsure":
      return null;

    default:
      // 将来 kind が増えたときに無音で落とさない (ログに出す)
      console.warn(`send-push: unknown kind ${kind}`);
      return null;
  }
}

// ============================================================
// APNs 送信
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
// エントリポイント
// ============================================================
Deno.serve(async (req) => {
  // 認可: Database Webhook からの呼び出しであることをシークレットで確認する。
  // 未設定なら常に 401 (fail-closed)。moderate-post と同じ方針
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

    // 受信者の端末と言語、行動した人の名前をまとめて引く
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
      // まだプッシュを許可していない人。正常系なので静かに終わる
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
      // タップ時に通知一覧へ飛ばすために渡す (クライアント側で使う)
      notification_id: record.id ?? null,
      kind: record.kind,
    };

    for (const row of tokens) {
      const declared = (row.environment === "sandbox" ? "sandbox" : "production") as Environment;
      let result = await sendToApns(row.token, declared, apsPayload);

      // 端末が Debug/Release を跨ぐと申告した environment と実体がズレる。
      // BadDeviceToken のときだけ、もう片方のホストに1回だけ賭けて自己修復する
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

      // 端末がアプリを消した / トークンが無効 → 掃除する。
      // 残しておくと毎回 APNs を叩いて無駄に失敗し続ける
      if (result.status === 410 || result.reason === "Unregistered" || result.reason === "BadDeviceToken") {
        await admin.from("user_push_tokens").delete().eq("token", row.token);
        console.log(`send-push: removed dead token (${result.reason ?? result.status})`);
        continue;
      }

      console.error(`send-push: APNs ${result.status} ${result.reason ?? ""}`);
    }

    return new Response("ok", { status: 200 });
  } catch (e) {
    // リトライの嵐を起こさないため、内部エラーは常に 200 で握りつぶす
    console.error("send-push: unhandled error", e);
    return new Response("ok", { status: 200 });
  }
});
