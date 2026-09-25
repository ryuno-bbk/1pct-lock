// ============================================================
// moderate-post / index.ts
// AI モデレーション Edge Function (Deno)
// ============================================================
// 設計: Fable 5 / 実装: Sonnet 5
// 設計書: Docs/ai_moderation_design_2026_07_10.md
//
// 役割:
//   Supabase Database Webhook (INSERT) を 3 テーブル分まとめて受ける:
//     - user_posts    : 画像 (carousel 全枚数) + text_jp/text_en/title を層1→層2で判定
//     - user_comments : テキストのみ、同じルーブリックで判定
//     - user_reports  : テキストのみ、AI トリアージ (ai_severity 1-5 + ai_summary)
//   判定結果は service_role クライアントで該当行へ直接 UPDATE する
//   (027_ai_moderation.sql の protect trigger は rolbypassrls を通すため書き込める)。
//
// 非同期 UX:
//   投稿/コメントは INSERT 時点で 'pending' のままフィードに即時表示される
//   (027 の RPC は moderation_status <> 'rejected' のみ弾くため、pending は表示継続)。
//   このFunctionはその後バックグラウンドで判定し、結果を書き戻すだけ。
//
// エラー処理:
//   Claude API 呼び出し・画像DL・パースのいずれかで失敗しても moderation_status は
//   'pending' のまま放置し (表示は継続)、HTTP 200 を返す。
//   Webhook を 4xx/5xx で落とすと Supabase 側がリトライの嵐を起こすため、
//   このFunction内部のエラーは常に 200 で握りつぶす (console.error でログのみ残す)。
//   例外: シークレット照合失敗のみ 401 (呼び出し認可、2026-07-20 監査 C2 対応)。
//
// 環境変数 (Supabase Edge Function ランタイムが自動注入 / secrets set で設定):
//   ANTHROPIC_API_KEY          - `supabase secrets set` で設定 (ユーザー作業)
//   MODERATION_WEBHOOK_SECRET  - `supabase secrets set` で設定 (ユーザー作業)。
//                                Database Webhook の x-moderation-secret ヘッダと
//                                同じ文字列にする。未設定の間は全リクエスト 401 (fail-closed)
//   SUPABASE_URL               - ランタイム自動注入
//   SUPABASE_SERVICE_ROLE_KEY  - ランタイム自動注入
//
// デプロイ: `supabase functions deploy moderate-post --no-verify-jwt`
//   (--no-verify-jwt 必須: verify_jwt はアプリ埋め込みの anon key JWT で通過できて
//    認可にならないため、x-moderation-secret 照合一本に統一する)
// Webhook 登録: Dashboard → Database → Webhooks で user_posts/user_comments/user_reports
//   の INSERT イベントをこの Function の URL に向け、HTTP Headers に
//   x-moderation-secret: <MODERATION_WEBHOOK_SECRET と同じ値> を追加する (ユーザー作業)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

// 監査C2対応: Database Webhook からの呼び出しであることをシークレットで検証する。
// 未設定 ("") の間は全リクエストを 401 で拒否する (fail-closed)
const MODERATION_WEBHOOK_SECRET = Deno.env.get("MODERATION_WEBHOOK_SECRET") ?? "";

// 047: 実際に使うモデルは moderation_config.model (SQL 一発で切替、デプロイ不要)。
// これは列が未追加/空の場合のフォールバック。通報トリアージは常にこの既定を使う
const DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-5";
const ANTHROPIC_VERSION = "2023-06-01";
const POST_IMAGES_BUCKET = "post-images";
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 066 (コスト攻撃対策 第1弾, §4-2): AIに送る直前の多層防御 truncate。
// DB側 (066_cost_attack_hardening.sql) で overlays合計3000字 / user_reports.detail
// 1000字の上限をトリガー/CHECK制約で設けたが、それでも Edge Function 側で独立に
// 切る。理由は2つ:
//   1. 「DB制約が将来緩められても課金が守られる」多層防御 (設計書 §4-2)
//   2. 066 適用前に作られた既存行は INSERT 時点のトリガー検証を通っていないため、
//      DB制約だけでは救えない。ここでの truncate が実質的な唯一の防波堤になる
// 文字数カウントの厳密さ (サロゲートペア等) より実装のシンプルさを優先している
// (モデレーション入力のコスト上限が目的で、表示用の正確な文字送りではないため)。
function truncateForAI(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen) + "…(truncated)";
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// ------------------------------------------------------------
// Webhook payload 型 (Supabase Database Webhooks の形)
// ------------------------------------------------------------
interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: Record<string, unknown>;
  old_record: Record<string, unknown> | null;
}

// ------------------------------------------------------------
// moderation_config (rubric + ethos_enforce) 読み込み
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
  // select("*"): 047/055 の列が未適用の環境でもエラーにしない (欠けていれば既定へフォールバック)
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
    // 055: 2段カスケード。低confidence判定を上位モデルで再判定する
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
// Claude API 呼び出し (raw fetch、依存を増やさない方針)
// ------------------------------------------------------------
interface PostVerdict {
  // 2026-07-23 B-full対応: analysis = 内部用の分析全文 (reasoning-first を維持したまま
  // 本人向け safety_reason/ethos_reason から分析過程・内部用語を排除するための分離先)。
  // 本人には一切表示しない (AppealService.fetchModerationInfo は reason 2キーしか読まない)
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

// M28監査対応: Anthropic API が stop_reason: "refusal" (safety/policy上の理由で判定自体を拒否)
// を返したことを表す専用エラー。呼び出し側 (handleUserPost/handleUserComment) はこれだけを
// catch し、pending放置ではなく安全側のrejectedへ自動的に倒す。
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
      // モデレーションは短い分類タスクなので thinking は明示的に無効化 (コスト/レイテンシ優先)
      thinking: { type: "disabled" },
      // 2026-07-29 コスト最適化: system (= rubric 数千tok、全判定で同一) にプロンプトキャッシュを
      // 効かせる。5分TTL内の連続判定 (連投/バズ時) で該当部分の input 単価が 1/10 になる。
      // 最低キャッシュ長 (1024tok〜) 未満の system (通報トリアージ等) では単に無視され課金増もない。
      // rubric を SQL で更新した場合はキャッシュキーが変わり自動で新規キャッシュになる (運用手順不要)
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

// analysis を先頭に置く = 分析(reasoning)を書き切ってから判定を出させる reasoning-first 構成。
// これで精度を保ったまま、本人表示用の *_reason から分析過程を追い出せる (B-full, 2026-07-23)
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
    // 2026-07-30 グラビア対策 (v15: ユーザー方針「基本Haikuで全部判断、見逃しかけの瞬間だけ網」):
    // ①弾く判定=一発確定 ②明確に運動実施/ステージと認定できたpass=一発通過 (ジム/ウォーキング/K-POP)
    // ③それ以外の露出系をpassにする時だけ低confidence強制=上位モデルの再確認 (=グラビア見逃しの網)。
    // 残余リスク: 場面認定ごと誤る自信満々の誤分類は通り得る → 056ルーブリック+通報3件閾値(042)が後段の網
    "人物画像を pass と判定する際、その場面が「運動・競技・練習を実際にしている場面 (ジム・ランニング・ウォーキング等)」または「ステージ上のパフォーマンス・公式の宣材写真」だと明確に認定できる場合は、通常どおりの confidence で構いません。それ以外で露出が多い人物画像 (水着・下着・ポーズ写真・身体の強調が主目的の構図) を pass と判定する場合のみ、confidence を 0.7 以下にしてください (上位モデルによる再確認に回されます)。fail 判定にはこの制限を適用しません。",
    "analysis は要点のみ簡潔に (最大3文)。",
    "",
    config.safety_rubric,
    "",
    config.ethos_rubric,
  ].join("\n");
}

// 055: 2段カスケード判定。基本モデル (Haiku) で判定し、confidence が閾値未満なら
// 上位モデル (Sonnet) で再判定してそちらを採用する。model と escalation_model が
// 同一値の場合は単段運用 (カスケード無効)。refusal はどちらの段でも呼び出し元の
// refusal フォールバック (安全側 rejected) に落ちる
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
// user_posts: 画像 (carousel 全枚数) 取得
// ------------------------------------------------------------
// パス規約 (UserPostService.swift / 021_post_carousel.sql と同一):
//   1枚目 = image_path そのもの ("{uid}/{post_id}.jpg")
//   2枚目以降 = "{base}_2.jpg" 〜 "_4.jpg" (base = image_path から ".jpg" を除去)
function buildImagePaths(imagePath: string, imageCount: number): string[] {
  if (!imagePath.endsWith(".jpg")) {
    // TODO: 想定外の拡張子/フォーマットの場合はここで対応を追加する。
    // 現状は1枚目のみ判定対象にする (層1のフォールバックとして安全側に倒す)。
    return [imagePath];
  }
  const base = imagePath.slice(0, -4); // ".jpg" を除去
  const count = Math.max(imageCount || 1, 1);
  const paths: string[] = [];
  for (let n = 1; n <= count; n++) {
    paths.push(n === 1 ? imagePath : `${base}_${n}.jpg`);
  }
  return paths;
}

// 067 #7: 1回分の取得ロジック (縮小変換→原寸フォールバックの2段構え自体は変更しない)。
// 呼び出し側 (下の fetchImageAsBase64) がこれをリトライでラップする。
async function fetchImageAsBase64Attempt(
  path: string,
): Promise<AnthropicContentBlock | null> {
  // M29軽量対応: Storage Image Transformations (対応プランのみ有効) で縮小してから送信し、
  // Anthropicへの画像トークンを削減する。
  // 変換URLが非200 (プラン未対応など) を返した場合のみ、原寸fetchにフォールバックする。
  // 2026-07-25 コスト対策: 768→512px (画像トークン約55%減、1判定の支配項)。
  // モデレーション用途 (ヌード/暴力/ジム/遊びの判別) は512pxで十分な解像度
  const transformUrl =
    `${SUPABASE_URL}/storage/v1/render/image/public/${POST_IMAGES_BUCKET}/${path}?width=512&format=origin`;
  const transformRes = await fetch(transformUrl);

  let res = transformRes;
  if (!transformRes.ok) {
    // 変換非対応プラン等へのフォールバック (画像ごとに出るログのため簡潔に留める)
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
  // btoa はバイナリ安全ではないため chunk 単位で変換する
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

// 067 #7: Storage の一時的な取得失敗 (5xx/タイムアウト等) で正当な投稿を誤って
// fail-closed に倒さないための短いリトライ。計3回・指数バックオフ (0.5s → 1s)。
// 3回とも失敗したら null を返す。呼び出し側 (handleUserPost) はこれを見て
// 「imagePath はあるのに1枚も取得できなかった」を判定し、fail-closed (rejected) にする。
async function fetchImageAsBase64(
  path: string,
): Promise<AnthropicContentBlock | null> {
  const backoffsMs = [500, 1000];
  for (let attempt = 0; ; attempt++) {
    try {
      const block = await fetchImageAsBase64Attempt(path);
      if (block) return block;
      // block が null = 非200が続いた (例外ではない)。これもリトライ対象にする
      // (一時的な5xx/404の可能性があるため)
    } catch (e) {
      console.error(
        `画像取得で例外 (attempt=${attempt + 1}/${backoffsMs.length + 1}, path=${path}):`,
        e instanceof Error ? e.message : e,
      );
    }
    if (attempt >= backoffsMs.length) return null; // リトライ回数を使い切った
    await sleep(backoffsMs[attempt]);
  }
}

// ------------------------------------------------------------
// verdict → moderation_status マッピング
// ------------------------------------------------------------
function mapVerdictToStatus(verdict: PostVerdict): string {
  if (verdict.safety === "fail") return "rejected";
  if (verdict.ethos === "fail") return "flagged";
  return "approved";
}

// ------------------------------------------------------------
// user_posts ハンドラ
// ------------------------------------------------------------
async function handleUserPost(id: string): Promise<void> {
  // 監査C2対応: payload の本文は信用せず、判定対象は必ず DB から再取得する
  // (偽テキストを添えた偽 webhook による moderation 洗浄/検閲を構造的に不可能にする)
  const { data: row, error: fetchError } = await supabase
    .from("user_posts")
    .select("image_path, image_count, text_jp, text_en, title, overlays, moderation_status, moderated_at")
    .eq("id", id)
    .maybeSingle();

  if (fetchError) {
    throw new Error(`user_posts 再取得失敗 (id=${id}): ${fetchError.message}`);
  }
  if (!row) {
    // 行が存在しない (偽 id / 判定前に削除済み) → 何もしない
    console.log(`↩️ user_posts 行なし、スキップ (id=${id})`);
    return;
  }
  if (row.moderated_at !== null || row.moderation_status !== "pending") {
    // 冪等ガード: 判定済み行は再判定しない (webhook 再送・重複呼び出し対策)
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

  // 067 #7: 期待枚数 (imagePath があれば paths.length) と実際に取得できた枚数を数える。
  // imagePath が非NULLなのに1枚も取得できなかった場合、テキストだけで approved が
  // 確定してしまう穴があった (fetchImageAsBase64 が null を返しても呼び出し側は
  // 黙って捨てるだけで、「画像0枚」を検出する分岐が存在しなかった)。
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
    // 067 #7: リトライ (計3回) してもなお1枚も取得できなかった場合は判定を実行せず
    // rejected で確定させる (fail-closed)。pending のままにすると「未審査の投稿を
    // 表示させ続ける」という攻撃者の目的を達成させてしまう
    // (index.ts:468-490 の ModerationRefusalError と同じ判断・同じ形を踏襲)。
    // 一部だけ取得できた場合 (fetchedImageCount > 0) はこの分岐に入らず従来どおり続行する。
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

  // v2投稿のユーザーテキストは画像への焼き込み (overlays) が主経路。生テキストを判定に渡さないと
  // AIには縮小画像内のピクセルとしてしか見えず、小さい文字は読めない (2026-07-25 ユーザー指摘で発覚)。
  // overlays jsonb: [{ text, imageIndex, ... }] (PostOverlayDTO / UserPost.swift と同形)
  const overlayTexts = (Array.isArray(row.overlays) ? row.overlays : [])
    .map((o: Record<string, unknown>) =>
      typeof o?.text === "string" ? o.text.trim() : ""
    )
    .filter((t: string) => t.length > 0);

  // 066 §4-2: DB側 (066マイグレーション) が overlays 合計3000字を検証するのは INSERT
  // 時点のみ。ここでの truncate は (a) その制約が将来緩んだ場合の保険 (b) 066適用前に
  // 作られた既存行 (未検証) の両方をカバーする最終防波堤
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
      // analysis フィールド追加 (2026-07-23) に合わせて増量。途中切れは JSON parse error になる
      700,
      config,
      `user_posts id=${id}`,
    );
  } catch (e) {
    if (e instanceof ModerationRefusalError) {
      // M28: refusal は「AIが判定自体を拒否するほど危険」というシグナルなので、
      // pending(表示継続)ではなく安全側のrejectedへ倒す
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
    throw e; // refusal以外は既存通り再スロー (外側でpending維持のままログのみ)
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
// user_comments ハンドラ (テキストのみ)
// ------------------------------------------------------------
async function handleUserComment(id: string): Promise<void> {
  // 監査C2対応: 判定対象テキストは DB から再取得する (payload は信用しない)
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
      // analysis フィールド追加 (2026-07-23) に合わせて増量
      500,
      config,
      `user_comments id=${id}`,
    );
  } catch (e) {
    if (e instanceof ModerationRefusalError) {
      // M28: refusal は「AIが判定自体を拒否するほど危険」というシグナルなので、
      // pending(表示継続)ではなく安全側のrejectedへ倒す
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
    throw e; // refusal以外は既存通り再スロー (外側でpending維持のままログのみ)
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
// user_reports ハンドラ (AIトリアージ、テキストのみ)
// ------------------------------------------------------------
async function handleUserReport(id: string): Promise<void> {
  // 監査C2対応: 通報内容も DB から再取得する。ai_severity が既に入っていれば再判定しない
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
    // 冪等ガード: トリアージ済み (user_reports に moderated_at は無いので ai_severity で判定)
    console.log(`↩️ トリアージ済みのためスキップ (id=${id})`);
    return;
  }

  const reason = (row.reason as string | null) ?? "";
  // 066 §4-2: user_reports.detail は DB側 CHECK 制約 (066マイグレーション) で1000字上限を
  // 追加したが、既存行 (適用前に作られたもの) は制約の対象外なのでここでも独立に切る
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
// エントリポイント
// ------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  // Database Webhook に設定した x-moderation-secret ヘッダと突き合わせる (監査C2)。
  // シークレット未設定 (secrets set 忘れ) も含めて不一致は全て 401 (fail-closed)
  const gotSecret = req.headers.get("x-moderation-secret");
  if (!MODERATION_WEBHOOK_SECRET || gotSecret !== MODERATION_WEBHOOK_SECRET) {
    // 値そのものはログに残さない (秘密)。長さだけで原因を切り分ける
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
    // パース自体に失敗した場合はリトライしても無意味なので 200 で終わる
    return new Response("ok", { status: 200 });
  }

  try {
    if (payload.type !== "INSERT") {
      // INSERT 以外は対象外 (UPDATE/DELETE は無視)
      return new Response("ignored", { status: 200 });
    }

    // payload からは table と record.id しか信用しない (監査C2)。
    // 本文/画像パス等は各ハンドラが service_role で DB から再取得する
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
    // 判定失敗時は moderation_status='pending' のまま (表示は継続)。
    // Webhook のリトライ嵐を避けるため常に 200 を返す。
    console.error(
      `モデレーション処理失敗 (table=${payload.table}):`,
      e instanceof Error ? e.message : e,
    );
  }

  return new Response("ok", { status: 200 });
});
