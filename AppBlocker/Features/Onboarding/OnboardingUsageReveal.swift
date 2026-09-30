//
//  OnboardingUsageReveal.swift
//  AppBlocker
//
//  Diagnostic onboarding NEW step (2026-07 redesign): inserted right after Q3 (daily hours).
//  The measured Screen Time is drawn by DeviceActivityReport (UsageReportExtension) inside the extension
//  (measured values cannot be taken out of the extension). This file holds that embedding and the
//  fallback display for when the extension does not render.
//
//  Internal flow (everything runs on @State phase inside one OnboardingStep):
//    PHASE 1 loading  : 1% monogram splash animation (the pulsing "Analyzing..." dots were removed)
//    PHASE 2 reveal   : guess vs actual comparison (extension) → go forward with the CTA
//    PHASE 3 topApps  : top 3 apps by usage (extension) → onContinue()
//
//  The fallback for slow or unavailable measured data holds no real data at all:
//  reveal shows only the user's own guess (the Q3 answer) as "自分の予想" ("Your guess"), and topApps
//  shows the content of topAppsCard (skeletonBarWidthRatios, neutral skeleton rows).
//  2026-09-26: removed the old fallback's "comparison chart that treated self-report × 2.2 as the actual
//  usage time" and the "予想より多く使っています" ("You use it more than you expected") heading,
//  because they were fabricated values.
//

import SwiftUI
import DeviceActivity

struct UsageRevealStepView: View {
    /// Answer to Q3 (how many hours a day you look at your phone). Used for the guess value passed to the
    /// extension, and for the fallback display (your guess) when the extension does not render
    let dailyHours: QuizDailyHours?
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var phase: RevealPhase = .loading

    /// Opacity of the fallback display in the reveal phase (self-reported guess only).
    /// A flicker was reported on a real device (2026-07-17): "the moment the bar chart appears, a placeholder
    /// bar with a fabricated value (16h) is visible for 0.1 seconds, then it is replaced by the measured
    /// report". The cause: the placeholder is shown immediately, while the DeviceActivityReport (extension)
    /// on top of it finishes drawing slightly later. As a fix, right after entering reveal we hide it with
    /// opacity 0, and fade it in only after the time the extension would normally need to finish drawing
    /// (about 0.8 seconds).
    /// → As long as the extension draws normally, the user never sees this placeholder at all.
    /// Only when the extension draws slowly or fails does it appear as a fallback after 0.8 seconds.
    /// 2026-09-26: the bar with the fabricated value (self-report × 2.2) was removed; it now holds only the
    /// user's guess. The flicker itself (another view visible for a moment before the extension) can still
    /// happen, so the delay is kept as is.
    /// The neutral skeleton on the topApps side is a legitimate "loading" display, so it is excluded (still
    /// shown immediately)
    @State private var revealPlaceholderOpacity: Double = 0

    /// Opacity of the report layer (DeviceActivityReport).
    /// Real-device feedback (2026-07-17): on the reveal→topApps context switch, the old comparison chart
    /// (measured bars) stays visible for about 0.1 seconds until the extension finishes drawing the new
    /// scene → hide the report layer only during the switch, show the topApps skeleton below (a legitimate
    /// loading display), then fade it back in
    @State private var reportOpacity: Double = 1

    /// Delay mounting the report until the step transition animation (slide + fade 0.42s) finishes.
    /// SwiftUI opacity is multiplied into each child of the ZStack, so during the transition fade even the
    /// "loading curtain that should be opaque" becomes semi-transparent, and the report already mounted
    /// below it (a warmed-up extension may show the previous pass's drawing immediately) shows through for
    /// a moment (2026-07-25 real-device feedback: histogram flicker at the moment of the transition to
    /// analyzing). If we mount after the transition finishes, this cannot happen by structure
    @State private var reportMounted = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    private enum RevealPhase { case loading, reveal, topApps }

    // MARK: - Guess (self-reported)

    /// Self-reported daily hours (median)
    private var estimateDailyHours: Double { dailyHours?.medianHours ?? 4 }

    /// Guess shown in the fallback display. The exact text of the option the user picked
    /// (e.g. "4〜6時間" ("4-6 hours")).
    /// The median (medianHours) is a representative value for calculations, not the user's answer, so it is
    /// not used for display.
    /// If unanswered (nil), no value is shown
    private var estimateAnswerLabel: String? { dailyHours?.label(lang) }

    // The placeholder for "実際の使用時間" ("Actual usage time") (self-report × 2.2, capped at 16h), the
    // comparison chart that used it, and the "予想より多く" ("More than expected") heading were removed on
    // 2026-09-26 (because they were fabricated values).
    // Measured values cannot be taken out of the extension, so when the extension does not render, the
    // main app has no "actual value" it can show

    var body: some View {
        ZStack {
            // The measured report layer stays mounted "from the moment this step is entered", so the extension
            // process warms up behind the loading animation (2-3 seconds).
            // The old implementation mounted DeviceActivityReport only when reveal was reached. Because of the
            // extension's cold-start drawing delay, the first time always showed the placeholder (centered chart +
            // gray top 3), and only the second time, after going to the top-3 screen and back (warmed up), did the
            // measured report (chart near the CTA + real apps) appear. That was the cause of the carry-over bug
            // that made it look like "there are two layouts" (fixed 2026-07-25). The setup that keeps a single
            // instance and switches only the context is kept
            // (the only workaround for the "second one is blank" bug)
            reportLayer

            // The loading splash is an opaque overlay. It covers the report warming up behind it
            if phase == .loading {
                loadingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Write the Report extension's input (self-reported guess + language) to the App Group first.
            // The loader's 2-3 seconds also serve as the extension's prewarm
            AppGroupStorage.shared.saveOnboardingRevealInputs(
                estimateMinutes: Int((estimateDailyHours * 60).rounded()),
                languageRaw: lang == .japanese ? "japanese" : "english"
            )

            // Mount the report after the step transition animation finishes (details in the reportMounted comment).
            // This is always after the App Group input write (above), so the extension draws with the correct guess
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                reportMounted = true
            }

            guard phase == .loading else { return }
            // Hold the monogram animation for 2-3 seconds (shorter when Reduce Motion is on)
            let delay = UIAccessibility.isReduceMotionEnabled ? 0.4 : Double.random(in: 2.0...3.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.4)) { phase = .reveal }
            }
        }
    }

    // MARK: - Phase 1: Loading (monogram splash)

    private var loadingView: some View {
        VStack(spacing: 28) {
            Spacer()
            // Shimmer loader: a diagonal band of light runs across the still form of the app's real icon (1% monogram)
            // (renewed 2026-07-17. The old "two dots bounce and swap" was rejected by user feedback)
            MonogramSwapLoader(size: 108)
            // Glowing "解析中" ("Analyzing") text (2026-07-17 user request. Replaces the old "1%" wordmark:
            // the monogram carries the brand, so the text says what is happening right now)
            GlowingAnalyzingText(lang: lang)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Phase 2: Guess vs actual

    private var reportLayer: some View {
        VStack(spacing: 0) {
            // Put the measured report (UsageReportExtension) on the top layer.
            // When the report renders, its opaque black background fully covers the placeholder;
            // when it does not render or is slow, the placeholder below (based on the self-report) is visible.
            // DeviceActivityReport stays a single instance and only its context is switched
            ZStack {
                // Placeholder (fallback while the extension has not drawn). If warmed up, the extension covers it.
                // loading/reveal lay down the comparison placeholder (topApps uses the topApps one)
                if phase == .topApps {
                    placeholderTopAppsContent
                } else {
                    // Flicker fix for the fallback (details in the revealPlaceholderOpacity comment)
                    placeholderRevealContent
                        .opacity(revealPlaceholderOpacity)
                }
                // loading and reveal both keep showing comparison, so the comparison report warmed up during loading
                // is used as is in reveal, with no second cold start.
                // Switching to topApps recreates the whole instance with .id (2026-07-25 real-device feedback:
                // when only the context of the same instance was replaced, the topApps scene did not render the first
                // time only, and it appeared after going back and entering again (= view recreated) → circumstantial
                // evidence that recreating works.
                // Only one is ever mounted at a time, so we do not hit the "second one is blank" bug (2026-07-13).
                // The data query uses the same filter and is already warm, so redraw is fast, and the blank moment
                // during the switch is already covered by the skeleton below + the reportOpacity animation)
                if reportMounted {
                    usageReport(.init(phase == .topApps ? "onboardingTopApps" : "onboardingComparison"))
                        .id(phase == .topApps ? "report-topApps" : "report-comparison")
                        .opacity(reportOpacity)
                }
            }
            .task(id: phase) {
                guard phase == .reveal else { return }
                revealPlaceholderOpacity = 0
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeIn(duration: 0.3)) {
                    revealPlaceholderOpacity = 1
                }
            }

            // The CTA is always present; during loading it is only hidden with opacity (2026-07-25 review fix).
            // If it is removed with `if`, the report layer's height changes by the CTA's height on loading→reveal,
            // and the warmed-up layout and the displayed layout differ in size (risk that the extension's remote
            // view re-lays out and jitters during the fade). Fix the frame so the warm-up matches the display size
            PrimaryButton(lang == .japanese ? "次へ" : "Next") {
                if phase == .reveal {
                    // Flicker fix for the context switch (details in the reportOpacity comment):
                    // ① hide the report layer → ② switch phase (the skeleton below is visible) →
                    // ③ fade back in around when the new scene finishes drawing.
                    // Set the placeholder to 0 immediately, before hiding the report (2026-07-25 real-device feedback:
                    // the report's fade-out briefly exposed the fallback below (at the time, a fabricated-value chart
                    // such as 11h))
                    revealPlaceholderOpacity = 0
                    withAnimation(.easeOut(duration: 0.1)) { reportOpacity = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeOut(duration: 0.3)) { phase = .topApps }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            withAnimation(.easeIn(duration: 0.25)) { reportOpacity = 1 }
                        }
                    }
                } else {
                    onContinue()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(phase == .loading ? 0 : 1)
            .allowsHitTesting(phase != .loading)
        }
    }

    /// Fallback display with only the self-report (while the report has not drawn). There is no measured
    /// data, so "実際の使用時間" ("Actual usage time"), "予想より多く" ("More than expected") and the
    /// comparison chart are not shown; only the user's guess is shown as "自分の予想" ("Your guess")
    /// (2026-09-26)
    private var placeholderRevealContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            Text(revealHeadline)
                .font(.system(size: 26, weight: .bold)) // Same typeface as the extension's heading (unified 2026-07-27)
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Spacer()

            // Only the single bar for the guess (the bar height is fixed and does not represent the value). The
            // old implementation showed a comparison chart against the fabricated value (self-report × 2.2) / a
            // single bar for "実際の使用時間" ("Actual usage time") (removed 2026-09-26)
            SingleUsageBar(valueLabel: estimateAnswerLabel, lang: lang)

            // Match the bottom alignment (Spacer 44) of the extension's ComparisonReportView. In the old
            // implementation this was a flexible Spacer(), so the chart sat in the center of the screen, did not
            // match the extension's position (near the CTA), and it looked like "the chart is in two places"
            // (fixed 2026-07-25)
            Spacer().frame(height: 44)
        }
    }

    // MARK: - Embedded measured report (UsageReportExtension)

    /// Aggregation period (7 full days up to yesterday). Fixed with @State so that the DateInterval does
    /// not change on every re-render and keep re-querying the report.
    /// Why the ends are aligned to day boundaries (fix for 2026-07-19 real-device feedback "the average
    /// shows lower than actual"):
    /// the old implementation used "from this moment to the same time 7 days ago", so two incomplete days
    /// (partial data) were mixed in at the start and the end, and the extension divides by the number of
    /// daily segments, so the average came out systematically low.
    /// Excluding today (in progress and incomplete) and using 7 full days cut at day boundaries gives the
    /// correct daily average
    @State private var reportInterval: DateInterval = {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        return DateInterval(start: start, end: todayStart)
    }()

    /// Filter for the past 7 days with daily segments. The Context rawValue must match the extension's
    /// declaration exactly
    private func usageReport(_ context: DeviceActivityReport.Context) -> some View {
        let filter = DeviceActivityFilter(
            segment: .daily(during: reportInterval),
            users: .all,
            devices: .init([.iPhone])
        )
        return DeviceActivityReport(context, filter: filter)
            .allowsHitTesting(false)
    }

    private var revealHeadline: String {
        // The fallback has no measured data, so it does not show "実際の使用時間" ("Actual usage time") or
        // "予想より多く使っています" ("You use it more than you expected")
        // (both are texts that can only be said with measured data. Only the extension's TotalActivityView
        // shows them). The heading reuses the existing label "自分の予想" ("Your guess"); no new text is
        // written (2026-09-26)
        lang == .japanese ? "自分の予想" : "Your guess" // Text waiting for user review (reuses an existing label)
    }

    // MARK: - Phase 3: Top 3 by usage

    /// Width ratios (0...1) of the name bars in the skeleton rows. Previously this held concrete fabricated
    /// data such as "YouTube 7h 18m", but if this placeholder was visible the moment the measured report was
    /// late to render, there was a risk it would be mistaken for real data, so it was changed to neutral
    /// skeleton rows with no content (2026-07 cleanup). Each row has a different width, only to keep an
    /// uneven skeleton look
    private let skeletonBarWidthRatios: [CGFloat] = [0.62, 0.46, 0.52]

    /// Placeholder display (fallback while the report has not drawn)
    private var placeholderTopAppsContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            Text(lang == .japanese ? "最近最も\n使っているアプリ" : "Apps you use\nthe most")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer().frame(height: 36)

            topAppsCard

            Spacer()
        }
    }

    private var topAppsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(lang == .japanese ? "使用量トップ3" : "Top 3 by usage")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textTertiary)

            VStack(spacing: 18) {
                ForEach(Array(skeletonBarWidthRatios.enumerated()), id: \.offset) { _, ratio in
                    SkeletonTopAppRow(nameBarWidthRatio: ratio)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppColors.cardBackground)
        )
        .padding(.horizontal, 24)
    }
}

// MARK: - Prewarming the measured report (2026-07-25 real-device feedback round 26)

/// Mount an invisible DeviceActivityReport behind the birth date / gender steps, so that the extension
/// process launch + the DeviceActivity query are done in advance.
/// Observed on a real device: the cold start when reaching usageReveal is slower than the loading
/// animation (2-3 seconds), and the first time even the comparison chart stays the placeholder (a
/// fabricated value at the time) + the top 3 fails. The "second time", after passing once, draws
/// immediately → it is fast as long as the query/process is warm; that is the basis for prewarming.
/// ⚠️ The size is fixed at 1×1 (settled 2026-07-27): in feedback round 27 we misdiagnosed the 1×1
/// layout cache as the cause of the "vertical shrink" and made it full screen, but in fact the shrunken
/// chart was a separate implementation of the placeholder (now fixed to match the extension exactly).
/// Also, the full-screen run regressed so that even the top 3 failed (round 27, which was 1×1,
/// succeeded on the top 3) → rolled back to the proven 1×1.
/// ⚠️ The filter must match UsageRevealStepView.reportInterval / usageReport exactly
/// (so that they share the deviceactivityd query cache).
/// ⚠️ Mount only on quizBirthDate/quizGender (mounting at the same time as usageReveal hits the known
/// "second one is blank" bug. quizDailyHours sits in between to prevent coexistence by structure)
struct UsageReportWarmUpView: View {
    private let interval: DateInterval = {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        return DateInterval(start: start, end: todayStart)
    }()

    var body: some View {
        DeviceActivityReport(
            .init("onboardingComparison"),
            filter: DeviceActivityFilter(
                segment: .daily(during: interval),
                users: .all,
                devices: .init([.iPhone])
            )
        )
        .frame(width: 1, height: 1)
        .opacity(0.02) // Keep a tiny amount because a full 0 may cause drawing to be skipped (invisible on the black background)
        .allowsHitTesting(false)
    }
}

// MARK: - Format helpers

// (formatDuration / QuizDailyHours.revealRangeLabel became dead code after the 2026-07-27 unification
// of the extension's notation and were deleted)
// (reportDurationLabel and the comparison chart UsageComparisonChart became dead code after the
// 2026-09-26 removal of fabricated values and were deleted.
//  Measured values cannot be taken out of the extension, so a comparison chart in the main app could
//  only be filled with fabricated values)

// MARK: - Loader (swap of the two dots of %)

/// A loader with **exactly the same geometry** as the app's real icon (MonogramMark = 1% monogram)
/// (fully renewed 2026-07-17). The old animation "the two dots of % jump over the bar and swap" was
/// rejected by user feedback as "bouncing/spinning animations are lame" → the motion is limited to
/// "light" only: a diagonal band of light (shimmer) runs across the still 1% monogram at a fixed
/// interval. The light band is masked by the monogram shape, so only the inside of the glyphs lights up
/// in turn. Same approach as the skeleton loading of luxury brands; the shape never moves.
/// With Reduce Motion, only the still monogram
private struct MonogramSwapLoader: View {
    let size: CGFloat

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    @State private var sweep = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            MonogramMark(assembled: true, size: size)
                .opacity(0.9)

            if !reduceMotion {
                // Diagonal light band. The offset runs from outside the glyph width to outside on the other side, so
                // the wrap-around jump of repeatForever happens outside the mask and is not visible (it also serves as
                // the pause)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.9), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: size * 0.55, height: size * 1.7)
                .rotationEffect(.degrees(24))
                .offset(x: sweep ? size * 1.25 : -size * 1.25)
                .mask(MonogramMark(assembled: true, size: size))
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        // Slow breathing (added 2026-07-17 in response to user feedback "Shouldn't it have an animation?".
        // Keeping the rule of no movement-type animation, only a slight scale oscillation is added)
        .scaleEffect(breathe ? 1.025 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                sweep = true
            }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Glowing "解析中" ("Analyzing") text (2026-07-17 user request).
/// A blurred lower layer of the same string is stacked under it, and only its opacity breathes to make
/// a white halo (the blur radius is fixed = avoids recomputing the blur every frame. A lesson learned
/// about blur cost).
/// The three trailing dots light up in order to show analysis progress. Still when Reduce Motion is on
private struct GlowingAnalyzingText: View {
    let lang: AppLanguage

    @State private var glow = false
    @State private var litDots = 0

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var body: some View {
        ZStack {
            textContent
                .blur(radius: 7)
                .opacity(reduceMotion ? 0.4 : (glow ? 0.95 : 0.25))
            textContent
        }
        .onAppear {
            guard !reduceMotion else { litDots = 3; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 380_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    litDots = (litDots + 1) % 4
                }
            }
        }
    }

    private var textContent: some View {
        HStack(alignment: .center, spacing: 3) {
            Text(lang == .japanese ? "解析中" : "Analyzing") // Text waiting for user review
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 3.5, height: 3.5)
                        .opacity(litDots > i ? 1 : 0.25)
                }
            }
            .padding(.top, 6)   // Align near the baseline
        }
        .foregroundColor(AppColors.textPrimary)
    }
}

/// Fallback single-bar display (the user's guess). The bar height is fixed and does not represent the
/// value.
/// ⚠️ Must keep the same geometry as the extension (TotalActivityView.singleBar) (2026-07-27 real-device
/// feedback: when the dimensions differed from the extension, the chart seemed to "shrink and shift"
/// only when the placeholder appeared). If you change the extension side, follow it here
private struct SingleUsageBar: View {
    /// Text of the guess the user picked (e.g. "4〜6時間" ("4-6 hours")). If nil, no value is shown (only
    /// the frame height is reserved)
    let valueLabel: String?
    let lang: AppLanguage

    private let barHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 12) {
            // 2026-09-26: previously a fabricated value (self-report × 2.2) was placed here invisibly.
            // Now the user's guess is shown as is (under the heading "自分の予想" ("Your guess"))
            Text(valueLabel ?? " ")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .opacity(valueLabel == nil ? 0 : 1)

            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.textPrimary)
                .frame(width: 84, height: barHeight)

            Text(lang == .japanese ? "1日の平均使用時間" : "Daily average")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        }
    }
}

// MARK: - Top 3 by usage (skeleton, fallback while the measured report has not drawn)

/// One row of the top 3. Previously this showed a real app name (YouTube etc.) + a made-up usage time +
/// a colored icon tile, but if the measured report (UsageReportExtension) was late to draw and this was
/// visible even for a moment, there was a risk of it being mistaken for "real data".
/// Changed to a neutral gray-bar skeleton with no app name / time / icon color, while keeping only the
/// layout footprint (icon 40x40 / 2 lines / bar height 6) identical to the real-data version
/// (2026-07 cleanup)
private struct SkeletonTopAppRow: View {
    /// Width ratio of the name bar (0...1, fraction of the row width). Different per row,
    /// only to keep an uneven skeleton look
    let nameBarWidthRatio: CGFloat

    private var skeletonColor: Color { AppColors.textTertiary.opacity(0.18) }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(skeletonColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(skeletonColor)
                            .frame(width: geo.size.width * nameBarWidthRatio, height: 14)
                    }
                    .frame(height: 14)

                    Spacer(minLength: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonColor)
                        .frame(width: 34, height: 12)
                }

                Capsule()
                    .fill(skeletonColor)
                    .frame(height: 6)
            }
        }
    }
}
