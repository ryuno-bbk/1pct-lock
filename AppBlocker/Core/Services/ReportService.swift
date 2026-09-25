//
//  ReportService.swift
//  AppBlocker
//
//  投稿/ユーザー/名言の通報送信 (Supabase user_reports)
//

import Foundation
import Supabase

enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case nudity
    case violence
    /// 067 #9: エトス専用の通報理由 (「このアプリの趣旨に合わない」)。
    /// rawValue は 067_moderation_hardening.sql の user_reports_reason_check CHECK 制約と
    /// 一致させる必要がある (off_topic)。ReportSheetView は ForEach(ReportReason.allCases)
    /// で列挙しているため、追加するだけで選択肢に自然に出る (UI側の変更は不要)
    case offTopic = "off_topic"
    case other

    var id: String { rawValue }

    func displayName(_ lang: AppLanguage) -> String {
        switch self {
        case .spam:       return L.moderationReportReasonSpam(lang)
        case .harassment: return L.moderationReportReasonHarassment(lang)
        case .hate:       return L.moderationReportReasonHate(lang)
        case .nudity:     return L.moderationReportReasonNudity(lang)
        case .violence:   return L.moderationReportReasonViolence(lang)
        case .offTopic:   return L.moderationReportReasonOffTopic(lang)
        case .other:      return L.moderationReportReasonOther(lang)
        }
    }
}

@MainActor
final class ReportService {

    static let shared = ReportService()

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// 投稿を通報
    func reportPost(postId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: postId, targetUserId: nil, targetQuoteId: nil, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// ユーザーを通報 (プロフィール経由)
    func reportUser(userId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: nil, targetUserId: userId, targetQuoteId: nil, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// 公式名言を通報
    func reportQuote(quoteId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: nil, targetUserId: nil, targetQuoteId: quoteId, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// コメントを通報 (H9)。target_comment_id 列は 042_comment_reports_threshold_flag.sql が前提
    /// (未適用の DB では INSERT がカラム不存在エラーになる)
    func reportComment(commentId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: nil, targetUserId: nil, targetQuoteId: nil, targetCommentId: commentId, reason: reason, detail: detail)
    }

    private func submit(
        targetPostId: UUID?,
        targetUserId: UUID?,
        targetQuoteId: UUID?,
        targetCommentId: UUID?,
        reason: ReportReason,
        detail: String?
    ) async -> Bool {
        guard let me = UserAuthService.shared.userId else {
            print("⚠️ report ignored: not signed in")
            return false
        }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDetail: String? = (trimmedDetail?.isEmpty ?? true) ? nil : trimmedDetail

        struct InsertRow: Encodable {
            let reporter_id: String
            let target_post_id: String?
            let target_user_id: String?
            let target_quote_id: String?
            let target_comment_id: String?
            let reason: String
            let detail: String?
        }

        let row = InsertRow(
            reporter_id: me.uuidString,
            target_post_id: targetPostId?.uuidString,
            target_user_id: targetUserId?.uuidString,
            target_quote_id: targetQuoteId?.uuidString,
            target_comment_id: targetCommentId?.uuidString,
            reason: reason.rawValue,
            detail: cleanedDetail
        )

        do {
            try await client
                .from("user_reports")
                .insert(row)
                .execute()
            print("🚩 Report submitted: reason=\(reason.rawValue)")
            return true
        } catch {
            // 重複通報 (UNIQUE 制約) はサイレントに成功扱い (UX 改善)。
            // M14: 制約名の文字列一致は 015_security_audit.sql での改名 (user_reports_unique_per_post/quote →
            // 部分ユニークインデックス user_reports_reporter_{post,quote,user}_unique) で追従漏れが起きた実績があり脆い。
            // PostgrestError の SQLSTATE (unique_violation = "23505") で判定する方が制約名変更に影響されず堅牢
            // (BlockSessionTracker.isRowRejection と同じ判定方式)
            if let pgError = error as? PostgrestError, pgError.code == "23505" {
                print("ℹ️ Duplicate report ignored")
                return true
            }
            print("⚠️ Report failed: \(error)")
            return false
        }
    }
}
