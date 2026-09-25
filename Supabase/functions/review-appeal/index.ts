// ============================================================
// review-appeal / index.ts
// 異議申し立てのAI二次審査 Edge Function (Deno)
// ============================================================
// 設計+実装: Fable 5 (2026-07-29、ユーザー承認「自信あるなら実装入っちゃっていい」)
//
// 役割:
//   申し立て (user_appeals) の送信直後にクライアントから呼ばれ、対象コンテンツを
//   「二次審査」の観点で3値で再判定する (2026-07-30 ユーザー指摘で2値→3値へ:
//   「AI棄却を全部人間キューに積むと、筋なし申し立てが大半を占めて運営の労働が減らない」):
//     - overturn (明白な誤判定)   → status='approved' へ更新 (039 の user_appeals_resolve
//       トリガーがコンテンツ復活 + 通知まで自動で行う)
//     - reject   (明白に筋なし)   → status='rejected' へ更新 = AI が最終却下。
//       トリガーが本人への結果反映まで自動で行い、運営には来ない
//     - unsure   (言い切れない)   → status は 'pending' のまま = 運営 (人間) の最終裁定
//       キューに残る。AI の所見は ai_review (052) に記録され、二次意見として読める
//   これで運営の手動裁定は「AIが白とも黒とも言い切れなかった案件」だけに絞られる。
//   自動最終判定 (approved/rejected) は ai_review.auto=true でマークされ、月次パトロール
//   SQL でサンプル確認できる (申し立ては1投稿1回きりのため、reject は最終決定)。
//
// 認可:
//   verify_jwt ON でデプロイする (deploy 時に --no-verify-jwt を付けない! delete-account と同じ)。
//   さらに関数内で Authorization ヘッダの JWT から uid を取り、appeal.user_id と一致する
//   場合のみ処理する (申し立て本人しか自分の再審査をトリガーできない)。
//
// 判定の傾き:
//   一次判定 (moderate-post) は「安全側に倒す」が、二次審査は申し立て文脈がある前提なので
//   「規約違反が明確に確認できない限り申し立てを認める」方向に倒す。
//   ただし層1 (安全性) の明確な違反は覆さない。
//   reject (自動最終却下) は「原判定が明白に正しく、かつ申し立てに新しい事実・具体的根拠が
//   何もない」場合のみ。迷いが少しでもあれば unsure (人間キュー) に落とす。
//
// エラー処理:
//   失敗しても申し立ては pending のまま人間キューに残るだけ (fail-safe)。
//   HTTP はエラー時も 200 + {status:"skipped"} を返しクライアントを壊さない。
//
// 環境変数: moderate-post と同じ (ANTHROPIC_API_KEY は設定済みの secret を共用)。
// デプロイ: `supabase functions deploy review-appeal`   ← --no-verify-jwt を付けない!
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
// 型
// ------------------------------------------------------------
interface AppealReviewVerdict {
  // 内部用の分析全文 (ai_review に保存、運営キューの二次意見)
  analysis: string;
  // overturn = 復活 / reject = 最終却下 / unsure = 人間キューへ
  decision: "overturn" | "reject" | "unsure";
  // 本人向けの結果メモ (2文以内・丁寧語・内部用語禁止)。overturn/reject 時に
  // resolution_note として保存され、申し立てシートに表示される
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
// moderation_config (rubric + model) — moderate-post と同じ読み方
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
    // 055: unsure 時に再審査する上位モデル (列未適用なら既定 Sonnet)
    escalation_model:
      typeof row.escalation_model === "string" && row.escalation_model.length > 0
        ? row.escalation_model
        : DEFAULT_ANTHROPIC_MODEL,
    // 054 適用前 or 未設定なら null (通知はスキップされるだけで本流に影響なし)
    operator_user_id: typeof row.operator_user_id === "string" && row.operator_user_id.length > 0
      ? row.operator_user_id
      : null,
  };
}

// ------------------------------------------------------------
// 画像取得 (moderate-post と同一ロジック: 512px縮小 + フォールバック)
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
// Claude API (moderate-post と同じ raw fetch + キャッシュ + 構造化出力)
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
      // 067 #10: 700 → 2000。実地で `SyntaxError: Unterminated string in JSON at
      // position 798` が発生していた = analysis が長くなると応答JSONが途中で切れて
      // パース失敗 → fail-safe で握りつぶされ ai_review が NULL のまま pending に残る
      // (ユーザーからは「何も起きない」に見える)。max_tokens は上限であって課金額では
      // ない (実出力分のみ課金) ため引き上げコストはほぼゼロ。
      max_tokens: 2000,
      thinking: { type: "disabled" },
      // rubric 部分は moderate-post と共通の system 接頭辞ではないためキャッシュキーは別だが、
      // 申し立てが連続する場面 (誤判定の多発時) では同一 system が再利用される
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
  // 067 #10: max_tokens で打ち切られた応答は JSON が途中で切れ、この後の JSON.parse が
  // 失敗する。原因をログに明示しておく (パースエラーだけ見ても max_tokens 由来か
  // 判別できないため)。ここでは throw しない (JSON.parse 側の失敗が既存の catch で
  // 拾われ、呼び出し元は従来どおり fail-safe で pending キューに残る)
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
// メイン
// ------------------------------------------------------------
Deno.serve(async (req) => {
  const ok = (body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

  try {
    // 1. 呼び出し者の本人確認 (verify_jwt ON が前提だが、uid と申し立て所有者の一致まで確認する)
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

    // 2. 申し立てをロード (本人 + pending + 未審査のみ。冪等)
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

    // 3. 対象コンテンツ + 原判定をロード
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
      // 列名は 014_b の実定義どおり text (body ではない。046 の author_user_id 誤記の教訓)
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

    // 原判定の内部分析 + 申し立て文を文脈として渡す
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

    // 4. AI 二次審査 (055 カスケード: 基本モデルが unsure なら上位モデルで再審査。
    //    上位モデルでも unsure なら運営キュー+ベル通知 = 「Sonnetでも迷ったら俺が見る」)
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

    // 5. 結果の書き込み (decision で3分岐)
    const isFinal = verdict.decision === "overturn" || verdict.decision === "reject";
    const aiReview = {
      analysis: verdict.analysis,
      decision: verdict.decision,
      user_note: verdict.user_note,
      auto: isFinal, // AI が最終判定したケースのマーク (月次パトロール SQL 用)
      model: usedModel,
      escalated, // 055: 上位モデルへの再審査を経たか
      reviewed_at: new Date().toISOString(),
    };

    if (isFinal) {
      // approved: 039 user_appeals_resolve トリガーがコンテンツ復活+通知を実行
      // rejected: 同トリガーが本人への結果反映を実行 (運営には来ない)
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
        .eq("status", "pending"); // 競合ガード (運営が同時に裁定した場合は何もしない)
      if (error) throw error;
      console.log(
        verdict.decision === "overturn"
          ? `✅ 申し立て自動承認 (appeal=${appealId})`
          : `⛔ 申し立て自動却下 (appeal=${appealId})`,
      );
      return ok({ status: verdict.decision === "overturn" ? "overturned" : "rejected" });
    } else {
      // unsure: 所見を記録し pending のまま人間キューへ。
      // 067 #10: resolution_note に verdict.user_note も書く (status は 'pending' の
      // ままなので、この UPDATE では status キー自体を指定しない = 変更しない)。
      // 従来は ai_review にしか書いていなかったため、AI が生成した「担当者が確認中です」
      // という本人向け文言が捨てられ、申し立てたユーザーからは「無反応」に見えていた。
      // 表示側 (AppealSheetView.swift:174) は既に resolutionNote を描画する作りなので
      // クライアント側の変更は不要
      const { error } = await supabase
        .from("user_appeals")
        .update({ ai_review: aiReview, resolution_note: verdict.user_note })
        .eq("id", appealId)
        .eq("status", "pending");
      if (error) throw error;

      // 054 の運営ベル通知は 2026-07-30 ユーザー判断で撤去 (「無理してやらなくていい」+
      // 自分の申し立て文が自分の通知欄に出る見た目が不評)。unsure の確認は
      // 運営の審査画面を開く運用に一本化。
      // 054 のスキーマ (kind/operator_user_id) は残置 — 復活させる場合はここに
      // create_notification RPC 呼び出しを戻すだけ (git 履歴 085b80e 参照)

      console.log(`↩️ 申し立て unsure→人間キューへ (appeal=${appealId})`);
      return ok({ status: "upheld" });
    }
  } catch (e) {
    // 失敗しても申し立ては pending のまま人間キューに残る (fail-safe)
    console.error(`review-appeal エラー: ${e}`);
    return ok({ status: "skipped", reason: "error" });
  }
});
