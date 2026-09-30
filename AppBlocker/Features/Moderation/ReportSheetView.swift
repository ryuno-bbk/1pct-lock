//
//  ReportSheetView.swift
//  AppBlocker
//
//  Report modal for posts/users/quotes
//

import SwiftUI

struct ReportSheetView: View {

    enum Target: Identifiable, Hashable {
        case post(UUID)
        case user(UUID)
        case quote(UUID)
        case comment(UUID)

        var id: String {
            switch self {
            case .post(let id):    return "post-\(id.uuidString)"
            case .user(let id):    return "user-\(id.uuidString)"
            case .quote(let id):   return "quote-\(id.uuidString)"
            case .comment(let id): return "comment-\(id.uuidString)"
            }
        }
    }

    let target: Target
    var onSubmitted: () -> Void = {}

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var selectedReason: ReportReason = .spam
    @State private var detail: String = ""
    @State private var isSubmitting: Bool = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var navigationTitleText: String {
        switch target {
        case .post, .quote:
            return L.moderationReportTitle(lang)
        case .comment:
            return lang == .japanese ? "コメントを通報" : "Report Comment"  // Copy waiting for user review
        case .user:
            return lang == .japanese ? "ユーザーを通報" : "Report User"  // Copy waiting for user review
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L.moderationReportReason(lang)) {
                    ForEach(ReportReason.allCases) { reason in
                        Button {
                            selectedReason = reason
                        } label: {
                            HStack {
                                Text(reason.displayName(lang))
                                    .foregroundColor(AppColors.textPrimary)
                                Spacer()
                                if reason == selectedReason {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(AppColors.accent)
                                }
                            }
                        }
                    }
                }

                Section(L.moderationReportDetail(lang)) {
                    TextField("", text: $detail, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L.moderationReportCancel(lang)) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L.moderationReportSubmit(lang)) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        let ok: Bool
        switch target {
        case .post(let id):
            ok = await ReportService.shared.reportPost(postId: id, reason: selectedReason, detail: detail)
        case .user(let id):
            ok = await ReportService.shared.reportUser(userId: id, reason: selectedReason, detail: detail)
        case .quote(let id):
            ok = await ReportService.shared.reportQuote(quoteId: id, reason: selectedReason, detail: detail)
        case .comment(let id):
            ok = await ReportService.shared.reportComment(commentId: id, reason: selectedReason, detail: detail)
        }
        isSubmitting = false
        if ok {
            onSubmitted()
            dismiss()
        }
    }
}
