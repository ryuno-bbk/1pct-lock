//
//  WeeklyReportView.swift
//  AppBlocker
//
//  週次レポート (Opal の Focus Report 相当)。
//  中身は 080_weekly_report.sql の get_weekly_report をそのまま描くだけ。
//
//  ⚠️⚠️ 文言はユーザー添削待ち — この画面の日本語/英語は全て仮置き。
//        ブランドの声は Claude が発明しない (feedback_brand_voice_no_invented_copy)。
//
//  設計メモ:
//    - ❌ アプリ別の内訳は出せない。Screen Time API が実測値をアプリ本体に渡さない仕様。
//      代わりに「曜日別」と「モード別」を出す (どちらも block_sessions だけで作れる)。
//    - 🔴 scaleEffect は使わない (実機 10fps の前例あり)。棒グラフは frame(height:) で伸ばす。
//    - 🔴 取得結果はこの View のローカル state。共有シングルトンに書き戻すと
//      履歴から複数枚開いたときに互いを上書きする。
//

import SwiftUI

struct WeeklyReportView: View {

    /// 何週前のレポートか。0 = 進行中の今週、1 = 先週 (既定)
    var weekOffset: Int = 1

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var report: WeeklyReport?
    @State private var isLoading = true
    /// 「今週の順位」タップ → 累計ランキング (2026-09-05)
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
        .navigationTitle(isJa ? "週次レポート" : "Weekly Report")  // 文言はユーザー添削待ち
        .navigationBarTitleDisplayMode(.inline)
        // 親 (設定 / 通知一覧) が toolbarBackground(.hidden) を持つ画面から push されるため、
        // ここでも不透明バーを明示する。この NavigationStack に push する画面は必須 (2026-08-04)
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

    // MARK: - 本体

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

    // MARK: - 見出し + 今週のロック時間

    private func heroCard(_ r: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(weekRangeText(r))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)

                if r.isCurrentWeek {
                    Text(isJa ? "途中経過" : "In progress")  // 文言はユーザー添削待ち
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

            Text(isJa ? "今週ロックした時間" : "Locked this week")  // 文言はユーザー添削待ち
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)

            deltaRow(r)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppColors.cardBackground))
    }

    /// 🔴 先週比の出し方。
    /// 本番実データに **+6603.1%** (先週2時間 → 今週133時間) が存在する。
    /// 数値は正しいが画面に出すと壊れて見えるので、母数が小さい/変化が極端なときは
    /// % をやめて実数の比較に落とす (判定は WeeklyReport.showsDeltaPercent)。
    @ViewBuilder
    private func deltaRow(_ r: WeeklyReport) -> some View {
        if !r.hasComparison {
            Text(isJa ? "先週の記録はありません" : "No record last week")  // 文言はユーザー添削待ち
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        } else if r.showsDeltaPercent, let d = r.deltaPercent {
            let up = d >= 0
            HStack(spacing: 6) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                Text(String(format: "%@%.0f%%", up ? "+" : "", d))
                    .font(.system(size: 15, weight: .bold))
                Text(isJa ? "先週比" : "vs last week")  // 文言はユーザー添削待ち
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
            .foregroundColor(up ? AppColors.success : AppColors.textSecondary)
        } else {
            // 実数で並べる。%だと壊れて見えるケースのフォールバック
            Text(isJa
                 ? "先週 \(r.prevSeconds.lockDurationText) → 今週 \(r.seconds.lockDurationText)"
                 : "\(r.prevSeconds.lockDurationText) last week → \(r.seconds.lockDurationText)")  // 文言はユーザー添削待ち
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - 上位%

    /// 🔴 母数が閾値未満の週はサーバーが topPercent を返さない (「上位50%」が出て
    ///    格好悪い問題への対処)。ここに来るのは母数が足りた週だけ。
    private func rankCard(_ r: WeeklyReport) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isJa ? "今週の順位" : "Your rank this week")  // 文言はユーザー添削待ち
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isJa ? "上位 \(topPercentText(r))%" : "Top \(topPercentText(r))%")  // 文言はユーザー添削待ち
                        .font(Self.brandFont(26))
                        .foregroundColor(AppColors.textPrimary)

                    if let rank = r.rank {
                        Text(isJa ? "\(r.activeUsers)人中 \(rank)位" : "\(rank) of \(r.activeUsers)")  // 文言はユーザー添削待ち
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary)
                    }
                }
            }
            Spacer()
            // 🔴 この順位は「その週」のもので、飛び先は「累計」ランキング。
            //    数字が変わるので、押す前にそれが分かるよう chevron を出す
            //    (飛び先の画面タイトルも「累計ランキング」で再度明示している)
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

    /// 「上位 0.4%」のような値を潰さず、かつ「上位 12.0%」の .0 は出さない
    private func topPercentText(_ r: WeeklyReport) -> String {
        guard let p = r.topPercent else { return "-" }
        return p < 10 ? String(format: "%.1f", p) : String(format: "%.0f", p)
    }

    // MARK: - 曜日別

    private func dayChartCard(_ r: WeeklyReport) -> some View {
        let maxValue = max(r.days.max() ?? 0, 1)
        let barArea: CGFloat = 108

        return VStack(alignment: .leading, spacing: 14) {
            Text(isJa ? "曜日別" : "By day")  // 文言はユーザー添削待ち
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(r.days.enumerated()), id: \.offset) { idx, secs in
                    VStack(spacing: 8) {
                        // 🔴 scaleEffect は使わない。高さを直接与える
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

    /// 月曜始まり (サーバーの days[0] が月曜)
    private func weekdayLabel(_ idx: Int) -> String {
        let ja = ["月", "火", "水", "木", "金", "土", "日"]
        let en = ["M", "T", "W", "T", "F", "S", "S"]
        let a = isJa ? ja : en
        return idx >= 0 && idx < a.count ? a[idx] : ""
    }

    // MARK: - モード別

    private func modeCard(_ r: WeeklyReport) -> some View {
        // 表示順を固定する (辞書の順序に任せると毎回並びが変わる)
        let order: [(key: String, icon: String, ja: String, en: String)] = [
            ("timer",    "timer",            "タイマー",   "Timer"),
            ("schedule", "calendar",         "スケジュール", "Schedule"),
            ("location", "location.fill",    "位置",       "Location")
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(isJa ? "ロックの種類" : "Lock type")  // 文言はユーザー添削待ち
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

    // MARK: - 累計と予測

    private func totalsCard(_ r: WeeklyReport) -> some View {
        VStack(spacing: 14) {
            totalRow(label: isJa ? "これまでの累計" : "All-time total",  // 文言はユーザー添削待ち
                     value: r.totalSeconds.lockDurationText)

            Divider().overlay(AppColors.secondaryBackground)

            totalRow(label: isJa ? "今週のセッション" : "Sessions this week",  // 文言はユーザー添削待ち
                     value: "\(r.sessions)")

            // 🔴 予測は「直近4週の平均 × 52」。初回セッションより前の週は平均に入れていない
            //    (入れると使い始めたばかりの人の予測が実ペースの 1/4 になる)
            if r.avg4Seconds > 0 {
                Divider().overlay(AppColors.secondaryBackground)
                totalRow(label: isJa ? "このペースで1年" : "A year at this pace",  // 文言はユーザー添削待ち
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

    // MARK: - 空

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary)
            Text(isJa ? "まだレポートを出せません" : "No report yet")  // 文言はユーザー添削待ち
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
            Text(isJa ? "一度ロックを使うと、翌週から届きます" : "Use a lock once and your report starts next week")  // 文言はユーザー添削待ち
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - 部品

    private func weekRangeText(_ r: WeeklyReport) -> String {
        guard let s = r.weekStart, let e = r.weekEnd else { return r.weekStartRaw }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "M/d"
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }

    /// 端末に無いフォント名で silent fallback させない (Didot-Bold が実機に無かった
    /// 2026-07-15 の教訓。QuoteCardView.installed と同じ流儀)
    static func brandFont(_ size: CGFloat) -> Font {
        UIFont(name: "Montserrat-BlackItalic", size: size) != nil
            ? .custom("Montserrat-BlackItalic", size: size)
            : .system(size: size, weight: .heavy)
    }
}

#Preview {
    NavigationStack { WeeklyReportView() }
}
