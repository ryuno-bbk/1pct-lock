//
//  AppealService.swift
//  AppBlocker
//
//  モデレーション結果 (rejected/flagged) への異議申し立て。
//  Supabase user_appeals テーブル + file_appeal RPC (039_moderation_notifications_appeals.sql が前提)。
//  作成は file_appeal RPC 経由のみ (直接 INSERT 不可)。解決 (承認/却下) は運営が SQL Editor で
//  手動 UPDATE する運用 (user_reports と同じ)。承認時は resolve_user_appeal トリガーが
//  対象の moderation_status を 'approved' に戻す (クライアント側では何もしなくてよい)。
//

import Foundation
import Supabase

/// 異議申し立ての対象 (投稿 or コメント)。ReportSheetView.Target と同じ流儀
enum AppealTarget: Identifiable, Hashable {
    case post(UUID)
    case comment(UUID)

    var id: String {
        switch self {
        case .post(let id):    return "post-\(id.uuidString)"
        case .comment(let id): return "comment-\(id.uuidString)"
        }
    }
}

/// user_appeals 1件分 (fetchAppeal の戻り値)
struct AppealRecord: Decodable {
    let id: UUID
    /// "pending" / "approved" / "rejected"
    let status: String
    let reason: String
    let resolutionNote: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case reason
        case resolutionNote = "resolution_note"
        case createdAt      = "created_at"
    }
}

@MainActor
final class AppealService {

    static let shared = AppealService()

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// 対象の既存申し立てを取得 (無ければ nil)。RLS (user_appeals_select_own) により
    /// auth.uid() = user_id の行のみ返るため、自分の申し立てしか見えない。
    /// single() は 0 行の時に PostgrestError になるため使わず、limit(1) + 配列の先頭で表現する
    /// (user_appeals_unique_post / user_appeals_unique_comment により対象1件につき最大1行)
    func fetchAppeal(for target: AppealTarget) async -> AppealRecord? {
        do {
            var query = client.from("user_appeals").select()
            switch target {
            case .post(let postId):
                query = query.eq("target_post_id", value: postId.uuidString)
            case .comment(let commentId):
                query = query.eq("target_comment_id", value: commentId.uuidString)
            }
            let records: [AppealRecord] = try await query
                .limit(1)
                .execute()
                .value
            return records.first
        } catch {
            print("⚠️ fetchAppeal failed for \(target): \(error)")
            return nil
        }
    }

    /// 指定した投稿群のうち、審査中 (pending) の申し立てが存在する投稿 id 集合を返す。
    /// 制限オーバーレイのピルを「異議申し立て中」に切り替えるための一括取得
    /// (2026-07-23 実機FB: 申し立て済みかどうかがフィード上で分からない)。
    /// RLS (user_appeals_select_own) により自分の申し立て行しか返らない。
    /// approved は resolve trigger で投稿自体が approved に戻りオーバーレイごと消えるため、
    /// pending のみ拾えばよい (却下済み申し立ては通常ラベルのまま)
    func fetchPendingAppealPostIds(for postIds: Set<UUID>) async -> Set<UUID> {
        guard !postIds.isEmpty else { return [] }
        struct Row: Decodable {
            let targetPostId: UUID?
            enum CodingKeys: String, CodingKey {
                case targetPostId = "target_post_id"
            }
        }
        do {
            let rows: [Row] = try await client
                .from("user_appeals")
                .select("target_post_id")
                .in("target_post_id", values: postIds.map(\.uuidString))
                .eq("status", value: "pending")
                .execute()
                .value
            return Set(rows.compactMap(\.targetPostId))
        } catch {
            print("⚠️ fetchPendingAppealPostIds failed: \(error)")
            return []
        }
    }

    // MARK: - 判定理由の取得 (2026-07-22 実機FB: 「ダメな理由の全文を見れるようにしたい」)

    /// 対象の現在のモデレーション判定 (status + AI 理由文)。
    /// 理由文は moderation_verdict jsonb の safety_reason (層1 rejected) / ethos_reason (層2 flagged) で、
    /// moderate-post Edge Function が判定と同一の Claude 呼び出しで生成している (追加コストなし)。
    /// RLS: 自分の投稿/コメント行は本人が SELECT 可能なので、本人向け表示にのみ使う
    struct ModerationInfo {
        let status: String?
        let reason: String?
    }

    func fetchModerationInfo(for target: AppealTarget) async -> ModerationInfo? {
        struct VerdictRow: Decodable {
            let safetyReason: String?
            let ethosReason: String?
            enum CodingKeys: String, CodingKey {
                case safetyReason = "safety_reason"
                case ethosReason  = "ethos_reason"
            }
        }
        struct Row: Decodable {
            let moderationStatus: String?
            let moderationVerdict: VerdictRow?
            enum CodingKeys: String, CodingKey {
                case moderationStatus = "moderation_status"
                case moderationVerdict = "moderation_verdict"
            }
        }

        let table: String
        let id: UUID
        switch target {
        case .post(let postId):       table = "user_posts";    id = postId
        case .comment(let commentId): table = "user_comments"; id = commentId
        }

        do {
            let rows: [Row] = try await client
                .from(table)
                .select("moderation_status, moderation_verdict")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else { return nil }
            // rejected は層1理由を優先、flagged は層2理由を優先 (欠けていれば他方でフォールバック)
            let reason: String?
            switch row.moderationStatus {
            case "rejected": reason = row.moderationVerdict?.safetyReason ?? row.moderationVerdict?.ethosReason
            case "flagged":  reason = row.moderationVerdict?.ethosReason ?? row.moderationVerdict?.safetyReason
            default:         reason = nil
            }
            return ModerationInfo(status: row.moderationStatus, reason: reason)
        } catch {
            print("⚠️ fetchModerationInfo failed for \(target): \(error)")
            return nil
        }
    }

    enum FileResult {
        case filed
        case alreadyFiled
        case failed
    }

    /// 異議申し立てを送信 (file_appeal RPC)。対象1件につき1回のみ (2回目以降は .alreadyFiled)。
    /// RPC 側 (SECURITY DEFINER) が所有権 (auth.uid() = 投稿/コメントの owner) と
    /// moderation_status ('rejected'/'flagged' のみ) を検証してから INSERT する
    func fileAppeal(target: AppealTarget, reason: String) async -> FileResult {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ fileAppeal ignored: not signed in")
            return .failed
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        // file_appeal(p_target_post_id, p_target_comment_id, p_reason) はいずれも DEFAULT の無い
        // 必須引数 (039 SQL 参照)。対象でない側のキーを省略すると PostgREST が引数不足エラーに
        // するため、両方のキーを常に送り、非対象側は AnyJSON.null で明示的に null を送る
        // (UserAuthService.updateBio 等と同じ「Encodable struct の nil キー省略を避ける」パターン)
        let postParam: AnyJSON
        let commentParam: AnyJSON
        switch target {
        case .post(let postId):
            postParam = .string(postId.uuidString)
            commentParam = .null
        case .comment(let commentId):
            postParam = .null
            commentParam = .string(commentId.uuidString)
        }

        let params: [String: AnyJSON] = [
            "p_target_post_id":    postParam,
            "p_target_comment_id": commentParam,
            "p_reason":            .string(trimmed)
        ]

        do {
            // file_appeal は作成した申し立ての uuid を返す (039)。AI二次審査の起動に使う
            let appealId: String = try await client.rpc("file_appeal", params: params).execute().value
            print("📝 Appeal filed for \(target)")

            // AI二次審査 (review-appeal Edge Function、2026-07-29) を fire-and-forget で起動。
            // 明白な誤判定なら数秒〜十数秒で自動 approved → 039 トリガーが投稿復活+通知まで実行。
            // 失敗しても申し立ては pending のまま運営キューに残るだけなので結果は待たない
            Task.detached {
                struct ReviewParams: Encodable { let appealId: String }
                do {
                    try await SupabaseManager.shared.client.functions.invoke(
                        "review-appeal",
                        options: .init(body: ReviewParams(appealId: appealId))
                    )
                    print("🤖 AI appeal review triggered (\(appealId))")
                } catch {
                    print("⚠️ AI appeal review trigger failed (pendingのまま運営キューへ): \(error)")
                }
            }
            return .filed
        } catch {
            // file_appeal は既存申し立てに対し user_appeals_unique_post/comment の unique_violation を
            // catch し RAISE EXCEPTION 'already appealed' で再送出する (039 SQL 参照)。
            // PostgrestError.message にその文言が含まれるかで判定する (SQLSTATE ではなく文言判定なのは
            // RAISE EXCEPTION がカスタムメッセージのみで SQLSTATE は汎用の P0001 になるため)
            if let pgError = error as? PostgrestError, pgError.message.contains("already appealed") {
                print("ℹ️ Appeal already filed for \(target)")
                return .alreadyFiled
            }
            print("⚠️ fileAppeal failed for \(target): \(error)")
            return .failed
        }
    }
}
