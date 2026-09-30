//
//  AppealSheetView.swift
//  AppBlocker
//
//  Appeal modal for a moderation result (rejected/flagged).
//  Same structure as ReportSheetView: NavigationStack + Form + toolbar cancel/submit.
//  If the target already has an appeal, show "status mode", otherwise "input mode".
//

import SwiftUI

struct AppealSheetView: View {

    let target: AppealTarget
    var onFiled: () -> Void = {}

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var existingAppeal: AppealRecord?
    @State private var isLoadingExisting: Bool = true
    /// Full text of the AI decision reason (2026-07-22 real-device feedback: the 2 lines of the notification
    /// preview cannot show the full text, so this sheet is the hub for "full decision reason + appeal")
    @State private var moderationReason: String?
    @State private var reasonText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    /// Right after the user successfully submitted while this screen is open (a temporary done state,
    /// separate from status mode)
    @State private var justFiled: Bool = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private enum ViewMode {
        case loading
        case input
        case status(AppealRecord)
        case filed
    }

    private var mode: ViewMode {
        if justFiled { return .filed }
        if let existingAppeal { return .status(existingAppeal) }
        if isLoadingExisting { return .loading }
        return .input
    }

    private var trimmedReason: String {
        reasonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isInputMode: Bool {
        if case .input = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .loading:
                    loadingView
                case .input:
                    inputForm
                case .status(let record):
                    statusForm(record)
                case .filed:
                    filedView
                }
            }
            .navigationTitle(lang == .japanese ? "異議申し立て" : "Appeal")  // Copy waiting for user review
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isInputMode {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L.moderationReportCancel(lang)) { dismiss() }
                            .disabled(isSubmitting)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L.moderationReportSubmit(lang)) {
                            Task { await submit() }
                        }
                        .disabled(isSubmitting || trimmedReason.isEmpty)
                    }
                }
                if !isInputMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(lang == .japanese ? "閉じる" : "Close") { dismiss() }  // Copy waiting for user review
                    }
                }
            }
        }
        .task {
            // The appeal state and the decision reason are independent, so they are fetched in parallel
            async let appealTask = AppealService.shared.fetchAppeal(for: target)
            async let infoTask = AppealService.shared.fetchModerationInfo(for: target)
            existingAppeal = await appealTask
            moderationReason = await infoTask?.reason
            isLoadingExisting = false
        }
    }

    // MARK: - Modes

    private var loadingView: some View {
        ProgressView()
            .tint(AppColors.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background)
    }

    /// Section with the full text of the AI decision reason (shared by input and status modes)
    @ViewBuilder
    private var moderationReasonSection: some View {
        if let moderationReason, !moderationReason.isEmpty {
            Section(lang == .japanese ? "判定理由" : "Reason for the decision") {  // Copy waiting for user review
                Text(moderationReason)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    private var inputForm: some View {
        Form {
            moderationReasonSection

            // 2026-07-25 real-device feedback: two boxes that look the same as the "判定理由" ("Reason for the
            // decision") box side by side felt wrong →
            // the explanation of the input field is demoted to the input section header (a smaller caption, not a
            // box)
            Section {
                TextField("", text: $reasonText, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text(lang == .japanese
                    ? "この判定に心当たりがない場合は、理由を添えて再審査を申請できます"
                    : "If you believe this was a mistake, you can request a review")  // Copy waiting for user review
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
                    .textCase(nil)
            }

            if let submitError {
                Section {
                    Text(submitError)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                }
            }
        }
    }

    private func statusForm(_ record: AppealRecord) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: statusIconName(record.status))
                        .foregroundColor(AppColors.textPrimary)
                    Text(statusLabel(record.status))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                }
                .padding(.vertical, 4)
            }

            moderationReasonSection

            Section(lang == .japanese ? "送信した理由" : "Reason submitted") {  // Copy waiting for user review
                Text(record.reason)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
            }

            if let note = record.resolutionNote, !note.isEmpty {
                Section(lang == .japanese ? "運営からのコメント" : "Note from the team") {  // Copy waiting for user review
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
            }

            Section {
                Text(lang == .japanese ? "異議申し立てはコンテンツごとに1回できます" : "You can appeal each piece of content once")  // Copy waiting for user review
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }

    private var filedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
            Text(lang == .japanese ? "申し立てを受け付けました" : "Your appeal has been submitted")  // Copy waiting for user review
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }

    // MARK: - Status helpers

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "pending":  return lang == .japanese ? "審査中です" : "Under review"  // Copy waiting for user review
        case "approved": return lang == .japanese ? "承認されました" : "Approved"  // Copy waiting for user review
        case "rejected": return lang == .japanese ? "承認されませんでした" : "Not approved"  // Copy waiting for user review
        default:         return status
        }
    }

    private func statusIconName(_ status: String) -> String {
        switch status {
        case "approved": return "checkmark.seal.fill"
        case "rejected": return "xmark.seal.fill"
        default:         return "clock.fill"
        }
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        guard !trimmedReason.isEmpty else { return }
        isSubmitting = true
        submitError = nil
        let result = await AppealService.shared.fileAppeal(target: target, reason: trimmedReason)
        switch result {
        case .filed:
            isSubmitting = false
            justFiled = true
            onFiled()
        case .alreadyFiled:
            // It had already been submitted, e.g. in another session. Fetch the actual state
            // (pending/approved/rejected) again and switch to status mode (not a temporary done state like
            // justFiled)
            existingAppeal = await AppealService.shared.fetchAppeal(for: target)
            isSubmitting = false
        case .failed:
            isSubmitting = false
            submitError = lang == .japanese
                ? "送信できませんでした。時間をおいて再試行してください"
                : "Couldn't submit. Please try again later"  // Copy waiting for user review
        }
    }
}
