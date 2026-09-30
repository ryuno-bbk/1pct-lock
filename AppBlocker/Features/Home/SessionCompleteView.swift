//
//  SessionCompleteView.swift
//  AppBlocker
//
//  "Quiet celebration" screen when the timer completes naturally.
//  Based on Apple Fitness ring completion (particles), with a restrained ink + gold effect.
//  Flashy confetti is forbidden because it does not fit the brand (elite-minded / Not for everyone).
//

import SwiftUI
// Required because the implementation of @Environment(\.requestReview) (RequestReviewAction) is in
// StoreKit
import StoreKit

struct SessionCompleteView: View {
    /// Rating request right after completion (2026-09-05). ReviewPrompt makes the decision
    @Environment(\.requestReview) private var requestReview

    /// Actual lock time of this session (seconds)
    let duration: TimeInterval
    /// Note shown when a lock continues because of schedule/location (nil if not applicable)
    let continuedLockMessage: String?
    let lang: AppLanguage

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: - Animation sequence State

    @State private var numberRevealed = false
    @State private var animatedSeconds: Double = 0
    @State private var numberConfirmed = false
    @State private var hapticTrigger = false
    @State private var particlesActive = false
    @State private var statsGateReached = false
    @State private var revealedRowCount = 0
    @State private var showFooter = false
    @State private var showButton = false

    // MARK: - Data consistency State

    @State private var statsLoaded = false
    @State private var displayedTotalSeconds = 0

    private var totalSecondsInt: Int {
        max(0, Int(duration.rounded()))
    }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                mainNumberSection

                Spacer().frame(height: 36)

                statsCard
                    .opacity(statsGateReached ? 1 : 0)
                    .offset(y: statsGateReached ? 0 : 8)

                Spacer(minLength: 20)

                if let message = continuedLockMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                        .opacity(showFooter ? 1 : 0)
                }

                PrimaryButton(L.sessionCompleteDone(lang)) {
                    // 🔴 2026-09-05: brought back the completion-based trigger.
                    //    It was removed entirely on 2026-08-06 because "if completion is a **precondition**, most users
                    //    are never asked", so placing it as an **additional opportunity** does not contradict that decision.
                    //    Right after completion is the moment of the strongest sense of achievement, when ratings are
                    //    highest.
                    //    The OS limits it to 3 times a year, so it will not be shown too often. The decision is centralized
                    //    in ReviewPrompt.
                    ReviewPrompt.recordSessionCompleted()
                    let shouldAsk = ReviewPrompt.shouldAskAfterCompletedSession()
                    dismiss()
                    if shouldAsk {
                        Task {
                            // Show it after the screen has fully closed (do not overlap it with the close animation)
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            requestReview()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .opacity(showButton ? 1 : 0)
            }
        }
        .task {
            // Run the UI animation sequence and the data load in parallel (neither blocks)
            Task { await runIntroSequence() }
            await loadStatsData()
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            AppColors.background

            // "Ink gets slightly brighter" effect (slightly above center)
            RadialGradient(
                colors: [Color.white.opacity(0.05), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 0,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Main Number

    private var mainNumberSection: some View {
        VStack(spacing: 10) {
            Text(L.sessionCompleteAchievedLabel(lang))
                .font(.system(size: 13, weight: .medium))
                .tracking(1.5)
                .foregroundColor(AppColors.textSecondary)
                .opacity(numberRevealed ? 1 : 0)

            // 🔴 The gold color and particle effects were removed (2026-08-29 user instruction).
            //    Simple presentation: it just counts up in white
            Text(formatDuration(Int(animatedSeconds.rounded())))
                .font(.system(size: 56, weight: .bold))
                .monospacedDigit()
                .foregroundColor(AppColors.textPrimary)
                .contentTransition(.numericText(value: animatedSeconds))
                .opacity(numberRevealed ? 1 : 0)
                .sensoryFeedback(.success, trigger: hapticTrigger)
        }
    }

    // MARK: - Stats Card

    private var statsCard: some View {
        VStack(spacing: 0) {
            if statsLoaded {
                let kinds = visibleStatRowKinds
                ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                    statRow(kind)
                        .opacity(index < revealedRowCount ? 1 : 0)
                        .offset(y: index < revealedRowCount ? 0 : 4)
                    if index < kinds.count - 1 {
                        Divider().background(AppColors.textTertiary.opacity(0.15))
                    }
                }
            } else {
                placeholderRow
                Divider().background(AppColors.textTertiary.opacity(0.15))
                placeholderRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.cardBackground)
        )
        .padding(.horizontal, 24)
        .redacted(reason: statsLoaded ? [] : .placeholder)
    }

    // 2026-07-14 UI redesign: to keep the gold number as the single hero, the stat tiles were reduced to 2
    // (total lock / consecutive days).
    // The top percentile tile was removed (it still remains in MyProfileView)
    private enum StatRowKind: Equatable {
        case total, streak
    }

    private var visibleStatRowKinds: [StatRowKind] {
        [.total, .streak]
    }

    private func statRow(_ kind: StatRowKind) -> some View {
        HStack(spacing: 8) {
            if kind == .streak {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
            }
            Text(rowLabel(kind))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Text(rowValue(kind))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(.vertical, 12)
    }

    private var placeholderRow: some View {
        HStack {
            Text("00:00")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Text("00:00")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(.vertical, 12)
    }

    private func rowLabel(_ kind: StatRowKind) -> String {
        switch kind {
        case .total: return L.sessionCompleteTotalLabel(lang)
        case .streak: return L.sessionCompleteStreakLabel(lang)
        }
    }

    private func rowValue(_ kind: StatRowKind) -> String {
        switch kind {
        case .total: return displayedTotalText
        case .streak: return L.sessionCompleteStreakValue(sessionTracker.streakDays, lang)
        }
    }

    /// Format of the total lock time for display (same format as BlockSessionTracker.formattedTotal()).
    /// tracker.formattedTotal() uses tracker.totalSeconds directly, so it cannot be used for
    /// displayedTotalSeconds, which is corrected with max() for offline consistency, and the same logic is
    /// reproduced here.
    private var displayedTotalText: String {
        let hours = displayedTotalSeconds / 3600
        let minutes = (displayedTotalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Duration Formatting

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    // MARK: - Intro Sequence

    private func runIntroSequence() async {
        guard !reduceMotion else {
            // reduceMotion: skip the count-up and show the value immediately, skip particles, shorten the stagger
            numberRevealed = true
            animatedSeconds = duration
            numberConfirmed = true
            hapticTrigger.toggle()
            statsGateReached = true
            showFooter = true
            showButton = true
            revealStatsIfReady()
            return
        }

        // 1. 0.4 seconds of silence
        try? await Task.sleep(nanoseconds: 400_000_000)

        withAnimation(.easeOut(duration: 0.3)) {
            numberRevealed = true
        }

        // 2. Count up from 0 over about 1.2 seconds
        await runCountUp()

        // Number finalized: color transition + synced haptic
        withAnimation(.easeInOut(duration: 0.4)) {
            numberConfirmed = true
        }
        hapticTrigger.toggle()

        // 4. Gold particles (fade out naturally in 1.5 seconds, do not block the sequence itself)
        particlesActive = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            particlesActive = false
        }

        // 5. Stat rows: open the gate 0.3 seconds after the number is finalized
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation(.easeOut(duration: 0.3)) {
            statsGateReached = true
        }
        revealStatsIfReady()

        // 6. Footer
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeOut(duration: 0.25)) {
            showFooter = true
        }

        // 7. Done button
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeOut(duration: 0.25)) {
            showButton = true
        }
    }

    private func runCountUp() async {
        let target = duration
        guard target > 0 else {
            animatedSeconds = 0
            return
        }

        let steps = 36
        let stepNanos: UInt64 = 1_200_000_000 / UInt64(steps)

        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = 1 - pow(1 - t, 3) // ease-out cubic
            let value = target * eased
            withAnimation(.linear(duration: Double(stepNanos) / 1_000_000_000)) {
                animatedSeconds = value
            }
            try? await Task.sleep(nanoseconds: stepNanos)
        }
        animatedSeconds = target
    }

    /// Show with stagger only after both the gate (display timing in the sequence) and the data load are
    /// ready.
    /// If only the gate opens first, wait with placeholders; it is called again when loading finishes.
    private func revealStatsIfReady() {
        guard statsGateReached, statsLoaded else { return }
        let total = visibleStatRowKinds.count
        guard revealedRowCount < total else { return }

        Task {
            var start = revealedRowCount
            while start < total {
                withAnimation(.easeOut(duration: 0.25)) {
                    revealedRowCount = start + 1
                }
                start += 1
                if start < total {
                    try? await Task.sleep(nanoseconds: reduceMotion ? 40_000_000 : 120_000_000)
                }
            }
        }
    }

    // MARK: - Data Consistency (App Group queue flush → total updated)

    private func loadStatsData() async {
        let totalBefore = sessionTracker.totalSeconds

        await sessionTracker.flushQueue()
        await sessionTracker.loadStats()

        // Even if the flush fails offline, guarantee at least a value that includes this session
        let finalTotal = max(sessionTracker.totalSeconds, totalBefore + totalSecondsInt)
        displayedTotalSeconds = finalTotal
        statsLoaded = true
        revealStatsIfReady()
    }
}

// MARK: - Gold Particles (Canvas + TimelineView, no confetti library)

/// Fine gold particles that rise from around the outline of the number. Up to 15, drawn with a light
/// Canvas.
private struct GoldParticlesView: View {
    let isActive: Bool

    @State private var particles: [Particle] = []
    @State private var activatedAt: Date?

    private struct Particle {
        let startX: CGFloat   // -1...1 (relative offset from the center)
        let driftAmplitude: CGFloat
        let delay: Double
        let duration: Double
        let size: CGFloat
    }

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { timeline in
            Canvas { context, size in
                guard let activatedAt else { return }
                let elapsed = timeline.date.timeIntervalSince(activatedAt)

                for particle in particles {
                    let t = elapsed - particle.delay
                    guard t >= 0, t <= particle.duration else { continue }

                    let progress = t / particle.duration
                    let y = size.height * 0.6 - progress * size.height * 0.55
                    let sway = sin(progress * .pi * 2) * particle.driftAmplitude
                    let x = size.width / 2 + particle.startX * size.width * 0.28 + sway

                    let opacity: Double
                    if progress < 0.15 {
                        opacity = progress / 0.15
                    } else {
                        opacity = max(0, 1 - (progress - 0.15) / 0.85)
                    }

                    let rect = CGRect(
                        x: x - particle.size / 2,
                        y: y - particle.size / 2,
                        width: particle.size,
                        height: particle.size
                    )
                    context.opacity = opacity
                    context.fill(Path(ellipseIn: rect), with: .color(AppColors.gold))
                }
            }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            activatedAt = Date()
            particles = (0..<15).map { _ in
                Particle(
                    startX: CGFloat.random(in: -1...1),
                    driftAmplitude: CGFloat.random(in: 4...14),
                    delay: Double.random(in: 0...0.6),
                    duration: Double.random(in: 0.7...1.1),
                    size: CGFloat.random(in: 3...6)
                )
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SessionCompleteView(
        duration: 25 * 60,
        continuedLockMessage: "スケジュールで引き続きロック中です",
        lang: .japanese
    )
}
