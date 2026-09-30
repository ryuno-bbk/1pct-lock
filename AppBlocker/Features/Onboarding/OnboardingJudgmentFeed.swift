//
//  OnboardingJudgmentFeed.swift
//  AppBlocker
//
//  "Live review" effect (2026-07-29 user idea, v1 = implemented at Fable's discretion).
//  v1 was placed on the hook screen, but after real device feedback it moved to
//  "これらは流れてこない" ("These don't flow in") (ModerationPolicyStepView) (the hook screen was
//  redone as an ARISE-style hero). Post cards drop one at a time from the top, are scanned in the
//  center → get a category label → if passed, flow down (toward the feed), and if rejected, turn
//  red and get knocked out to the side. Shows the claim of AI moderation not in words but as
//  something happening in front of you. Meant to be embedded in a parent frame (the card is
//  placed at the center of the parent).
//
//  Tone design (avoiding the concern that it could feel "sadistic / in bad taste"):
//  - Not a show of judgment but a "checkpoint": a quiet scan and a matter-of-fact pass are the
//    base. Red is used only for the moment of rejection. Motion is mainly light and scale, per the
//    brand principles
//  - No stamps/bounces/excess rotation (only the -12° tilt when knocked out)
//
//  Rollback: just switch JudgmentFeedView back to FeedMarquee in FeedPreviewHookView
//  (FeedMarquee is left in place).
//

import SwiftUI

// MARK: - Script

/// One card under review. label = category name shown on the verdict chip // Wording awaiting user review
struct JudgmentItem {
    let image: String
    let labelJa: String
    let labelEn: String
    let pass: Bool
}

enum JudgmentScript {
    /// Script per display language (2026-07-31 real device feedback).
    /// Removed from the English version:
    ///   - Pachinko: a Japan-specific game whose context does not come across in English-speaking
    ///     regions (specified by the user). Instead, the 2nd card is a party (keeps the policy of
    ///     showing "the rejected ones" early as the hook)
    ///   - 5 good posts with Japanese baked in ("腕の日" ("arm day") / "4食分作った" ("made 4 meals") /
    ///     "今から商談" ("business meeting now") / "朝ラン" ("morning run") /
    ///     "食い終わったら走って勉強" ("done eating, now run and study")), so that English users are not
    ///     shown images with Japanese. The good posts usable in the English version are 4: "5:20",
    ///     "HARD WORK", "LEG DAY" and one with no text
    /// The English version has 12 in total (4 good + 8 NG). Add here once the brand images are remade
    /// including English versions
    static func items(for lang: AppLanguage) -> [JudgmentItem] {
        lang == .japanese ? japanese : english
    }

    /// 2026-07-29 real device feedback: "what we want to show is the rejected ones" → use all 9 NG
    /// images, and show a rejected example right from the 2nd card (opening hook good → bad → bad).
    /// After that, mostly alternating.
    /// Images are existing OnboardingPosts assets (good posts = 9 of the baked ones, NG = 9 new images
    /// without text)
    static let japanese: [JudgmentItem] = [
        JudgmentItem(image: "run-park-female-pov",       labelJa: "ランニング",   labelEn: "Running",   pass: true),
        JudgmentItem(image: "moderate-pachinko",         labelJa: "ギャンブル",   labelEn: "Gambling",  pass: false),
        JudgmentItem(image: "moderate-izakaya-beer",     labelJa: "飲み会",       labelEn: "Drinking",  pass: false),
        JudgmentItem(image: "study-desk-laptop",         labelJa: "勉強",         labelEn: "Study",     pass: true),
        JudgmentItem(image: "moderate-burger-drivethru", labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "gym-mirror-male",           labelJa: "筋トレ",       labelEn: "Workout",   pass: true),
        JudgmentItem(image: "moderate-karaoke",          labelJa: "夜遊び",       labelEn: "Night out", pass: false),
        JudgmentItem(image: "mealprep-containers",       labelJa: "自炊",         labelEn: "Meal prep", pass: true),
        JudgmentItem(image: "moderate-party-cups",       labelJa: "飲み会",       labelEn: "Partying",  pass: false),
        JudgmentItem(image: "study-cafe-coffee",         labelJa: "読書",         labelEn: "Reading",   pass: true), // Book + cafe image (2026-07-29 changed from "勉強" ("study") to "読書" ("reading"))
        JudgmentItem(image: "moderate-ramen-jiro",       labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "business-laptop",           labelJa: "仕事",         labelEn: "Work",      pass: true),
        JudgmentItem(image: "moderate-bowling",          labelJa: "遊び",         labelEn: "Hanging out", pass: false),
        JudgmentItem(image: "gym-mirror-female",         labelJa: "筋トレ",       labelEn: "Workout",   pass: true),
        JudgmentItem(image: "moderate-movie-popcorn",    labelJa: "夜更かし",     labelEn: "Late night", pass: false),
        JudgmentItem(image: "run-scenery-snapshot",      labelJa: "ランニング",   labelEn: "Running",   pass: true),
        JudgmentItem(image: "moderate-pizza-night",      labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "mealprep-eating-plate",     labelJa: "食事管理",     labelEn: "Nutrition", pass: true),
    ]

    /// English version (12 cards). Excludes images showing Japanese and pachinko; the 2nd card is a party
    static let english: [JudgmentItem] = [
        JudgmentItem(image: "run-park-female-pov",       labelJa: "ランニング",   labelEn: "Running",   pass: true),  // Baked text = "5:20"
        JudgmentItem(image: "moderate-party-cups",       labelJa: "飲み会",       labelEn: "Partying",  pass: false),
        JudgmentItem(image: "moderate-izakaya-beer",     labelJa: "飲み会",       labelEn: "Drinking",  pass: false),
        JudgmentItem(image: "study-desk-laptop",         labelJa: "勉強",         labelEn: "Study",     pass: true),  // Baked text = "HARD WORK"
        JudgmentItem(image: "moderate-burger-drivethru", labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "gym-mirror-female",         labelJa: "筋トレ",       labelEn: "Workout",   pass: true),  // Baked text = "LEG DAY"
        JudgmentItem(image: "moderate-karaoke",          labelJa: "夜遊び",       labelEn: "Night out", pass: false),
        JudgmentItem(image: "moderate-bowling",          labelJa: "遊び",         labelEn: "Hanging out", pass: false),
        JudgmentItem(image: "study-cafe-coffee",         labelJa: "読書",         labelEn: "Reading",   pass: true),  // No baked text
        JudgmentItem(image: "moderate-ramen-jiro",       labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "moderate-movie-popcorn",    labelJa: "夜更かし",     labelEn: "Late night", pass: false),
        JudgmentItem(image: "moderate-pizza-night",      labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
    ]
}

// MARK: - Main view

struct JudgmentFeedView: View {
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// Life of a card: above the screen → drops to the center → scan → verdict decided → exit (pass =
    /// down / reject = sideways)
    private enum Phase {
        case offscreen, center, scanning, verdict, exited
    }

    @State private var index = 0
    @State private var phase: Phase = .offscreen
    /// Travel of the scan light band (0→1). Reset and run each time scanning starts
    @State private var scanProgress: CGFloat = 0

    private var script: [JudgmentItem] { JudgmentScript.items(for: lang) }
    private var item: JudgmentItem { script[index % script.count] }

    var body: some View {
        GeometryReader { geo in
            // Fix for 2026-07-29 real device feedback "too small / the top is cut off":
            // - card width enlarged 0.60→0.68 (relative to the parent frame)
            // - aspect changed from 4:5 to 2:3 (the native ratio of the NG images, so top and bottom are not
            //   cut even with fill). But it is also constrained by height so it fits in the parent (prevents
            //   overflow on small devices)
            let cardW = min(geo.size.width * 0.68, (geo.size.height * 0.92) / 1.5)
            let cardH = cardW * 1.5
            // The center of the parent frame is the stage (meant to be embedded in the moderation screen. The
            // full-screen ignoresSafeArea + top-aligned layout from the old hook screen era was removed)
            let stageCenterY = geo.size.height * 0.5

            ZStack {
                judgedCard(width: cardW, height: cardH)
                    .position(x: geo.size.width / 2 + offsetX(width: geo.size.width),
                              y: stageCenterY + offsetY(height: geo.size.height))
                    .rotationEffect(.degrees(rotation), anchor: .bottomLeading)
                    .opacity(cardOpacity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .task { await runLoop() }
    }

    // MARK: - Card

    private func judgedCard(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if UIImage(named: item.image) != nil {
                    Color.clear.overlay(
                        Image(item.image).resizable().aspectRatio(contentMode: .fill)
                    )
                } else {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            // Once rejected, remove the saturation to make it a "dead" post
            .saturation(phase == .verdict && !item.pass ? 0.15 : 1)
            .overlay(Color.black.opacity(phase == .verdict && !item.pass ? 0.35 : 0))

            // Scan light band (runs once top→bottom only while scanning. The brand principle "motion is light")
            if phase == .scanning {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height * 0.28)
                .offset(y: -height * 0.64 + scanProgress * height * 1.28)
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
            }

            // Verdict chip (bottom left of the card). scanning = label only / verdict = icon + color decided
            if phase == .scanning || phase == .verdict {
                judgmentChip
                    .padding(10)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(chipIsFail ? AppColors.error.opacity(0.6) : Color.white.opacity(0.10),
                        lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private var chipIsFail: Bool { phase == .verdict && !item.pass }
    private var chipIsPass: Bool { phase == .verdict && item.pass }

    private var judgmentChip: some View {
        HStack(spacing: 6) {
            if phase == .verdict {
                Image(systemName: item.pass ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .transition(.scale.combined(with: .opacity))
            } else {
                // Thinking dots during the scan (quiet pulse, no rotating spinner)
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(0.7)
            }

            Text(lang == .japanese ? item.labelJa : item.labelEn)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(phase == .verdict ? .white : AppColors.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            // After the verdict: pass = green / reject = red (2026-07-29 user instruction "make OK the green OK
            // color"). Neutral glass while scanning
            Capsule().fill(
                chipIsFail
                    ? AnyShapeStyle(AppColors.error.opacity(0.92))
                    : chipIsPass
                        ? AnyShapeStyle(AppColors.success.opacity(0.92))
                        : AnyShapeStyle(.ultraThinMaterial)
            )
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Phase → transform

    private func offsetY(height: CGFloat) -> CGFloat {
        switch phase {
        case .offscreen:            return -height * 0.7
        case .center, .scanning, .verdict: return 0
        case .exited:               return item.pass ? height * 0.85 : 0.06 * height
        }
    }

    private func offsetX(width: CGFloat) -> CGFloat {
        // Only the rejected exit is knocked out sideways
        (phase == .exited && !item.pass) ? -width * 1.3 : 0
    }

    private var rotation: Double {
        (phase == .exited && !item.pass) ? -12 : 0
    }

    private var cardOpacity: Double {
        switch phase {
        case .offscreen:  return 0
        case .exited:     return item.pass ? 0 : 0.9
        default:          return 1
        }
    }

    // MARK: - Progress loop

    @MainActor
    private func runLoop() async {
        if UIAccessibility.isReduceMotionEnabled {
            // Static display: just place one card with a pass chip
            phase = .verdict
            return
        }

        // Tempo history: 2.4s (v1 "too slow") → 1.85s ("a bit slower is fine") → about 2.15s per card
        // (2026-07-29 feedback round 3: bring back a pause between scans)
        while !Task.isCancelled {
            // 1. Drop → caught in the center
            phase = .offscreen
            scanProgress = 0
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = .center }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard !Task.isCancelled else { return }

            // 2. Scan (one pass of the light band + the label appears)
            withAnimation(.easeOut(duration: 0.22)) { phase = .scanning }
            withAnimation(.easeInOut(duration: 0.5)) { scanProgress = 1 }
            try? await Task.sleep(nanoseconds: 620_000_000)
            guard !Task.isCancelled else { return }

            // 3. Verdict decided + haptics (pass = light / reject = rigid)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { phase = .verdict }
            if item.pass {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            try? await Task.sleep(nanoseconds: item.pass ? 450_000_000 : 580_000_000)
            guard !Task.isCancelled else { return }

            // 4. Exit (pass = flows into the feed below / reject = knocked out sideways)
            withAnimation(.easeIn(duration: item.pass ? 0.42 : 0.38)) { phase = .exited }
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }

            index += 1
        }
    }
}
