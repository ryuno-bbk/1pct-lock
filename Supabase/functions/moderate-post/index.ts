// ============================================================
// moderate-post / index.ts
// AI moderation Edge Function (Deno)
// ============================================================
// Design: Fable 5 / Implementation: Sonnet 5
// Design doc: Docs/ai_moderation_design_2026_07_10.md
//
// Role:
//   Receives the Supabase Database Webhook (INSERT) for 3 tables in one place:
//     - user_posts    : images (all carousel images) + text_jp/text_en/title, judged by layer 1→layer 2
//     - user_comments : text only, judged with the same rubric
//     - user_reports  : text only, AI triage (ai_severity 1-5 + ai_summary)
//   The result is written with a direct UPDATE to the target row using the service_role client
//   (the protect trigger in 027_ai_moderation.sql lets rolbypassrls through, so the write works).
//
// Asynchronous UX:
//   Posts/comments appear in the feed immediately at INSERT time while still 'pending'
//   (the RPC in 027 filters only on moderation_status <> 'rejected', so pending stays visible).
//   This Function then judges in the background and only writes the result back.
//
// Error handling:
//   If any of the Claude API call, image download or parsing fails, moderation_status is left as
//   'pending' (it stays visible) and HTTP 200 is returned.
//   Failing the webhook with 4xx/5xx makes Supabase fire a storm of retries, so errors inside this
//   Function are always swallowed with 200 (only logged with console.error).
//   Exception: only a secret mismatch returns 401 (call authorization, fix for 2026-07-20 audit C2).
//
// Environment variables (auto-injected by the Supabase Edge Function runtime / set with secrets set):
//   ANTHROPIC_API_KEY          - set with `supabase secrets set` (user task)
//   MODERATION_WEBHOOK_SECRET  - set with `supabase secrets set` (user task).
//                                Must be the same string as the x-moderation-secret header of
//                                the Database Webhook. While unset, every request gets 401 (fail-closed)
//   SUPABASE_URL               - auto-injected by the runtime
//   SUPABASE_SERVICE_ROLE_KEY  - auto-injected by the runtime
//
// Deploy: `supabase functions deploy moderate-post --no-verify-jwt`
//   (--no-verify-jwt is required: verify_jwt can be passed with the anon key JWT embedded in the
//    app, so it is not authorization. Authorization relies only on the x-moderation-secret check)
// Webhook registration: in Dashboard → Database → Webhooks, point the INSERT events of
//   user_posts/user_comments/user_reports to this Function's URL, and add to HTTP Headers
//   x-moderation-secret: <same value as MODERATION_WEBHOOK_SECRET> (user task)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

// Audit C2 fix: verify with the secret that the call comes from the Database Webhook.
// While unset (""), every request is rejected with 401 (fail-closed)
const MODERATION_WEBHOOK_SECRET = Deno.env.get("MODERATION_WEBHOOK_SECRET") ?? "";

// 047: the model actually used is moderation_config.model (switch with one SQL statement, no deploy).
// This is the fallback when the column is not added / empty. Report triage always uses this default
const DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-5";
const ANTHROPIC_VERSION = "2023-06-01";
const POST_IMAGES_BUCKET = "post-images";
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 066 (cost attack countermeasures part 1, §4-2): defense-in-depth truncate right before sending to
// the AI. The DB side (066_cost_attack_hardening.sql) sets limits of 3000 chars total for overlays
// and 1000 chars for user_reports.detail with a trigger/CHECK constraint, but the Edge Function still
// truncates independently. Two reasons:
//   1. Defense in depth: "billing stays protected even if the DB constraint is loosened later"
//      (design doc §4-2)
//   2. Existing rows created before 066 was applied did not go through the INSERT-time trigger
//      check, so the DB constraint alone cannot cover them. The truncate here is effectively the
//      only barrier
// Implementation simplicity is preferred over exact character counting (surrogate pairs etc.)
// (the goal is a cost cap on moderation input, not exact character handling for display).
function truncateForAI(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen) + "…(truncated)";
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// ------------------------------------------------------------
// Webhook payload type (the shape of Supabase Database Webhooks)
// ------------------------------------------------------------
interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: Record<string, unknown>;
  old_record: Record<string, unknown> | null;
}

// ------------------------------------------------------------
// Load moderation_config (rubric + ethos_enforce)
// ------------------------------------------------------------
interface ModerationConfig {
  ethos_enforce: boolean;
  safety_rubric: string;
  ethos_rubric: string;
  model: string;
  escalation_model: string;
  escalation_threshold: number;
}

async function loadModerationConfig(): Promise<ModerationConfig> {
  // select("*"): does not error even in environments where the 047/055 columns are not applied (falls
  // back to defaults if missing)
  const { data, error } = await supabase
    .from("moderation_config")
    .select("*")
    .limit(1)
    .maybeSingle();

  if (error || !data) {
    throw new Error(
      `moderation_config の読み込みに失敗: ${error?.message ?? "no rows"}`,
    );
  }
  const row = data as Record<string, unknown>;
  const threshold = Number(row.escalation_threshold);
  return {
    ethos_enforce: Boolean(row.ethos_enforce),
    safety_rubric: String(row.safety_rubric ?? ""),
    ethos_rubric: String(row.ethos_rubric ?? ""),
    model: typeof row.model === "string" && row.model.length > 0
      ? row.model
      : DEFAULT_ANTHROPIC_MODEL,
    // 055: 2-stage cascade. Re-judge low-confidence verdicts with a higher-tier model
    escalation_model:
      typeof row.escalation_model === "string" && row.escalation_model.length > 0
        ? row.escalation_model
        : DEFAULT_ANTHROPIC_MODEL,
    escalation_threshold: Number.isFinite(threshold) && threshold > 0 && threshold <= 1
      ? threshold
      : 0.8,
  };
}

// ------------------------------------------------------------
// Claude API call (raw fetch, following the policy of not adding dependencies)
// ------------------------------------------------------------
interface PostVerdict {
  // 2026-07-23 B-full fix: analysis = the full internal analysis text (split out so that we keep
  // reasoning-first while removing the analysis process and internal terms from the user-facing
  // safety_reason/ethos_reason). Never shown to the user (AppealService.fetchModerationInfo only reads
  // the 2 reason keys)
  analysis: string;
  safety: "pass" | "fail";
  safety_reason: string;
  ethos: "pass" | "fail";
  ethos_reason: string;
  confidence: number;
}

interface ReportVerdict {
  severity: number;
  summary: string;
}

type AnthropicContentBlock =
  | { type: "text"; text: string }
  | {
      type: "image";
      source: { type: "base64"; media_type: string; data: string };
    };

// M28 audit fix: dedicated error meaning the Anthropic API returned stop_reason: "refusal" (it
// refused to judge at all for safety/policy reasons). The callers (handleUserPost/handleUserComment)
// catch only this and automatically fall to the safe side, rejected, instead of leaving it pending.
class ModerationRefusalError extends Error {}

async function callClaudeJSON<T>(
  system: string,
  content: AnthropicContentBlock[],
  schema: Record<string, unknown>,
  maxTokens: number,
  model: string = DEFAULT_ANTHROPIC_MODEL,
): Promise<T> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": ANTHROPIC_VERSION,
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      // Moderation is a short classification task, so thinking is explicitly disabled (cost/latency first)
      thinking: { type: "disabled" },
      // 2026-07-29 cost optimization: apply prompt caching to system (= the rubric, thousands of tokens,
      // the same for every judgment). For consecutive judgments within the 5-minute TTL (rapid posting /
      // viral spikes), the input price for that part drops to 1/10. A system shorter than the minimum
      // cache length (1024 tok+), such as report triage, is simply ignored and costs nothing extra.
      // When the rubric is updated by SQL, the cache key changes and a new cache is created automatically
      // (no ops step needed)
      system: [
        {
          type: "text",
          text: system,
          cache_control: { type: "ephemeral" },
        },
      ],
      messages: [{ role: "user", content }],
      output_config: {
        format: { type: "json_schema", schema },
      },
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Anthropic API error ${res.status}: ${body}`);
  }

  const json = await res.json();
  if (json.stop_reason === "refusal") {
    throw new ModerationRefusalError("Anthropic API refused the moderation request");
  }
  const textBlock = (json.content ?? []).find(
    (b: { type: string }) => b.type === "text",
  );
  if (!textBlock) {
    throw new Error("Anthropic API returned no text block");
  }
  return JSON.parse(textBlock.text) as T;
}

// Putting analysis first = a reasoning-first structure where the model writes out the analysis
// (reasoning) before giving the verdict. This keeps accuracy while moving the analysis process out
// of the user-facing *_reason (B-full, 2026-07-23)
const POST_VERDICT_SCHEMA = {
  type: "object",
  properties: {
    analysis: {
      type: "string",
      description:
        "内部用の分析メモ (運営のみ閲覧)。層1/層2それぞれの検討過程・迷った点を自由に書く。判定より先にここで分析を完了させること",
    },
    safety: { type: "string", enum: ["pass", "fail"] },
    safety_reason: {
      type: "string",
      description:
        "投稿者本人にそのまま表示される説明文。表示ルールはルーブリックの【本人向け理由文のルール】に従う",
    },
    ethos: { type: "string", enum: ["pass", "fail"] },
    ethos_reason: {
      type: "string",
      description:
        "投稿者本人にそのまま表示される説明文。表示ルールはルーブリックの【本人向け理由文のルール】に従う",
    },
    confidence: { type: "number" },
  },
  required: [
    "analysis",
    "safety",
    "safety_reason",
    "ethos",
    "ethos_reason",
    "confidence",
  ],
  additionalProperties: false,
};

const REPORT_VERDICT_SCHEMA = {
  type: "object",
  properties: {
    severity: { type: "integer", enum: [1, 2, 3, 4, 5] },
    summary: { type: "string" },
  },
  required: ["severity", "summary"],
  additionalProperties: false,
};

function buildSystemPrompt(config: ModerationConfig): string {
  return [
    "あなたは SNS アプリ「1%」の投稿モデレーション AI です。",
    "層1(安全性)→層2(1%エトス)の順で評価し、必ず指定された JSON 形式のみで回答してください。",
    "confidence には判定全体の確信度を 0〜1 の数値で出力してください。ルーブリックの適用に迷いがある・境界的だと感じる場合は 0.8 未満にしてください。",
    // 2026-07-30 gravure countermeasure (v15: user policy "Haiku judges everything by default, with a
    // net only at the moment something is nearly missed"):
    // ① reject verdicts = final in one shot ② a pass clearly identified as actual exercise/stage =
    // passes in one shot (gym/walking/K-POP) ③ only when passing other revealing content, force low
    // confidence = re-check by the higher model (= the net for missed gravure).
    // Remaining risk: a confident misclassification that gets the scene itself wrong can get through →
    // the 056 rubric + the 3-report threshold (042) are the later net
    "人物画像を pass と判定する際、その場面が「運動・競技・練習を実際にしている場面 (ジム・ランニング・ウォーキング等)」または「ステージ上のパフォーマンス・公式の宣材写真」だと明確に認定できる場合は、通常どおりの confidence で構いません。それ以外で露出が多い人物画像 (水着・下着・ポーズ写真・身体の強調が主目的の構図) を pass と判定する場合のみ、confidence を 0.7 以下にしてください (上位モデルによる再確認に回されます)。fail 判定にはこの制限を適用しません。",
    "analysis は要点のみ簡潔に (最大3文)。",
    "",
    config.safety_rubric,
    "",
    config.ethos_rubric,
  ].join("\n");
}

// 055: 2-stage cascade judgment. Judge with the base model (Haiku), and if confidence is below the
// threshold, re-judge with the higher model (Sonnet) and use that result. If model and
// escalation_model are the same value, it runs as a single stage (cascade disabled). A refusal at
// either stage falls to the caller's refusal fallback (safe side, rejected)
async function judgeWithCascade(
  system: string,
  content: AnthropicContentBlock[],
  maxTokens: number,
  config: ModerationConfig,
  logId: string,
): Promise<PostVerdict & { model: string; escalated: boolean }> {
  const first = await callClaudeJSON<PostVerdict>(
    system,
    content,
    POST_VERDICT_SCHEMA,
    maxTokens,
    config.model,
  );
  if (
    config.model === config.escalation_model ||
    first.confidence >= config.escalation_threshold
  ) {
    return { ...first, model: config.model, escalated: false };
  }
  console.log(
    `↗️ 低confidence(${first.confidence}) → ${config.escalation_model} へエスカレーション (${logId})`,
  );
  const second = await callClaudeJSON<PostVerdict>(
    system,
    content,
    POST_VERDICT_SCHEMA,
    maxTokens,
    config.escalation_model,
  );
  return { ...second, model: config.escalation_model, escalated: true };
}

// ------------------------------------------------------------
// user_posts: fetch images (all carousel images)
// ------------------------------------------------------------
// Path convention (same as UserPostService.swift / 021_post_carousel.sql):
//   1st image = image_path itself ("{uid}/{post_id}.jpg")
//   2nd and later = "{base}_2.jpg" to "_4.jpg" (base = image_path with ".jpg" removed)
function buildImagePaths(imagePath: string, imageCount: number): string[] {
  if (!imagePath.endsWith(".jpg")) {
    // TODO: add handling here for unexpected extensions/formats.
    // For now only the 1st image is judged (falls to the safe side as the layer 1 fallback).
    return [imagePath];
  }
  const base = imagePath.slice(0, -4); // Remove ".jpg"
  const count = Math.max(imageCount || 1, 1);
  const paths: string[] = [];
  for (let n = 1; n <= count; n++) {
    paths.push(n === 1 ? imagePath : `${base}_${n}.jpg`);
  }
  return paths;
}

// 067 #7: logic for a single attempt (the 2-step approach itself, resize transform → original-size
// fallback, is unchanged). The caller (fetchImageAsBase64 below) wraps this with retries.
async function fetchImageAsBase64Attempt(
  path: string,
): Promise<AnthropicContentBlock | null> {
  // M29 lightweight fix: resize with Storage Image Transformations (only on supported plans) before
  // sending, to reduce the image tokens sent to Anthropic.
  // Only if the transform URL returns non-200 (plan not supported, etc.), fall back to an
  // original-size fetch.
  // 2026-07-25 cost measure: 768→512px (about 55% fewer image tokens, the dominant cost of one
  // judgment). For moderation use (telling nudity/violence/gym/play apart), 512px is enough resolution
  const transformUrl =
    `${SUPABASE_URL}/storage/v1/render/image/public/${POST_IMAGES_BUCKET}/${path}?width=512&format=origin`;
  const transformRes = await fetch(transformUrl);

  let res = transformRes;
  if (!transformRes.ok) {
    // Fallback for plans without transform support, etc. (this log is written per image, so keep it
    // short)
    console.log(`画像変換フォールバック (status=${transformRes.status}): ${path}`);

    const { data } = supabase.storage.from(POST_IMAGES_BUCKET).getPublicUrl(
      path,
    );
    const publicUrl = data?.publicUrl;
    if (!publicUrl) return null;

    res = await fetch(publicUrl);
    if (!res.ok) {
      console.error(`画像DL失敗 (${res.status}): ${publicUrl}`);
      return null;
    }
  }
  const buf = new Uint8Array(await res.arrayBuffer());
  // btoa is not binary-safe, so convert in chunks
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < buf.length; i += chunkSize) {
    binary += String.fromCharCode(...buf.subarray(i, i + chunkSize));
  }
  const base64 = btoa(binary);
  return {
    type: "image",
    source: { type: "base64", media_type: "image/jpeg", data: base64 },
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// 067 #7: short retry so that a temporary Storage fetch failure (5xx/timeout etc.) does not wrongly
// push a valid post into fail-closed. 3 attempts total with exponential backoff (0.5s → 1s).
// Returns null if all 3 fail. The caller (handleUserPost) uses this to detect
// "imagePath exists but not a single image could be fetched" and makes it fail-closed (rejected).
async function fetchImageAsBase64(
  path: string,
): Promise<AnthropicContentBlock | null> {
  const backoffsMs = [500, 1000];
  for (let attempt = 0; ; attempt++) {
    try {
      const block = await fetchImageAsBase64Attempt(path);
      if (block) return block;
      // block is null = non-200 kept coming back (not an exception). This is also retried
      // (it may be a temporary 5xx/404)
    } catch (e) {
      console.error(
        `画像取得で例外 (attempt=${attempt + 1}/${backoffsMs.length + 1}, path=${path}):`,
        e instanceof Error ? e.message : e,
      );
    }
    if (attempt >= backoffsMs.length) return null; // Retries used up
    await sleep(backoffsMs[attempt]);
  }
}

// ------------------------------------------------------------
// verdict → moderation_status mapping
// ------------------------------------------------------------
function mapVerdictToStatus(verdict: PostVerdict): string {
  if (verdict.safety === "fail") return "rejected";
  if (verdict.ethos === "fail") return "flagged";
  return "approved";
}

// ------------------------------------------------------------
// user_posts handler
// ------------------------------------------------------------
async function handleUserPost(id: string): Promise<void> {
  // Audit C2 fix: do not trust the payload body. Always refetch the target from the DB
  // (makes laundering/censoring moderation with a fake webhook carrying fake text structurally
  // impossible)
  const { data: row, error: fetchError } = await supabase
    .from("user_posts")
    .select("image_path, image_count, text_jp, text_en, title, overlays, moderation_status, moderated_at")
    .eq("id", id)
    .maybeSingle();

  if (fetchError) {
    throw new Error(`user_posts 再取得失敗 (id=${id}): ${fetchError.message}`);
  }
  if (!row) {
    // Row does not exist (fake id / deleted before judging) → do nothing
    console.log(`↩️ user_posts 行なし、スキップ (id=${id})`);
    return;
  }
  if (row.moderated_at !== null || row.moderation_status !== "pending") {
    // Idempotency guard: do not re-judge rows already judged (protection against webhook resends /
    // duplicate calls)
    console.log(`↩️ 判定済みのためスキップ (id=${id}, status=${row.moderation_status})`);
    return;
  }

  const imagePath = row.image_path as string | null;
  const imageCount = (row.image_count as number | null) ?? 1;
  const textJp = (row.text_jp as string | null) ?? "";
  const textEn = (row.text_en as string | null) ?? "";
  const title = (row.title as string | null) ?? "";

  const config = await loadModerationConfig();

  const content: AnthropicContentBlock[] = [];

  // 067 #7: count the expected number of images (paths.length if imagePath exists) and the number
  // actually fetched. There was a hole where approved could be finalized from the text alone when
  // imagePath was non-NULL but not a single image could be fetched (even when fetchImageAsBase64
  // returned null, the caller just silently dropped it, and no branch detected "0 images").
  let fetchedImageCount = 0;
  if (imagePath) {
    const paths = buildImagePaths(imagePath, imageCount);
    for (const path of paths) {
      const block = await fetchImageAsBase64(path);
      if (block) {
        content.push(block);
        fetchedImageCount++;
      }
    }
  }

  if (imagePath && fetchedImageCount === 0) {
    // 067 #7: if not a single image can be fetched even after retrying (3 attempts total), do not run
    // the judgment and finalize as rejected (fail-closed). Leaving it pending would achieve the
    // attacker's goal of "keeping an unreviewed post visible"
    // (follows the same decision and the same shape as the ModerationRefusalError at index.ts:468-490).
    // If only some images were fetched (fetchedImageCount > 0), this branch is not entered and it
    // continues as before.
    const { error } = await supabase
      .from("user_posts")
      .update({
        moderation_status: "rejected",
        moderation_verdict: {
          analysis: "image fetch failed (auto-rejected)",
          safety: "fail",
          safety_reason: "Image could not be loaded for review (auto-rejected)",
          ethos: "fail",
          ethos_reason: "",
          confidence: 1,
        },
        moderated_at: new Date().toISOString(),
      })
      .eq("id", id);
    if (error) {
      throw new Error(`image-fetch-fail時のuser_posts UPDATE失敗 (id=${id}): ${error.message}`);
    }
    console.error(`⛔ 画像0枚のためfail-closed rejected (id=${id}, imagePath=${imagePath})`);
    return;
  }

  // For v2 posts, the user's text is mainly baked into the image (overlays). If the raw text is not
  // passed to the judgment, the AI only sees it as pixels in the resized image and cannot read small
  // text (found when the user pointed it out on 2026-07-25).
  // overlays jsonb: [{ text, imageIndex, ... }] (same shape as PostOverlayDTO / UserPost.swift)
  const overlayTexts = (Array.isArray(row.overlays) ? row.overlays : [])
    .map((o: Record<string, unknown>) =>
      typeof o?.text === "string" ? o.text.trim() : ""
    )
    .filter((t: string) => t.length > 0);

  // 066 §4-2: the DB side (066 migration) checks the 3000-char overlays total only at INSERT time.
  // The truncate here is the final barrier that covers both (a) insurance in case that constraint is
  // loosened later and (b) existing rows created before 066 was applied (never checked)
  const overlayTextsJoined = truncateForAI(overlayTexts.join(" / "), 3000);

  const textParts = [
    title && `タイトル: ${title}`,
    overlayTexts.length > 0 && `画像内テキスト (ユーザーが画像に載せた文字): ${overlayTextsJoined}`,
    textJp && `本文(日本語): ${textJp}`,
    textEn && `本文(英語): ${textEn}`,
  ].filter(Boolean);

  content.push({
    type: "text",
    text: textParts.length > 0
      ? textParts.join("\n")
      : "(画像のみ、テキスト無し)",
  });

  let verdict: PostVerdict & { model: string; escalated: boolean };
  try {
    verdict = await judgeWithCascade(
      buildSystemPrompt(config),
      content,
      // Increased to match the analysis field added on 2026-07-23. A cut-off response becomes a JSON parse
      // error
      700,
      config,
      `user_posts id=${id}`,
    );
  } catch (e) {
    if (e instanceof ModerationRefusalError) {
      // M28: a refusal is a signal that "it is dangerous enough for the AI to refuse to judge at all", so
      // fall to the safe side, rejected, instead of pending (stays visible)
      const { error } = await supabase
        .from("user_posts")
        .update({
          moderation_status: "rejected",
          moderation_verdict: {
            analysis: "refusal fallback (moderation request refused by API)",
            safety: "fail",
            safety_reason: "AI refused to classify this content (auto-rejected as unsafe)",
            ethos: "fail",
            ethos_reason: "",
            confidence: 1,
          },
          moderated_at: new Date().toISOString(),
        })
        .eq("id", id);
      if (error) {
        throw new Error(`refusal時のuser_posts UPDATE失敗 (id=${id}): ${error.message}`);
      }
      return;
    }
    throw e; // Anything other than refusal is rethrown as before (outside, it stays pending and is only logged)
  }

  const status = mapVerdictToStatus(verdict);

  const { error } = await supabase
    .from("user_posts")
    .update({
      moderation_status: status,
      moderation_verdict: verdict,
      moderated_at: new Date().toISOString(),
    })
    .eq("id", id);

  if (error) {
    throw new Error(`user_posts UPDATE 失敗 (id=${id}): ${error.message}`);
  }
}

// ------------------------------------------------------------
// user_comments handler (text only)
// ------------------------------------------------------------
async function handleUserComment(id: string): Promise<void> {
  // Audit C2 fix: refetch the text to judge from the DB (do not trust the payload)
  const { data: row, error: fetchError } = await supabase
    .from("user_comments")
    .select("text, moderation_status, moderated_at")
    .eq("id", id)
    .maybeSingle();

  if (fetchError) {
    throw new Error(`user_comments 再取得失敗 (id=${id}): ${fetchError.message}`);
  }
  if (!row) {
    console.log(`↩️ user_comments 行なし、スキップ (id=${id})`);
    return;
  }
  if (row.moderated_at !== null || row.moderation_status !== "pending") {
    console.log(`↩️ 判定済みのためスキップ (id=${id}, status=${row.moderation_status})`);
    return;
  }

  const text = (row.text as string | null) ?? "";

  const config = await loadModerationConfig();

  let verdict: PostVerdict & { model: string; escalated: boolean };
  try {
    verdict = await judgeWithCascade(
      buildSystemPrompt(config),
      [{ type: "text", text: text || "(本文無し)" }],
      // Increased to match the analysis field added on 2026-07-23
      500,
      config,
      `user_comments id=${id}`,
    );
  } catch (e) {
    if (e instanceof ModerationRefusalError) {
      // M28: a refusal is a signal that "it is dangerous enough for the AI to refuse to judge at all", so
      // fall to the safe side, rejected, instead of pending (stays visible)
      const { error } = await supabase
        .from("user_comments")
        .update({
          moderation_status: "rejected",
          moderation_verdict: {
            analysis: "refusal fallback (moderation request refused by API)",
            safety: "fail",
            safety_reason: "AI refused to classify this content (auto-rejected as unsafe)",
            ethos: "fail",
            ethos_reason: "",
            confidence: 1,
          },
          moderated_at: new Date().toISOString(),
        })
        .eq("id", id);
      if (error) {
        throw new Error(`refusal時のuser_comments UPDATE失敗 (id=${id}): ${error.message}`);
      }
      return;
    }
    throw e; // Anything other than refusal is rethrown as before (outside, it stays pending and is only logged)
  }

  const status = mapVerdictToStatus(verdict);

  const { error } = await supabase
    .from("user_comments")
    .update({
      moderation_status: status,
      moderation_verdict: verdict,
      moderated_at: new Date().toISOString(),
    })
    .eq("id", id);

  if (error) {
    throw new Error(`user_comments UPDATE 失敗 (id=${id}): ${error.message}`);
  }
}

// ------------------------------------------------------------
// user_reports handler (AI triage, text only)
// ------------------------------------------------------------
async function handleUserReport(id: string): Promise<void> {
  // Audit C2 fix: also refetch the report content from the DB. If ai_severity is already set, do not
  // re-judge
  const { data: row, error: fetchError } = await supabase
    .from("user_reports")
    .select("reason, detail, ai_severity")
    .eq("id", id)
    .maybeSingle();

  if (fetchError) {
    throw new Error(`user_reports 再取得失敗 (id=${id}): ${fetchError.message}`);
  }
  if (!row) {
    console.log(`↩️ user_reports 行なし、スキップ (id=${id})`);
    return;
  }
  if (row.ai_severity !== null) {
    // Idempotency guard: already triaged (user_reports has no moderated_at, so ai_severity is used to
    // check)
    console.log(`↩️ トリアージ済みのためスキップ (id=${id})`);
    return;
  }

  const reason = (row.reason as string | null) ?? "";
  // 066 §4-2: a 1000-char limit on user_reports.detail was added with a DB-side CHECK constraint (066
  // migration), but existing rows (created before it was applied) are not covered by the constraint,
  // so truncate independently here too
  const detail = truncateForAI((row.detail as string | null) ?? "", 1000);

  const system = [
    "あなたは SNS アプリ「1%」の通報トリアージ AI です。",
    "通報内容から優先度(severity: 1=低 〜 5=高、緊急性/深刻度が高いほど大きい数字)と",
    "運営が一目で状況を把握できる短い要約(summary、日本語)を JSON で返してください。",
  ].join("\n");

  const verdict = await callClaudeJSON<ReportVerdict>(
    system,
    [{
      type: "text",
      text: `通報理由: ${reason}\n詳細: ${detail || "(詳細記入無し)"}`,
    }],
    REPORT_VERDICT_SCHEMA,
    300,
  );

  const { error } = await supabase
    .from("user_reports")
    .update({
      ai_severity: verdict.severity,
      ai_summary: verdict.summary,
    })
    .eq("id", id);

  if (error) {
    throw new Error(`user_reports UPDATE 失敗 (id=${id}): ${error.message}`);
  }
}

// ------------------------------------------------------------
// Entry point
// ------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  // Compare with the x-moderation-secret header set on the Database Webhook (audit C2).
  // Any mismatch, including an unset secret (forgot secrets set), is 401 (fail-closed)
  const gotSecret = req.headers.get("x-moderation-secret");
  if (!MODERATION_WEBHOOK_SECRET || gotSecret !== MODERATION_WEBHOOK_SECRET) {
    // Do not log the value itself (it is a secret). Diagnose the cause from the length only
    console.error(
      `❌ secret mismatch: got len=${gotSecret?.length ?? 0} expected len=${MODERATION_WEBHOOK_SECRET.length}`,
    );
    return new Response("unauthorized", { status: 401 });
  }

  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch (e) {
    console.error("payload の JSON パースに失敗:", e);
    // If parsing itself fails, retrying is pointless, so finish with 200
    return new Response("ok", { status: 200 });
  }

  try {
    if (payload.type !== "INSERT") {
      // Anything other than INSERT is out of scope (UPDATE/DELETE are ignored)
      return new Response("ignored", { status: 200 });
    }

    // From the payload, only table and record.id are trusted (audit C2).
    // The body, image path etc. are refetched from the DB by each handler with service_role
    const recordId = payload.record?.id;
    if (typeof recordId !== "string" || !UUID_RE.test(recordId)) {
      console.error(`record.id が UUID でない: ${String(recordId)}`);
      return new Response("ignored", { status: 200 });
    }

    switch (payload.table) {
      case "user_posts":
        await handleUserPost(recordId);
        break;
      case "user_comments":
        await handleUserComment(recordId);
        break;
      case "user_reports":
        await handleUserReport(recordId);
        break;
      default:
        console.error(`未対応のテーブル: ${payload.table}`);
    }
  } catch (e) {
    // On a judgment failure, moderation_status stays 'pending' (it stays visible).
    // Always return 200 to avoid a webhook retry storm.
    console.error(
      `モデレーション処理失敗 (table=${payload.table}):`,
      e instanceof Error ? e.message : e,
    );
  }

  return new Response("ok", { status: 200 });
});
