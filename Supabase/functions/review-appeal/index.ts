// ============================================================
// review-appeal / index.ts
// Edge Function (Deno) for the AI second review of appeals
// ============================================================
// Design + implementation: Fable 5 (2026-07-29, user approval: "if you are confident, go ahead and
// implement it")
//
// Role:
//   Called by the client right after an appeal (user_appeals) is submitted, and re-judges the content
//   from a "second review" point of view with 3 values (changed from 2 to 3 values after the user's
//   point on 2026-07-30: "if every AI rejection goes to the human queue, weak appeals make up most of
//   it and the operator's work does not go down"):
//     - overturn (clear misjudgment) → update to status='approved' (the user_appeals_resolve
//       trigger in 039 restores the content + sends the notification automatically)
//     - reject   (clearly no grounds) → update to status='rejected' = the AI makes the final rejection.
//       The trigger applies the result for the user automatically, and it never reaches the operator
//     - unsure   (cannot say either way) → status stays 'pending' = stays in the operator (human)
//       final decision queue. The AI's findings are recorded in ai_review (052) and can be read as a
//       second opinion
//   This narrows the operator's manual decisions to "cases the AI could not call either way".
//   Automatic final decisions (approved/rejected) are marked with ai_review.auto=true and can be
//   sampled with the monthly patrol SQL (an appeal is allowed only once per post, so reject is final).
//
// Authorization:
//   Deploy with verify_jwt ON (do not add --no-verify-jwt at deploy! Same as delete-account).
//   In addition, the function takes the uid from the JWT in the Authorization header and processes
//   only if it matches appeal.user_id (only the person who appealed can trigger their own re-review).
//
// Bias of the decision:
//   The first decision (moderate-post) "leans to the safe side", but the second review assumes there
//   is appeal context, so it leans toward "accept the appeal unless a policy violation is clearly
//   confirmed". However, clear layer 1 (safety) violations are not overturned.
//   reject (automatic final rejection) only when "the original decision is clearly correct and the
//   appeal has no new facts or concrete grounds at all". With even a little doubt, fall back to
//   unsure (human queue).
//
// Error handling:
//   Even on failure, the appeal just stays pending in the human queue (fail-safe).
//   On error HTTP still returns 200 + {status:"skipped"} so the client does not break.
//
// Environment variables: same as moderate-post (shares the ANTHROPIC_API_KEY secret already set).
// Deploy: `supabase functions deploy review-appeal`   ← do not add --no-verify-jwt!
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-5";
const ANTHROPIC_VERSION = "2023-06-01";
const POST_IMAGES_BUCKET = "post-images";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// ------------------------------------------------------------
// Types
// ------------------------------------------------------------
interface AppealReviewVerdict {
  // Full internal analysis (saved in ai_review, second opinion for the operator queue)
  analysis: string;
  // overturn = restore / reject = final rejection / unsure = to the human queue
  decision: "overturn" | "reject" | "unsure";
  // Result note for the user (max 2 sentences, polite, no internal terms). On overturn/reject it is
  // saved as resolution_note and shown in the appeal sheet
  user_note: string;
}

type AnthropicContentBlock =
  | { type: "text"; text: string }
  | {
      type: "image";
      source: { type: "base64"; media_type: string; data: string };
    };

const APPEAL_REVIEW_SCHEMA = {
  type: "object",
  properties: {
    analysis: { type: "string" },
    decision: { type: "string", enum: ["overturn", "reject", "unsure"] },
    user_note: { type: "string" },
  },
  required: ["analysis", "decision", "user_note"],
  additionalProperties: false,
} as const;

// ------------------------------------------------------------
// moderation_config (rubric + model). Read the same way as moderate-post
// ------------------------------------------------------------
async function loadConfig(): Promise<{
  safety_rubric: string;
  ethos_rubric: string;
  model: string;
  escalation_model: string;
  operator_user_id: string | null;
}> {
  const { data, error } = await supabase
    .from("moderation_config")
    .select("*")
    .limit(1)
    .maybeSingle();
  if (error || !data) {
    throw new Error(`moderation_config 読み込み失敗: ${error?.message ?? "no rows"}`);
  }
  const row = data as Record<string, unknown>;
  return {
    safety_rubric: String(row.safety_rubric ?? ""),
    ethos_rubric: String(row.ethos_rubric ?? ""),
    model: typeof row.model === "string" && row.model.length > 0
      ? row.model
      : DEFAULT_ANTHROPIC_MODEL,
    // 055: stronger model used to re-review when unsure (defaults to Sonnet if the column is not applied)
    escalation_model:
      typeof row.escalation_model === "string" && row.escalation_model.length > 0
        ? row.escalation_model
        : DEFAULT_ANTHROPIC_MODEL,
    // null before 054 is applied or if not set (the notification is just skipped, no effect on the main
    // flow)
    operator_user_id: typeof row.operator_user_id === "string" && row.operator_user_id.length > 0
      ? row.operator_user_id
      : null,
  };
}

// ------------------------------------------------------------
// Image fetch (same logic as moderate-post: resize to 512px + fallback)
// ------------------------------------------------------------
function buildImagePaths(imagePath: string, imageCount: number): string[] {
  if (!imagePath.endsWith(".jpg")) return [imagePath];
  const base = imagePath.slice(0, -4);
  const count = Math.max(imageCount || 1, 1);
  const paths: string[] = [];
  for (let n = 1; n <= count; n++) {
    paths.push(n === 1 ? imagePath : `${base}_${n}.jpg`);
  }
  return paths;
}

async function fetchImageAsBase64(
  path: string,
): Promise<AnthropicContentBlock | null> {
  const transformUrl =
    `${SUPABASE_URL}/storage/v1/render/image/public/${POST_IMAGES_BUCKET}/${path}?width=512&format=origin`;
  let res = await fetch(transformUrl);
  if (!res.ok) {
    const { data } = supabase.storage.from(POST_IMAGES_BUCKET).getPublicUrl(path);
    const publicUrl = data?.publicUrl;
    if (!publicUrl) return null;
    res = await fetch(publicUrl);
    if (!res.ok) {
      console.error(`画像DL失敗 (${res.status}): ${publicUrl}`);
      return null;
    }
  }
  const buf = new Uint8Array(await res.arrayBuffer());
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < buf.length; i += chunkSize) {
    binary += String.fromCharCode(...buf.subarray(i, i + chunkSize));
  }
  return {
    type: "image",
    source: { type: "base64", media_type: "image/jpeg", data: btoa(binary) },
  };
}

// ------------------------------------------------------------
// Claude API (same raw fetch + cache + structured output as moderate-post)
// ------------------------------------------------------------
async function callClaudeJSON<T>(
  system: string,
  content: AnthropicContentBlock[],
  model: string,
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
      // 067 #10: 700 → 2000. In real use `SyntaxError: Unterminated string in JSON at
      // position 798` was happening = when analysis got long the response JSON was cut off and
      // parsing failed → swallowed by the fail-safe, ai_review stayed NULL and the appeal stayed pending
      // (to the user it looked like "nothing happens"). max_tokens is a cap, not the billed amount
      // (only actual output is billed), so raising it costs almost nothing.
      max_tokens: 2000,
      thinking: { type: "disabled" },
      // The rubric part is not the same system prefix as moderate-post, so the cache key is different, but
      // when appeals come in a row (when misjudgments are frequent) the same system is reused
      system: [
        { type: "text", text: system, cache_control: { type: "ephemeral" } },
      ],
      messages: [{ role: "user", content }],
      output_config: { format: { type: "json_schema", schema: APPEAL_REVIEW_SCHEMA } },
    }),
  });
  if (!res.ok) {
    throw new Error(`Anthropic API ${res.status}: ${await res.text()}`);
  }
  const json = await res.json();
  if (json?.stop_reason === "refusal") {
    throw new Error("model refusal");
  }
  // 067 #10: a response cut off by max_tokens has truncated JSON, and the JSON.parse below
  // fails. Log the cause explicitly (from the parse error alone you cannot tell whether it came from
  // max_tokens). Do not throw here (the JSON.parse failure is caught by the existing catch, and
  // the caller stays in the pending queue by the fail-safe as before)
  if (json?.stop_reason === "max_tokens") {
    console.error(
      "⚠️ Anthropic応答が max_tokens で打ち切られた (JSON parse失敗の原因になりうる)",
    );
  }
  const text = (json?.content ?? []).find(
    (b: Record<string, unknown>) => b?.type === "text",
  )?.text;
  if (typeof text !== "string") throw new Error("empty response");
  return JSON.parse(text) as T;
}

function buildSystemPrompt(cfg: { safety_rubric: string; ethos_rubric: string }): string {
  return [
    "あなたは SNS アプリ「1%」のモデレーション二次審査 AI です。",
    "一次判定で制限されたコンテンツに対して投稿者から異議申し立てがあり、あなたはその再審査を行います。",
    "以下のルーブリックに照らして再評価してください。",
    "",
    "【二次審査の原則 — decision は3値】",
    "- overturn: 規約違反がルーブリック上明確に確認できない場合。一次判定は安全側に倒す設計なので、二次審査は申し立てを認める方向で判断してよい。",
    "- reject: 原判定がルーブリック上明白に正しく、かつ申し立て文に新しい事実・具体的根拠が何もない場合のみ。これは最終却下で人間の確認なしに本人へ通知される。",
    "- unsure: 上のどちらとも言い切れない場合。判断に少しでも迷いがある場合、または申し立てが画像からは確認できない新しい事実 (撮影状況・文脈等) を具体的に主張している場合は、必ず unsure にして人間の最終判断へ回す。",
    "- 安全性ルーブリック (層1) の明確な違反は申し立て内容にかかわらず覆さない (overturn にしない)。",
    "- 申し立て文は投稿者の主張であり事実とは限らない。画像・テキストの実物を優先して判断する。",
    "- analysis には判断根拠を内部用に詳述してよい。",
    "- user_note は本人向け: 2文以内・丁寧語・内部用語 (層1/層2/エトス/シャドー等) 禁止。unsure の場合は「確認中」の趣旨で書く (表示されない可能性もある)。",
    "",
    cfg.safety_rubric,
    "",
    cfg.ethos_rubric,
  ].join("\n");
}

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------
Deno.serve(async (req) => {
  const ok = (body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

  try {
    // 1. Verify the caller's identity (verify_jwt ON is assumed, but also check that the uid matches the
    // appeal owner)
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    const uid = userData?.user?.id;
    if (userError || !uid) {
      return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
    }

    const { appealId } = await req.json().catch(() => ({}));
    if (typeof appealId !== "string" || appealId.length === 0) {
      return ok({ status: "skipped", reason: "no appealId" });
    }

    // 2. Load the appeal (own + pending + not yet reviewed only. Idempotent)
    const { data: appeal, error: appealError } = await supabase
      .from("user_appeals")
      .select("id, user_id, target_post_id, target_comment_id, reason, status, ai_review")
      .eq("id", appealId)
      .maybeSingle();
    if (appealError || !appeal) return ok({ status: "skipped", reason: "not found" });
    if (appeal.user_id !== uid) {
      return new Response(JSON.stringify({ error: "forbidden" }), { status: 403 });
    }
    if (appeal.status !== "pending" || appeal.ai_review != null) {
      return ok({ status: "skipped", reason: "already reviewed" });
    }

    // 3. Load the target content + the original verdict
    const content: AnthropicContentBlock[] = [];
    let originalVerdict: Record<string, unknown> | null = null;

    if (appeal.target_post_id) {
      const { data: post } = await supabase
        .from("user_posts")
        .select("title, text_jp, text_en, overlays, image_path, image_count, moderation_status, moderation_verdict")
        .eq("id", appeal.target_post_id)
        .maybeSingle();
      if (!post) return ok({ status: "skipped", reason: "target missing" });
      if (post.moderation_status === "approved") {
        return ok({ status: "skipped", reason: "already approved" });
      }
      originalVerdict = (post.moderation_verdict ?? null) as Record<string, unknown> | null;

      if (typeof post.image_path === "string" && post.image_path.length > 0) {
        for (const path of buildImagePaths(post.image_path, Number(post.image_count) || 1)) {
          const block = await fetchImageAsBase64(path);
          if (block) content.push(block);
        }
      }
      const overlayTexts = (Array.isArray(post.overlays) ? post.overlays : [])
        .map((o: Record<string, unknown>) =>
          typeof o?.text === "string" ? o.text.trim() : ""
        )
        .filter((t: string) => t.length > 0);
      const textParts = [
        post.title && `タイトル: ${post.title}`,
        overlayTexts.length > 0 &&
        `画像内テキスト (ユーザーが画像に載せた文字): ${overlayTexts.join(" / ")}`,
        post.text_jp && `本文(日本語): ${post.text_jp}`,
        post.text_en && `本文(英語): ${post.text_en}`,
      ].filter(Boolean);
      content.push({
        type: "text",
        text: `【審査対象の投稿】\n${textParts.length > 0 ? textParts.join("\n") : "(画像のみ、テキスト無し)"}`,
      });
    } else {
      // The column name is text, as in the actual definition in 014_b (not body. Lesson from the
      // author_user_id typo in 046)
      const { data: comment } = await supabase
        .from("user_comments")
        .select("text, moderation_status, moderation_verdict")
        .eq("id", appeal.target_comment_id)
        .maybeSingle();
      if (!comment) return ok({ status: "skipped", reason: "target missing" });
      if (comment.moderation_status === "approved") {
        return ok({ status: "skipped", reason: "already approved" });
      }
      originalVerdict = (comment.moderation_verdict ?? null) as Record<string, unknown> | null;
      content.push({
        type: "text",
        text: `【審査対象のコメント】\n${comment.text ?? ""}`,
      });
    }

    // Pass the internal analysis of the original verdict + the appeal text as context
    const verdictSummary = originalVerdict
      ? JSON.stringify(originalVerdict)
      : "(原判定の記録なし)";
    content.push({
      type: "text",
      text: [
        `【一次判定の記録】\n${verdictSummary}`,
        `【投稿者の申し立て】\n${appeal.reason}`,
      ].join("\n\n"),
    });

    // 4. AI second review (055 cascade: if the base model is unsure, re-review with the stronger model.
    //    If the stronger model is also unsure, operator queue + bell notification = "if even Sonnet is
    //    unsure, I will look at it")
    const cfg = await loadConfig();
    const system = buildSystemPrompt(cfg);
    let verdict = await callClaudeJSON<AppealReviewVerdict>(system, content, cfg.model);
    let usedModel = cfg.model;
    let escalated = false;
    if (verdict.decision === "unsure" && cfg.model !== cfg.escalation_model) {
      console.log(`↗️ unsure → ${cfg.escalation_model} で再審査 (appeal=${appealId})`);
      verdict = await callClaudeJSON<AppealReviewVerdict>(system, content, cfg.escalation_model);
      usedModel = cfg.escalation_model;
      escalated = true;
    }

    // 5. Write the result (3 branches on decision)
    const isFinal = verdict.decision === "overturn" || verdict.decision === "reject";
    const aiReview = {
      analysis: verdict.analysis,
      decision: verdict.decision,
      user_note: verdict.user_note,
      auto: isFinal, // Marks cases where the AI made the final decision (for the monthly patrol SQL)
      model: usedModel,
      escalated, // 055: whether it went through re-review by the stronger model
      reviewed_at: new Date().toISOString(),
    };

    if (isFinal) {
      // approved: the 039 user_appeals_resolve trigger restores the content + sends the notification
      // rejected: the same trigger applies the result for the user (never reaches the operator)
      const newStatus = verdict.decision === "overturn" ? "approved" : "rejected";
      const { error } = await supabase
        .from("user_appeals")
        .update({
          status: newStatus,
          resolution_note: verdict.user_note,
          resolved_at: new Date().toISOString(),
          ai_review: aiReview,
        })
        .eq("id", appealId)
        .eq("status", "pending"); // Race guard (does nothing if the operator decided at the same time)
      if (error) throw error;
      console.log(
        verdict.decision === "overturn"
          ? `✅ 申し立て自動承認 (appeal=${appealId})`
          : `⛔ 申し立て自動却下 (appeal=${appealId})`,
      );
      return ok({ status: verdict.decision === "overturn" ? "overturned" : "rejected" });
    } else {
      // unsure: record the findings and leave it pending in the human queue.
      // 067 #10: also write verdict.user_note to resolution_note (status stays 'pending', so this UPDATE
      // does not set the status key at all = no change).
      // Before, it was written only to ai_review, so the AI-generated text for the user, "a staff member
      // is checking this", was thrown away, and to the user who appealed it looked like "no response".
      // The display side (AppealSheetView.swift:174) already renders resolutionNote, so
      // no client change is needed
      const { error } = await supabase
        .from("user_appeals")
        .update({ ai_review: aiReview, resolution_note: verdict.user_note })
        .eq("id", appealId)
        .eq("status", "pending");
      if (error) throw error;

      // The operator bell notification from 054 was removed on 2026-07-30 by user decision ("no need to
      // force it" + the look of your own appeal text showing up in your own notification list was
      // disliked). Checking unsure cases is now done only by opening the operator review screen.
      // The 054 schema (kind/operator_user_id) is left in place. To bring it back, just put the
      // create_notification RPC call back here (see git history 085b80e)

      console.log(`↩️ 申し立て unsure→人間キューへ (appeal=${appealId})`);
      return ok({ status: "upheld" });
    }
  } catch (e) {
    // Even on failure the appeal stays pending in the human queue (fail-safe)
    console.error(`review-appeal エラー: ${e}`);
    return ok({ status: "skipped", reason: "error" });
  }
});
