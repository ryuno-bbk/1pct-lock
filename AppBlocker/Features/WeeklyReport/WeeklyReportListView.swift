//
//  WeeklyReportListView.swift
//  AppBlocker
//
//  Settings → Weekly report. Lists past reports newest first, tap to open.
//
//  🔴 Reports are not stored. What is listed here is the result of re-aggregating block_sessions, and
//     tapping one fetches the same week again with weekOffset (it is not a stored static copy).
//
//  ⚠️⚠️ Copy waiting for user review
//

import SwiftUI

struct WeeklyReportListView: View {

    @ObservedObject private var service = WeeklyReportService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }
    private var isJa: Bool { lang == .japanese }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if service.isLoadingHistory && service.history.isEmpty {
                ProgressView()
                    .tint(AppColors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.history.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(service.history) { row in
                            NavigationLink {
                                WeeklyReportView(weekOffset: row.weekOffset)
                            } label: {
                                rowLabel(row)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(isJa ? "週次レポート" : "Weekly Reports")  // Copy waiting for user review
        .navigationBarTitleDisplayMode(.inline)
        // It is pushed from Settings, so the same header see-through fix as SettingsListView is applied
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await service.loadHistory() }
        .refreshable { await service.loadHistory() }
    }

    private func rowLabel(_ row: WeeklyReportSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(weekRangeText(row))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text(isJa ? "\(row.sessions)回" : "\(row.sessions) sessions")  // Copy waiting for user review
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
            }
            Spacer()
            Text(row.seconds.lockDurationText)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(row.seconds > 0 ? AppColors.textPrimary : AppColors.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textTertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary)
            Text(isJa ? "まだレポートがありません" : "No reports yet")  // Copy waiting for user review
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
            Text(isJa ? "一度ロックを使うと、翌週から届きます" : "Use a lock once and your report starts next week")  // Copy waiting for user review
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func weekRangeText(_ row: WeeklyReportSummary) -> String {
        guard let s = row.weekStart, let e = row.weekEnd else { return row.weekStartRaw }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "M/d"
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }
}

#Preview {
    NavigationStack { WeeklyReportListView() }
}
