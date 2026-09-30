//
//  OnboardingLockModes.swift
//  AppBlocker
//
//  Shows the 3 lock modes (timer / schedule / location) on a single onboarding screen.
//
//  Why (2026-08-06 user feedback):
//  The old onboarding only argued "why you should quit" (diagnosis → shock → dream → signature),
//  and reached the paywall without ever showing what this app does.
//  = It was selling without showing what it sells.
//
//  Placed right after "shock → resolve" (user instruction).
//  This puts "here is how" right after "人生を変える覚悟はできていますか?" ("Are you ready to
//  change your life?").
//
//  Layout decision (the conclusion after mockups of 4 → 3 → 3 options):
//  - Mode names are large and **never wrap**. Same typesetting as the headings of the approved App
//    Store screenshots (heavy / tight tracking / nowrap). Spec is .headline in _builder/decorate.html
//  - The description sits small under the mode name in AppColors.textSecondary (same as .sub in the
//    screenshots)
//  - 🔴 The icon is placed extra large **behind** the text, cut off by the right edge of the screen.
//    Placing it side by side would force the mode name to shrink by that width
//    (this placement lets both "large icon" and "large text" work)
//  - Divider lines run to the screen edge. Stopping them 24pt inside left and right makes it look
//    like a list
//
//  ⚠️ Put the icon in .background. Inside a ZStack the 96pt icon decides the row height,
//     and 3 rows overflow the screen
//  ⚠️ Do not use scaleEffect (it dropped to 10fps on a real device in 2026-07. Only opacity + offset)
//

import SwiftUI

// MARK: - Step View

struct LockModesStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// Staged reveal. Rows come in from the top in order, and the CTA appears last (same approach as
    /// ShockLossStepView)
    @State private var revealedRows = 0
    @State private var showCTA = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    private var modes: [LockModeCopy] { LockModeCopy.all(lang) }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed space to avoid the top nav (back + 2px progress bar).
            // Matches the 64pt of the other quiz screens (OnboardingTopNav is 44pt + 16pt top padding)
            Spacer().frame(height: 64)

            // Page heading. One step larger than the mode names (21pt) so it stands out as the title.
            // 28pt = same as AppTypography.title1, matching the headings on the other onboarding screens
            Text(LockModeCopy.heading(lang))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .tracking(-0.6)
                .foregroundColor(AppColors.textPrimary)
                // "このアプリのロック方法" ("How this app locks") = 11 characters. Fits even at 28pt on the
                // narrowest iPhone
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            Spacer(minLength: 20)

            // Only this block has no horizontal padding, so the divider lines and icons reach the screen edge
            VStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    LockModeRow(mode: mode, isFirst: index == 0)
                        .opacity(revealedRows > index ? 1 : 0)
                        .offset(y: revealedRows > index ? 0 : 10)
                }
            }

            Spacer(minLength: 20)

            PrimaryButton(LockModeCopy.next(lang), icon: "arrow.right") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(showCTA ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LockModesBackdrop())
        .onAppear(perform: runReveal)
    }

    /// Bring rows in from the top at 0.13 second intervals, and show the CTA after all are in
    private func runReveal() {
        guard revealedRows == 0 else { return }
        for index in modes.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(index)) {
                withAnimation(.easeOut(duration: 0.45)) { revealedRows = index + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(modes.count) + 0.25) {
            withAnimation(.easeOut(duration: 0.45)) { showCTA = true }
        }
    }
}

// MARK: - One row

private struct LockModeRow: View {
    let mode: LockModeCopy
    let isFirst: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isFirst { hairline }

            VStack(alignment: .leading, spacing: 5) {
                Text(mode.title)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .tracking(-0.4)
                    .foregroundColor(AppColors.textPrimary)
                    // ⚠️ Do not wrap. The Japanese "タイマーブロック" ("Timer block", 8 characters) is currently the
                    // longest
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(mode.subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 19)
            // The extra large icon is laid as a background. .background does not affect the parent's size, so
            // the row height is decided by the text only (in a ZStack the icon would decide the height)
            .background(alignment: .trailing) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 74, weight: .ultraLight))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                AppColors.textPrimary.opacity(0.30),
                                AppColors.textPrimary.opacity(0.07)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Cut off at the right edge of the screen (being cut at the edge conveys "big")
                    .offset(x: 18)
                    .allowsHitTesting(false)
            }
            .clipped()

            hairline
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppColors.textPrimary.opacity(0.09))
            .frame(height: 1)
    }
}

// MARK: - Background

/// Black + fog. Matches the App Store screenshot spec ("background = black + fog. No other background
/// elements").
/// ⚠️ Do not use blur / material (full-screen blur is heavy on a real device). Only layered
/// RadialGradients
private struct LockModesBackdrop: View {
    var body: some View {
        ZStack {
            AppColors.background

            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.16),
                startRadius: 0,
                endRadius: 300
            )
            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.05), .clear],
                center: UnitPoint(x: 0.18, y: 0.58),
                startRadius: 0,
                endRadius: 250
            )
            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.045), .clear],
                center: UnitPoint(x: 0.86, y: 0.86),
                startRadius: 0,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Copy

/// 🔴 The Japanese is what the user specified verbally (2026-08-06). Do not reword it.
/// English is a draft translation, for the full native check. // Wording is waiting for the user's review
struct LockModeCopy: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String

    static func heading(_ lang: AppLanguage) -> String {
        lang == .japanese ? "このアプリのロック方法" : "How 1% locks your apps" // Wording is waiting for the user's review
    }

    static func next(_ lang: AppLanguage) -> String {
        lang == .japanese ? "次へ" : "Continue"
    }

    static func all(_ lang: AppLanguage) -> [LockModeCopy] {
        [
            LockModeCopy(
                id: "timer",
                symbol: "timer",
                title: lang == .japanese ? "タイマーブロック" : "Timer Block",
                subtitle: lang == .japanese
                    ? "ワンタップで決めた時間だけ集中"
                    : "One tap locks your apps for as long as you choose"
            ),
            LockModeCopy(
                id: "schedule",
                symbol: "calendar",
                title: lang == .japanese ? "スケジュール制限" : "Schedule",
                subtitle: lang == .japanese
                    ? "設定した曜日の決めた時間帯に自動でロック"
                    : "Locks automatically on the days and hours you set"
            ),
            LockModeCopy(
                id: "location",
                symbol: "mappin.and.ellipse",
                title: lang == .japanese ? "位置情報ロック" : "Location Lock",
                subtitle: lang == .japanese
                    ? "集中すると決めた場所に入った瞬間にロック"
                    : "Locks the moment you arrive at a place you chose to focus"
            )
        ]
    }
}

#Preview {
    LockModesStepView(onContinue: {})
}
