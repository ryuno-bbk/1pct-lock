//
//  AppealSheetView.swift
//  AppBlocker
//
//  モデレーション結果 (rejected/flagged) への異議申し立てモーダル。
//  ReportSheetView と同じ NavigationStack + Form + toolbar キャンセル/送信の構造。
//  対象に既存の申し立てがあれば「状態表示モード」、無ければ「入力モード」を出す。
//

import SwiftUI

struct AppealSheetView: View {

    let target: AppealTarget
    var onFiled: () -> Void = {}

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var existingAppeal: AppealRecord?
    @State private var isLoadingExisting: Bool = true
    /// AI 判定理由の全文 (2026-07-22 実機FB: 通知プレビューの2行では全文が読めないため、
    /// このシートを「判定理由の全文+申し立て」のハブにする)
    @State private var moderationReason: String?
    @State private var reasonText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    /// この画面を開いている間に自分で送信が成功した直後 (状態表示モードとは別の一時的な完了表示)
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
            .navigationTitle(lang == .japanese ? "異議申し立て" : "Appeal")  // 文言はユーザー添削待ち
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
                        Button(lang == .japanese ? "閉じる" : "Close") { dismiss() }  // 文言はユーザー添削待ち
                    }
                }
            }
        }
        .task {
            // 申し立て状態と判定理由は独立なので並列に取得する
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

    /// AI 判定理由の全文セクション (入力/状態表示の両モード共通)
    @ViewBuilder
    private var moderationReasonSection: some View {
        if let moderationReason, !moderationReason.isEmpty {
            Section(lang == .japanese ? "判定理由" : "Reason for the decision") {  // 文言はユーザー添削待ち
                Text(moderationReason)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    private var inputForm: some View {
        Form {
            moderationReasonSection

            // 2026-07-25 実機FB: 「判定理由」ボックスと同じ見た目の箱が2つ並ぶ違和感 →
            // 入力欄の説明は入力セクションのヘッダー (非ボックスの小さめキャプション) に格下げする
            Section {
                TextField("", text: $reasonText, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text(lang == .japanese
                    ? "この判定に心当たりがない場合は、理由を添えて再審査を申請できます"
                    : "If you believe this was a mistake, you can request a review")  // 文言はユーザー添削待ち
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

            Section(lang == .japanese ? "送信した理由" : "Reason submitted") {  // 文言はユーザー添削待ち
                Text(record.reason)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
            }

            if let note = record.resolutionNote, !note.isEmpty {
                Section(lang == .japanese ? "運営からのコメント" : "Note from the team") {  // 文言はユーザー添削待ち
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
            }

            Section {
                Text(lang == .japanese ? "異議申し立てはコンテンツごとに1回できます" : "You can appeal each piece of content once")  // 文言はユーザー添削待ち
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
            Text(lang == .japanese ? "申し立てを受け付けました" : "Your appeal has been submitted")  // 文言はユーザー添削待ち
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
        case "pending":  return lang == .japanese ? "審査中です" : "Under review"  // 文言はユーザー添削待ち
        case "approved": return lang == .japanese ? "承認されました" : "Approved"  // 文言はユーザー添削待ち
        case "rejected": return lang == .japanese ? "承認されませんでした" : "Not approved"  // 文言はユーザー添削待ち
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
            // 別セッション等で既に送信済みだった。実際の状態 (pending/approved/rejected) を
            // 再取得して状態表示モードへ切り替える (justFiled のような一時完了表示にはしない)
            existingAppeal = await AppealService.shared.fetchAppeal(for: target)
            isSubmitting = false
        case .failed:
            isSubmitting = false
            submitError = lang == .japanese
                ? "送信できませんでした。時間をおいて再試行してください"
                : "Couldn't submit. Please try again later"  // 文言はユーザー添削待ち
        }
    }
}
