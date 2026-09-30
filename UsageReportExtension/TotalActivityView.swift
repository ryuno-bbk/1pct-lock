//
//  TotalActivityView.swift
//  UsageReportExtension
//
//  The 2 report views for the onboarding diagnosis (comparison chart / top 3 by usage).
//  The extension cannot import the main app's AppColors, so the brand tokens are
//  hardcoded here (keep them in sync with AppColors.swift):
//    background #000000 / off-white #F2EFE7 / muted #97928A / most muted #6E6A63 / card #17171B
//  ⚠️ Always paint the background opaque: the main app side has a fallback structure where "the
//  placeholder below shows through when this report is not drawn", so when it is drawn it must
//  cover it completely.
//

import SwiftUI
import FamilyControls
import ManagedSettings

// Brand tokens (match AppColors)
private let inkColor = Color(red: 242/255, green: 239/255, blue: 231/255)   // #F2EFE7
private let secondaryColor = Color(red: 151/255, green: 146/255, blue: 138/255) // #97928A
private let tertiaryColor = Color(red: 110/255, green: 106/255, blue: 99/255)   // #6E6A63
private let cardColor = Color(red: 23/255, green: 23/255, blue: 27/255)     // #17171B
private let barGrayColor = Color(red: 42/255, green: 42/255, blue: 48/255)  // #2A2A30

/// Minutes → "7h 18m". Units are written in English even in Japanese
/// (the Japanese form of "7 hours 18 minutes" takes too much width and breaks the chart's margins.
/// 2026-07-15 real device feedback, follows the reference)
private func durationLabel(minutes: Int, jp: Bool) -> String {
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// L28: the device has no Screen Time records at all (measured 0 minutes and 0 top apps).
/// In this case, drawing "actual usage 0m" or empty top 3 cards as is looks broken, so
/// the callers (both Comparison/TopApps) swap in an empty state
private extension UsageConfiguration {
    var hasNoUsageHistory: Bool { actualDailyMinutes == 0 && apps.isEmpty }
}

/// Shared empty state display (L28). The extension cannot import the main app's L enum, so these are
/// local strings
private struct EmptyUsageHistoryView: View {
    let jp: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(jp ? "まだデータがありません" : "No data yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(inkColor)
            Text(jp ? "スクリーンタイムの記録が貯まると表示されます" : "This appears once Screen Time has some history")
                .font(.system(size: 13))
                .foregroundColor(tertiaryColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Comparison chart (estimate vs measured)

struct ComparisonReportView: View {
    let config: UsageConfiguration

    private var jp: Bool { config.isJapanese }

    /// Show the comparison chart (2 bars) if the measured value is more than +20% over the estimate
    private var isOverEstimate: Bool {
        config.estimateDailyMinutes > 0 &&
        Double(config.actualDailyMinutes) > Double(config.estimateDailyMinutes) * 1.2
    }

    /// People who answered "8時間以上" ("8 hours or more") (the top bracket of the estimate = 480 minutes)
    /// are not surprised even if the measured value is higher (they chose 8+ knowing they use 16 hours),
    /// so no shock headline is shown (condition specified by the user 2026-07-17)
    private var isTopBracketEstimate: Bool {
        config.estimateDailyMinutes >= 480
    }

    private var showsShockHeadline: Bool { isOverEstimate && !isTopBracketEstimate }

    private var headline: String {
        if showsShockHeadline {
            return jp ? "予想より多く\n使っています" : "You're using more\nthan you thought"
        } else {
            // Estimate was right / estimate was higher / already aware of 8+ hours → just present the facts
            // plainly
            return jp ? "実際の使用時間" : "Your actual\nscreen time" // Wording is waiting for the user's review
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The 72pt at the top is space to avoid the main app's back button + progress bar
            // (OnboardingTopNav). If it is smaller, the headline overlaps the nav (2026-07-13 real device
            // feedback)
            Spacer().frame(height: 72)

            if config.hasNoUsageHistory {
                // L28: devices with 0 Screen Time history (right after the first launch on a real device/simulator,
                // etc.)
                Spacer()
                EmptyUsageHistoryView(jp: jp)
                Spacer()
            } else {
                // Follows the reference (2026-07-15 real device feedback): headlines are bold sans.
                // Policy of no longer overusing serif (forcing a cool typeface actually looks lame)
                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                Spacer()

                // Comparison (2 bars, estimate vs measured) only when the shock effect works.
                // If the user is already aware of 8+ hours / the estimate was right, no comparison is needed at all;
                // show only the single measured bar (2026-07-17 user request)
                if showsShockHeadline {
                    comparisonBars
                } else {
                    singleBar
                }

                // Place the chart lower instead of in the center of the screen to remove the stretched look
                // (2026-07-15 real device feedback: too much empty space)
                Spacer().frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black) // Must be opaque (covers the placeholder below)
    }

    private let maxChartHeight: CGFloat = 230
    private let minBarHeight: CGFloat = 28

    private func barHeight(minutes: Int, referenceMax: Int) -> CGFloat {
        guard referenceMax > 0 else { return minBarHeight }
        let ratio = CGFloat(minutes) / CGFloat(referenceMax)
        return max(maxChartHeight * ratio, minBarHeight)
    }

    private var comparisonBars: some View {
        let refMax = Int(Double(max(config.actualDailyMinutes, config.estimateDailyMinutes, 1)) * 1.08)
        // Column width fixed at 120/130 + spacing 10 (2026-07-17 real device feedback: the gap between bars
        // was too wide, so it was shortened 28→10).
        // Column width stays as is: it is the minimum width where the "1日の平均使用時間" ("Daily average")
        // label fits without wrapping
        // Follows the reference: number labels are bold sans, bars are a bit thick, labels are right under
        // the bars
        return HStack(alignment: .bottom, spacing: 10) {
            VStack(spacing: 12) {
                Text(durationLabel(minutes: config.estimateDailyMinutes, jp: jp))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 12)
                    .fill(barGrayColor)
                    .frame(width: 76, height: barHeight(minutes: config.estimateDailyMinutes, referenceMax: refMax))
                Text(jp ? "自分の予想" : "Your guess") // Wording follows the reference (2026-07-15)
                    .font(.system(size: 13))
                    .foregroundColor(tertiaryColor)
                    .lineLimit(1)
            }
            .frame(width: 120)

            VStack(spacing: 12) {
                Text(durationLabel(minutes: config.actualDailyMinutes, jp: jp))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                RoundedRectangle(cornerRadius: 12)
                    .fill(inkColor)
                    .frame(width: 76, height: barHeight(minutes: config.actualDailyMinutes, referenceMax: refMax))
                Text(jp ? "1日の平均使用時間" : "Daily average") // Wording follows the reference (2026-07-15)
                    .font(.system(size: 13))
                    .foregroundColor(tertiaryColor)
                    .lineLimit(1)
            }
            .frame(width: 130)
        }
        .frame(maxWidth: .infinity)
    }

    private var singleBar: some View {
        VStack(spacing: 12) {
            Text(durationLabel(minutes: config.actualDailyMinutes, jp: jp))
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(inkColor)
                .monospacedDigit()
            RoundedRectangle(cornerRadius: 12)
                .fill(inkColor)
                .frame(width: 84, height: 220)
            Text(jp ? "1日の平均使用時間" : "Daily average") // Wording follows the reference (2026-07-15)
                .font(.system(size: 13))
                .foregroundColor(tertiaryColor)
        }
    }
}

// MARK: - Top 3 by usage

struct TopAppsReportView: View {
    let config: UsageConfiguration

    private var jp: Bool { config.isJapanese }

    var body: some View {
        VStack(spacing: 0) {
            // Space to avoid the main app's back button + progress bar
            Spacer().frame(height: 72)

            if config.hasNoUsageHistory {
                // L28: on devices with 0 Screen Time history, do not draw empty top 3 cards
                Spacer()
                EmptyUsageHistoryView(jp: jp)
                Spacer()
            } else {
                Text(jp ? "最近最も\n使っているアプリ" : "Apps you use\nthe most")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 36)

                card

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black) // Must be opaque (covers the placeholder below)
    }

    /// Fixed width of the bar. GeometryReader caused a layout bug where rows stretch vertically in the
    /// Report drawing context, so it is not used at all; everything is built with fixed sizes
    /// (2026-07-13 real device feedback)
    private let barWidth: CGFloat = 280

    private var card: some View {
        let maxMinutes = config.apps.map(\.totalMinutes).max() ?? 1

        return VStack(alignment: .leading, spacing: 16) {
            // The value stays the daily average; the title is kept short (follows the reference 2026-07-15)
            Text(jp ? "使用量トップ 3" : "Top 3 by usage")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(secondaryColor)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            VStack(spacing: 22) {
                ForEach(config.apps) { app in
                    row(app: app, maxMinutes: maxMinutes)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(cardColor))
        .padding(.horizontal, 24)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Row that follows competitors: one line of [icon + name ... time] + a full-width bar under it
    private func row(app: TopAppEntry, maxMinutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let token = app.token {
                    Label(token)
                        .labelStyle(TopAppLabelStyle())
                } else {
                    Text(app.fallbackName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(inkColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(durationLabel(minutes: app.totalMinutes, jp: jp))
                    .font(.system(size: 14))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            bar(ratio: Double(app.totalMinutes) / Double(max(maxMinutes, 1)))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bar(ratio: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(tertiaryColor.opacity(0.18))
                .frame(width: barWidth, height: 6)
            Capsule()
                .fill(inkColor)
                .frame(width: barWidth * CGFloat(max(min(ratio, 1), 0)), height: 6)
        }
    }
}

/// Styles the icon + title of Label(ApplicationToken) in the brand tone
private struct TopAppLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: 40, height: 40)
            configuration.title
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(inkColor)
                .lineLimit(1)
        }
    }
}
