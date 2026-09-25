//
//  SessionCompleteView.swift
//  AppBlocker
//
//  タイマー自然完了時の「静かな祝福」画面。
//  Apple Fitness のリング完了(粒子)を参考に、墨+金で控えめに演出する。
//  派手な confetti はブランド(エリート志向 / Not for everyone)に不整合のため禁止。
//

import SwiftUI
// @Environment(\.requestReview) の実体 (RequestReviewAction) は StoreKit 側にあるため必須
import StoreKit

struct SessionCompleteView: View {
    /// 完遂直後の評価依頼 (2026-09-05)。判断は ReviewPrompt が持つ
    @Environment(\.requestReview) private var requestReview

    /// 今回のセッションの実ロック時間 (秒)
    let duration: TimeInterval
    /// schedule/location による継続ロック中の注記 (該当しない場合は nil)
    let continuedLockMessage: String?
    let lang: AppLanguage

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: - 演出シーケンス State

    @State private var numberRevealed = false
    @State private var animatedSeconds: Double = 0
    @State private var numberConfirmed = false
    @State private var hapticTrigger = false
    @State private var particlesActive = false
    @State private var statsGateReached = false
    @State private var revealedRowCount = 0
    @State private var showFooter = false
    @State private var showButton = false

    // MARK: - データ整合 State

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
                    // 🔴 2026-09-05: 完遂ベースのトリガーを復活させた。
                    //    2026-08-06 に全廃したのは「完遂を**前提条件**にすると大半に永久に聞けない」
                    //    という理由で、**追加の機会**として置く分には当時の判断と矛盾しない。
                    //    完遂直後は達成感が最大の瞬間で、最も星が高くなる。
                    //    OS が年3回に間引くので出し過ぎにはならない。判断は ReviewPrompt に集約。
                    ReviewPrompt.recordSessionCompleted()
                    let shouldAsk = ReviewPrompt.shouldAskAfterCompletedSession()
                    dismiss()
                    if shouldAsk {
                        Task {
                            // 画面が閉じきってから被せる (閉じるアニメと重ねない)
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
            // UI演出シーケンスとデータロードを並行実行 (どちらもブロックしない)
            Task { await runIntroSequence() }
            await loadStatsData()
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            AppColors.background

            // 「墨がわずかに明るくなる」演出 (中心やや上)
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

            // 🔴 金色と粒子の演出は撤去 (2026-08-29 ユーザー指示)。
            //    白のままカウントアップするだけのシンプルな見せ方にする
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

    // 2026-07-14 UI再設計: 金の数字を単独ヒーローに保つため、統計タイルは 2 個 (累計ロック / 連続日数) に縮小。
    // 上位% タイルは撤去 (MyProfileView 側には引き続き残る)
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

    /// 表示用の累計ロック時間フォーマット (BlockSessionTracker.formattedTotal() と同じ書式)。
    /// tracker.formattedTotal() は tracker.totalSeconds を直接使うため、
    /// オフライン整合用に max() 補正した displayedTotalSeconds には使えず、同じロジックをここで再現する。
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
            // reduceMotion: カウントアップ省略で即値表示、粒子スキップ、stagger 短縮
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

        // 1. 0.4秒の静寂
        try? await Task.sleep(nanoseconds: 400_000_000)

        withAnimation(.easeOut(duration: 0.3)) {
            numberRevealed = true
        }

        // 2. 0 から約1.2秒かけてカウントアップ
        await runCountUp()

        // 数字確定: 色遷移 + haptic 同期
        withAnimation(.easeInOut(duration: 0.4)) {
            numberConfirmed = true
        }
        hapticTrigger.toggle()

        // 4. 金の粒子 (1.5秒で自然消滅、シーケンス本体はブロックしない)
        particlesActive = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            particlesActive = false
        }

        // 5. 統計行: 数字確定の0.3秒後にゲートを開く
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation(.easeOut(duration: 0.3)) {
            statsGateReached = true
        }
        revealStatsIfReady()

        // 6. フッター
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeOut(duration: 0.25)) {
            showFooter = true
        }

        // 7. 完了ボタン
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

    /// ゲート (シーケンス上の表示タイミング) とデータロードの両方が揃ってから stagger 表示する。
    /// ゲートだけ先に開いた場合はプレースホルダのまま待機し、ロード完了時に改めて呼ばれる。
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

    // MARK: - Data Consistency (App Group キュー flush → 累計反映)

    private func loadStatsData() async {
        let totalBefore = sessionTracker.totalSeconds

        await sessionTracker.flushQueue()
        await sessionTracker.loadStats()

        // オフラインで flush 失敗しても、今回分を含んだ値を最低保証する
        let finalTotal = max(sessionTracker.totalSeconds, totalBefore + totalSecondsInt)
        displayedTotalSeconds = finalTotal
        statsLoaded = true
        revealStatsIfReady()
    }
}

// MARK: - Gold Particles (Canvas + TimelineView, confetti ライブラリ不使用)

/// 数字の輪郭付近から立ち上る金の微粒子。最大15個、軽量な Canvas 描画。
private struct GoldParticlesView: View {
    let isActive: Bool

    @State private var particles: [Particle] = []
    @State private var activatedAt: Date?

    private struct Particle {
        let startX: CGFloat   // -1...1 (中心からの相対オフセット)
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
