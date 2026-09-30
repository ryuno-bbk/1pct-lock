//
//  WeeklyReportView.swift
//  AppBlocker
//
//  Weekly report (equivalent to Opal's Focus Report).
//  The content just draws get_weekly_report from 080_weekly_report.sql as is.
//
//  ⚠️⚠️ Wording is waiting for the user's review. All Japanese/English text on this screen is a
//        placeholder. Claude does not invent the brand voice (feedback_brand_voice_no_invented_copy).
//
//  Design notes:
//    - ❌ A per-app breakdown is not possible. By design, the Screen Time API does not pass measured
//      values to the app itself.
//      Instead show "by weekday" and "by mode" (both can be built from block_sessions alone).
//    - 🔴 Do not use scaleEffect (it caused 10fps on a real device before). Bars grow with
//      frame(height:).
//    - 🔴 The fetched result is local state of this View. Writing it back to a shared singleton makes
//      multiple reports opened from history overwrite each other.
//

import SwiftUI

struct WeeklyReportView: View {

    /// How many weeks ago the report is for. 0 = this week in progress, 1 = last week (default)
    var weekOffset: Int = 1

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var report: WeeklyReport?
    @State private var isLoading = true
    /// Tap on "今週の順位" ("Your rank this week") → all-time ranking (2026-09-05)
    @State private var showRanking = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }
    private var isJa: Bool { lang == .japanese }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(AppColors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report, report.hasHistory {
                content(report)
            } else {
                emptyView
            }
        }
        .navigationTitle(isJa ? "週次レポート" : "Weekly Report")  // Wording is waiting for the user's review
        .navigationBarTitleDisplayMode(.inline)
        // This is pushed from screens whose parent (settings / notification list) has
        // toolbarBackground(.hidden), so set an opaque bar explicitly here too. Required for every screen
        // pushed onto this NavigationStack (2026-08-04)
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $showRanking) {
            RankingView()
        }
        .task {
            report = await WeeklyReportService.shared.fetchReport(weekOffset: weekOffset)
            isLoading = false
        }
    }

    // MARK: - Body

    private func content(_ r: WeeklyReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard(r)
                if r.topPercent != nil {
                    Button { showRanking = true } label: { rankCard(r) }
                        .buttonStyle(PlainButtonStyle())
                }
                dayChartCard(r)
                if !r.byMode.isEmpty { modeCard(r) }
                totalsCard(r)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Heading + lock time this week

    private func heroCard(_ r: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(weekRangeText(r))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)

                if r.isCurrentWeek {
                    Text(isJa ? "途中経過" : "In progress")  // Wording is waiting for the user's review
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppColors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(AppColors.secondaryBackground)
                        )
                }
            }

            Text(r.seconds.lockDurationText)
                .font(Self.brandFont(46))
                .foregroundColor(AppColors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(isJa ? "今週ロックした時間" : "Locked this week")  // Wording is waiting for the user's review
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)

            deltaRow(r)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    /// 🔴 How to show the change vs last week.
    /// Real production data includes **+6603.1%** (2 hours last week → 133 hours this week).
    /// The number is correct but looks broken on screen, so when the base is small / the change is
    /// extreme, drop the % and compare actual values (decided by WeeklyReport.showsDeltaPercent).
    @ViewBuilder
    private func deltaRow(_ r: WeeklyReport) -> some View {
        if !r.hasComparison {
            Text(isJa ? "先週の記録はありません" : "No record last week")  // Wording is waiting for the user's review
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        } else if r.showsDeltaPercent, let d = r.deltaPercent {
            let up = d >= 0
            HStack(spacing: 6) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                Text(String(format: "%@%.0f%%", up ? "+" : "", d))
                    .font(.system(size: 15, weight: .bold))
                Text(isJa ? "先週比" : "vs last week")  // Wording is waiting for the user's review
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
            .foregroundColor(up ? AppColors.success : AppColors.textSecondary)
        } else {
            // Show actual values side by side. Fallback for cases where % looks broken
            Text(isJa
                 ? "先週 \(r.prevSeconds.lockDurationText) → 今週 \(r.seconds.lockDurationText)"
                 : "\(r.prevSeconds.lockDurationText) last week → \(r.seconds.lockDurationText)")  // Wording is waiting for the user's review
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - Top percentile

    /// 🔴 In weeks where the pool is below the threshold, the server does not return topPercent (fixes
    ///    the problem of an embarrassing "上位50%" ("Top 50%") showing). Only weeks with a big enough
    ///    pool reach here.
    private func rankCard(_ r: WeeklyReport) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isJa ? "今週の順位" : "Your rank this week")  // Wording is waiting for the user's review
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isJa ? "上位 \(topPercentText(r))%" : "Top \(topPercentText(r))%")  // Wording is waiting for the user's review
                        .font(Self.brandFont(26))
                        .foregroundColor(AppColors.textPrimary)

                    if let rank = r.rank {
                        Text(isJa ? "\(r.activeUsers)人中 \(rank)位" : "\(rank) of \(r.activeUsers)")  // Wording is waiting for the user's review
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary)
                    }
                }
            }
            Spacer()
            // 🔴 This rank is for "that week", but the destination is the "all-time" ranking.
            //    The number changes, so show a chevron so the user knows before tapping
            //    (the destination screen title also says "累計ランキング" ("All-time ranking") again)
            HStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 20))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(AppColors.textTertiary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    /// Do not round away values like "上位 0.4%" ("Top 0.4%"), and do not show the .0 in "上位 12.0%"
    /// ("Top 12.0%")
    private func topPercentText(_ r: WeeklyReport) -> String {
        guard let p = r.topPercent else { return "-" }
        return p < 10 ? String(format: "%.1f", p) : String(format: "%.0f", p)
    }

    // MARK: - By weekday

    private func dayChartCard(_ r: WeeklyReport) -> some View {
        let maxValue = max(r.days.max() ?? 0, 1)
        let barArea: CGFloat = 108

        return VStack(alignment: .leading, spacing: 14) {
            Text(isJa ? "曜日別" : "By day")  // Wording is waiting for the user's review
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(r.days.enumerated()), id: \.offset) { idx, secs in
                    VStack(spacing: 8) {
                        // 🔴 Do not use scaleEffect. Set the height directly
                        RoundedRectangle(cornerRadius: 5)
                            .fill(secs > 0 ? AppColors.textPrimary : AppColors.secondaryBackground)
                            .frame(height: secs > 0
                                   ? max(6, barArea * CGFloat(secs) / CGFloat(maxValue))
                                   : 3)
                        Text(weekdayLabel(idx))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: barArea + 24, alignment: .bottom)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    /// Weeks start on Monday (the server's days[0] is Monday)
    private func weekdayLabel(_ idx: Int) -> String {
        let ja = ["月", "火", "水", "木", "金", "土", "日"]
        let en = ["M", "T", "W", "T", "F", "S", "S"]
        let a = isJa ? ja : en
        return idx >= 0 && idx < a.count ? a[idx] : ""
    }

    // MARK: - By mode

    private func modeCard(_ r: WeeklyReport) -> some View {
        // Fix the display order (leaving it to dictionary order changes the order every time)
        let order: [(key: String, icon: String, ja: String, en: String)] = [
            ("timer",    "timer",            "タイマー",   "Timer"),
            ("schedule", "calendar",         "スケジュール", "Schedule"),
            ("location", "location.fill",    "位置",       "Location")
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(isJa ? "ロックの種類" : "Lock type")  // Wording is waiting for the user's review
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            ForEach(order.filter { (r.byMode[$0.key] ?? 0) > 0 }, id: \.key) { m in
                HStack(spacing: 10) {
                    Image(systemName: m.icon)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                        .frame(width: 20)
                    Text(isJa ? m.ja : m.en)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    Text((r.byMode[m.key] ?? 0).lockDurationText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    // MARK: - Totals and projection

    private func totalsCard(_ r: WeeklyReport) -> some View {
        VStack(spacing: 14) {
            totalRow(label: isJa ? "これまでの累計" : "All-time total",  // Wording is waiting for the user's review
                     value: r.totalSeconds.lockDurationText)

            Divider().overlay(AppColors.secondaryBackground)

            totalRow(label: isJa ? "今週のセッション" : "Sessions this week",  // Wording is waiting for the user's review
                     value: "\(r.sessions)")

            // 🔴 The projection is "average of the last 4 weeks × 52". Weeks before the first session are not
            //    included in the average (including them would make the projection for new users 1/4 of their
            //    actual pace)
            if r.avg4Seconds > 0 {
                Divider().overlay(AppColors.secondaryBackground)
                totalRow(label: isJa ? "このペースで1年" : "A year at this pace",  // Wording is waiting for the user's review
                         value: "\(r.projectionYearSeconds / 3600)h")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    private func totalRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary)
            Text(isJa ? "まだレポートを出せません" : "No report yet")  // Wording is waiting for the user's review
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
            Text(isJa ? "一度ロックを使うと、翌週から届きます" : "Use a lock once and your report starts next week")  // Wording is waiting for the user's review
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - Parts

    private func weekRangeText(_ r: WeeklyReport) -> String {
        guard let s = r.weekStart, let e = r.weekEnd else { return r.weekStartRaw }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "M/d"
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }

    /// Do not let a font name missing on the device silently fall back (lesson from 2026-07-15, when
    /// Didot-Bold was not on the real device. Same style as QuoteCardView.installed)
    static func brandFont(_ size: CGFloat) -> Font {
        UIFont(name: "Montserrat-BlackItalic", size: size) != nil
            ? .custom("Montserrat-BlackItalic", size: size)
            : .system(size: size, weight: .heavy)
    }
}

#Preview {
    NavigationStack { WeeklyReportView() }
}
