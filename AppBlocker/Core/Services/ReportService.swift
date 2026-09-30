//
//  ReportService.swift
//  AppBlocker
//
//  Sending reports on posts/users/quotes (Supabase user_reports)
//

import Foundation
import Supabase

enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case nudity
    case violence
    /// 067 #9: ethos-specific report reason ("このアプリの趣旨に合わない" ("Doesn't fit the purpose
    /// of this app")). The rawValue must match the user_reports_reason_check CHECK constraint in
    /// 067_moderation_hardening.sql (off_topic). ReportSheetView lists them with
    /// ForEach(ReportReason.allCases), so just adding it makes it appear as an option (no UI change
    /// needed)
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

    /// Report a post
    func reportPost(postId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: postId, targetUserId: nil, targetQuoteId: nil, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// Report a user (from the profile)
    func reportUser(userId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: nil, targetUserId: userId, targetQuoteId: nil, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// Report an official quote
    func reportQuote(quoteId: UUID, reason: ReportReason, detail: String?) async -> Bool {
        await submit(targetPostId: nil, targetUserId: nil, targetQuoteId: quoteId, targetCommentId: nil, reason: reason, detail: detail)
    }

    /// Report a comment (H9). The target_comment_id column requires
    /// 042_comment_reports_threshold_flag.sql (on a DB without it, the INSERT fails with a
    /// column-does-not-exist error)
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
            // Duplicate reports (UNIQUE constraint) are silently treated as success (UX improvement).
            // M14: matching on the constraint name string is fragile; it already failed to keep up once, when
            // 015_security_audit.sql renamed the constraints (user_reports_unique_per_post/quote →
            // partial unique indexes user_reports_reporter_{post,quote,user}_unique).
            // Checking the SQLSTATE of PostgrestError (unique_violation = "23505") is robust against constraint
            // name changes (same check as BlockSessionTracker.isRowRejection)
            if let pgError = error as? PostgrestError, pgError.code == "23505" {
                print("ℹ️ Duplicate report ignored")
                return true
            }
            print("⚠️ Report failed: \(error)")
            return false
        }
    }
}
