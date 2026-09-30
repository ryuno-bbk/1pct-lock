//
//  OnboardingHook.swift
//  AppBlocker
//
//  Diagnostic onboarding PHASE 0: hook of the splash (monogram launch animation) and
//  the feed preview (vertical loop of AI-generated posts).
//
//  - The monogram is drawn directly as shapes, not from the icon PNG (same as b1Mark in AreteWatermark,
//    in viewBox 100 units: bar x44 y20 w12 h60 rx6 / dots r9.5 centers (26,31),(74,69))
//  - The feed preview shows "OnboardingFeed1" to "OnboardingFeed6" from Assets.
//    While the images are not added, it falls back to a monochrome gradient so development is not blocked
//

import SwiftUI

// MARK: - 1. Splash (monogram launch)

struct MonogramSplashView: View {
    let onContinue: () -> Void

    // Stages of the "engraving" animation (fully renewed 2026-07-17. The old snap-in animation where "the
    // dots fly in from the diagonal" was rejected by user feedback as "lame" → changed direction: elements
    // do not move, they come into focus in place)
    @State private var barGrown = false
    @State private var dot1Shown = false
    @State private var dot2Shown = false
    @State private var settled = false
    @State private var showWordmark = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            SplashMonogram(
                barGrown: barGrown,
                dot1Shown: dot1Shown,
                dot2Shown: dot2Shown,
                settled: settled,
                size: 108
            )

            Text("1%")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .opacity(showWordmark ? 1 : 0)
                .offset(y: showWordmark ? 0 : 6)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if UIAccessibility.isReduceMotionEnabled {
                barGrown = true; dot1Shown = true; dot2Shown = true
                settled = true; showWordmark = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onContinue() }
                return
            }
            // 1. The vertical bar grows quickly from the center (easeOutExpo-like curve)
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                barGrown = true
            }
            // 2. The dots do not fly in: they come into focus from a blur in place (two, staggered)
            withAnimation(.easeOut(duration: 0.45).delay(0.4)) { dot1Shown = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.58)) { dot2Shown = true }
            // 3. The whole mark sinks slightly and is "set down" + one haptic
            withAnimation(.easeOut(duration: 0.45).delay(1.0)) { settled = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                QuizHaptics.light()
            }
            // 4. The wordmark rises up from below
            withAnimation(.easeOut(duration: 0.4).delay(1.15)) {
                showWordmark = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                onContinue()
            }
        }
    }
}

/// Monogram only for the splash (for the engraving choreography).
/// The geometry is the same as MonogramMark (viewBox 100: vertical bar 50,50/w12h60, dots r9.5
/// @(26,31)(74,69)), but it has parameters to show the dots with "blur → focus"
/// (blur+scale+opacity) instead of movement.
/// The general MonogramMark is used elsewhere (the loader's mask etc.), so it is not touched
private struct SplashMonogram: View {
    let barGrown: Bool
    let dot1Shown: Bool
    let dot2Shown: Bool
    let settled: Bool
    let size: CGFloat

    var body: some View {
        let s = size / 100

        ZStack {
            RoundedRectangle(cornerRadius: 6 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 12 * s, height: 60 * s)
                .scaleEffect(y: barGrown ? 1 : 0.02, anchor: .center)
                .position(x: 50 * s, y: 50 * s)

            dot(x: 26, y: 31, shown: dot1Shown, s: s)
            dot(x: 74, y: 69, shown: dot2Shown, s: s)
        }
        .frame(width: size, height: size)
        // After coming into focus, it sinks slightly to 1x (a "set down" feel). Exempt from the ban on
        // scaleEffect on huge Views (S16)
        .scaleEffect(settled ? 1.0 : 1.03)
    }

    private func dot(x: CGFloat, y: CGFloat, shown: Bool, s: CGFloat) -> some View {
        Circle()
            .fill(AppColors.textPrimary)
            .frame(width: 19 * s, height: 19 * s)
            .scaleEffect(shown ? 1 : 1.45)
            .blur(radius: shown ? 0 : 5)
            .opacity(shown ? 1 : 0)
            .position(x: x * s, y: y * s)
    }
}

/// Bold monogram (added 2026-07-29 for the hero screen). Same family of proportions as the primary
/// icon "Classic" (bold monogram): the bar and dots are thicker than in MonogramMark.
/// It is drawn as vectors, so it does not hide the background (smoke) behind a square (placing the icon
/// PNG directly would make a black tile block the smoke)
struct MonogramMarkBold: View {
    let size: CGFloat

    var body: some View {
        let s = size / 100

        ZStack {
            // Vertical bar: width 12→20, thicker rounded corners too
            RoundedRectangle(cornerRadius: 10 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 20 * s, height: 62 * s)
                .position(x: 50 * s, y: 50 * s)

            // Dots: r9.5→r13
            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 26 * s, height: 26 * s)
                .position(x: 24 * s, y: 28 * s)

            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 26 * s, height: 26 * s)
                .position(x: 76 * s, y: 72 * s)
        }
        .frame(width: size, height: size)
    }
}

/// 1% monogram (vertical bar + 2 diagonal dots). While assembled=false, the dots are scattered outside
/// the diagonal
struct MonogramMark: View {
    let assembled: Bool
    let size: CGFloat

    var body: some View {
        let s = size / 100   // In viewBox 100 units

        ZStack {
            // Vertical bar (x44 y20 w12 h60 rx6)
            RoundedRectangle(cornerRadius: 6 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 12 * s, height: 60 * s)
                .scaleEffect(y: assembled ? 1 : 0.01, anchor: .center)
                .position(x: 50 * s, y: 50 * s)

            // Dots (r9.5, centers (26,31) / (74,69))
            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 19 * s, height: 19 * s)
                .position(x: 26 * s, y: 31 * s)
                .offset(x: assembled ? 0 : -46 * s, y: assembled ? 0 : -46 * s)
                .opacity(assembled ? 1 : 0)

            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 19 * s, height: 19 * s)
                .position(x: 74 * s, y: 69 * s)
                .offset(x: assembled ? 0 : 46 * s, y: assembled ? 0 : 46 * s)
                .opacity(assembled ? 1 : 0)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Post image assets (the text is already baked into the images)

/// One post in the feed preview. The image has the text baked in and is shown square.
/// username / title / likes / comments are dummies (assigned by Fable). likes / comments are not used
/// for display (the reaction counts were removed on 2026-09-26. See HookPostCard).
/// avatar is the name of an icon asset the user will send later (a placeholder is shown if nil).
struct HookFeedPost: Identifiable {
    let id = UUID()
    let image: String
    let username: String
    let title: String
    let likes: Int
    let comments: Int
    var avatar: String? = nil
}

/// 13 "good posts" shown in the feed preview (Assets/OnboardingPosts).
/// For the baked-in text see Docs/onboarding_image_prompts.md. If missing, falls back to a gradient
enum OnboardingFeedAssets {
    static let good: [HookFeedPost] = [
        HookFeedPost(image: "gym-mirror-female",     username: "@rina_lifts", title: "脚の日は逃げない。今日も潰してきた", likes: 214, comments: 18),
        HookFeedPost(image: "mealprep-containers",   username: "@kenta_fuel", title: "日曜の30分で平日が決まる",          likes: 156, comments: 9),
        HookFeedPost(image: "study-desk-laptop",     username: "@sho_study",  title: "テスト2週間前。ここからが本番",      likes: 302, comments: 24),
        HookFeedPost(image: "run-park-female-pov",   username: "@miku_runs",  title: "朝の街はまだ静か。5kmだけ",          likes: 189, comments: 11),
        HookFeedPost(image: "gym-mirror-male",       username: "@takumi_gym", title: "腕の日。パンプが正義",              likes: 271, comments: 15),
        HookFeedPost(image: "business-laptop",       username: "@yuto_biz",   title: "スーツに着替えた。勝ってくる",       likes: 98,  comments: 6),
        HookFeedPost(image: "study-book-only",       username: "@nao_kei",    title: "眠い。でも夢の方が強い",            likes: 233, comments: 20),
        HookFeedPost(image: "mealprep-eating-plate", username: "@gym_daily",  title: "食う。走る。読む。以上",            likes: 145, comments: 8),
        HookFeedPost(image: "run-scenery-snapshot",  username: "@run_sora",   title: "誰もいない朝を独り占め",            likes: 176, comments: 10),
        HookFeedPost(image: "gym-mirror-foreign",    username: "@leo_fit",    title: "Chest day. No excuses",           likes: 320, comments: 22),
        HookFeedPost(image: "gym-equipment-only",    username: "@iron_note",  title: "仕事終わり。ジムが一日の締め",       likes: 134, comments: 7),
        HookFeedPost(image: "study-cafe-coffee",     username: "@mari_reads", title: "カフェで2時間。集中できた",         likes: 121, comments: 9),
        HookFeedPost(image: "business-stock-chart",  username: "@invest_k",   title: "淡々と積み立てるだけ",              likes: 88,  comments: 5)
    ]
    /// 9 "to be removed" images shown on the moderation page (fully replaced on 2026-07-29 with new
    /// material provided by the user. The old 6 had Japanese text baked in and looked unnatural to overseas
    /// users → the new material has no text at all and is shared by JP/EN. They are ordered so that the
    /// same category is never adjacent: alcohol/gambling/junk food/play/staying up late alternate)
    static let moderate: [String] = [
        "moderate-izakaya-beer",      // Izakaya beer toast (JP)
        "moderate-pachinko",          // Pachinko (gambling)
        "moderate-burger-drivethru",  // Burger in a car
        "moderate-karaoke",           // Karaoke
        "moderate-party-cups",        // House party red cups (overseas)
        "moderate-ramen-jiro",        // Jiro-style ramen (JP)
        "moderate-bowling",           // Bowling
        "moderate-movie-popcorn",     // Late-night movie + popcorn
        "moderate-pizza-night"        // Pizza + movie
    ]
    // Old assets (moderate-drinking-izakaya-toast / moderate-junkfood-burger /
    // moderate-game-controller / moderate-drinking-bar / moderate-junkfood-chips /
    // moderate-game-desk) are left in Assets, unreferenced. Delete only after the user confirms
}

// MARK: - 2. Feed preview (hook)

struct FeedPreviewHookView: View {
    let onStart: () -> Void
    let onAlreadyHasAccount: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// Ken Burns effect on the background (very slow zoom). 1.06→1.0 on onAppear
    @State private var backdropSettled = false
    @State private var showWordmark = false
    @State private var showTagline = false

    var body: some View {
        ZStack {
            // ARISE-style hero (fully renewed 2026-07-29, user-specified. Reference = the first view of overseas
            // motivation apps: atmospheric background + huge wordmark in the center + tagline + white pill CTA).
            // The judgment animation (JudgmentFeedView) was moved to the moderation screen.
            heroBackdrop

            // Dark overlay: keeps the wordmark and CTA readable (darkens the top and bottom)
            LinearGradient(
                colors: [
                    AppColors.background.opacity(0.55),
                    AppColors.background.opacity(0.15),
                    AppColors.background.opacity(0.30),
                    AppColors.background.opacity(0.92)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top: the "cut-out" glyph of the Classic icon (settled in real-device feedback round 5 on 2026-07-29:
                // placing the tile directly was rejected because "the top looks like an app icon" → a pure white glyph
                // cut out from the real icon PNG with a luminance→alpha conversion (HeroClassicGlyph imageset, the
                // generation script is PIL, see memory notes). It comes from the real icon, so by structure the dot
                // ratios cannot be off
                Image("HeroClassicGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 54)
                    .padding(.top, 18)

                Spacer()

                // Center: huge wordmark (Montserrat Black Italic = a heavy italic display face in the ARISE style.
                // OFL license, registered via Resources/Fonts + Info.plist UIAppFonts.
                // ⚠️ Wordmark only: do not use it for UI body text (the font consistency rule keeps the system font).
                // In environments where the font is not registered, Font.custom falls back to the system font
                // automatically)
                // Entrance = the brand's "blur → focus" pattern (blur 8→0 + sink 18pt + 0.96→1x, 0.9s)
                Text("1%")
                    .font(.custom("Montserrat-BlackItalic", size: 104))
                    .foregroundColor(AppColors.textPrimary)
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 4)
                    .opacity(showWordmark ? 1 : 0)
                    .blur(radius: showWordmark ? 0 : 8)
                    .scaleEffect(showWordmark ? 1 : 0.96)
                    .offset(y: showWordmark ? 0 : 18)

                // Tagline: English = "Not for everyone.", confirmed by the user (2026-07-29).
                // Japanese is still under consideration, so the same sentence is used for now. Candidate: "the social
                // network for the top 1%" (the user's words)
                Text("Not for everyone.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .opacity(showTagline ? 1 : 0)
                    .blur(radius: showTagline ? 0 : 5)
                    .offset(y: showTagline ? 0 : 14)

                Spacer()

                PrimaryButton(lang == .japanese ? "始める" : "Get Started", icon: "arrow.right") {
                    onStart()
                }
                .padding(.horizontal, 24)

                Button(action: onAlreadyHasAccount) {
                    Text(lang == .japanese ? "すでにアカウントを持っている" : "I already have an account")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                        .underline()
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            guard !UIAccessibility.isReduceMotionEnabled else {
                backdropSettled = true; showWordmark = true; showTagline = true
                return
            }
            // Background: a very slow zoom out (Ken Burns).
            // Text: blur → focus + rise, in stages (2026-07-29 feedback "make it stand out more" → longer timing
            // and deeper staggering. With the splash removed, this became the first thing the app shows)
            withAnimation(.easeOut(duration: 14)) { backdropSettled = true }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(0.25)) { showWordmark = true }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.85).delay(0.65)) { showTagline = true }
        }
    }

    /// Background art. If you add a "HeroBackdrop" imageset to Assets, it is shown automatically
    /// (the user plans to generate it with AI, 2026-07-29). Until it is added, it falls back to **moving
    /// smoke** (procedural FBM in HeroSmoke.metal, no video asset needed, infinite loop) + a faint glow in
    /// the center
    @ViewBuilder
    private var heroBackdrop: some View {
        if UIImage(named: "HeroBackdrop") != nil {
            Color.clear.overlay(
                Image("HeroBackdrop")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(backdropSettled ? 1.0 : 1.06)
            )
            .ignoresSafeArea()
        } else {
            SmokeBackdrop()
                .ignoresSafeArea()
        }
    }
}

// SmokeBackdrop was moved to DesignSystem/Components/SmokeBackdrop.swift for sharing (2026-07-30,
// because it is also used in the official profile hero. Implementation and look unchanged)

/// An infinite loop where cardless post UI modeled on the real feed (FeedListCard) (header = avatar +
/// name / 4:5 image / like and comment icons overlaid inside the image) keeps flowing slowly vertically.
///
/// Seamless loop implementation: stack 2 sets of the card column vertically, and after scrolling at a
/// constant speed by exactly one set's height (setHeight), rewind offset to 0. The rewind target
/// (offset=0, top of set 1) and the rewind source (offset=-setHeight, top of set 2) have exactly the
/// same content, so no switch is visible. The key point is that setHeight must match "the actually
/// laid-out height of one set" exactly: a hand-calculated estimate is off by a few pt because of
/// font/line-spacing errors, and at that point it looks like it "teleports" for a moment. So the height
/// of set 1 is measured with a PreferenceKey, and the estimate is used as a fallback until the measured
/// value arrives.
private struct FeedMarquee: View {
    let posts: [HookFeedPost]

    private let gap: CGFloat = 14
    private let hPadding: CGFloat = 16
    private var duration: Double { Double(posts.count) * 4.6 }

    /// Start time of the animation. Converting context.date (wall clock) to elapsed time instead of using it
    /// as is removes room for floating-point error from large absolute time values
    @State private var startDate = Date()
    /// Measured height of one set. Until it arrives, the estimate (estimatedSetHeight below) is used for the
    /// fallback display
    @State private var measuredSetHeight: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width - hPadding * 2
            // Images are 4:5. Card height estimate = header (~42: avatar 30 + spacing) + image (cardW*5/4)
            let imgH = cardW * 5.0 / 4.0
            let estimatedSetHeight = CGFloat(posts.count) * (imgH + 42 + gap)
            let setHeight = measuredSetHeight ?? estimatedSetHeight

            Group {
                if UIAccessibility.isReduceMotionEnabled {
                    cardStack(imgW: cardW, imgH: imgH)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let elapsed = context.date.timeIntervalSince(startDate)
                        let t = elapsed.truncatingRemainder(dividingBy: duration) / duration
                        VStack(spacing: gap) {
                            measuredCardStack(imgW: cardW, imgH: imgH)
                            cardStack(imgW: cardW, imgH: imgH)
                        }
                        .offset(y: -setHeight * CGFloat(t))
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func cardStack(imgW: CGFloat, imgH: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(posts) { post in
                HookPostCard(post: post, imgW: imgW, imgH: imgH)
            }
        }
        .padding(.horizontal, hPadding)
    }

    /// Equivalent to set 1. Measures the actually laid-out height via a PreferenceKey and reflects it into
    /// measuredSetHeight
    private func measuredCardStack(imgW: CGFloat, imgH: CGFloat) -> some View {
        cardStack(imgW: imgW, imgH: imgH)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeSetHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(MarqueeSetHeightKey.self) { height in
                if height > 0 { measuredSetHeight = height }
            }
    }
}

/// PreferenceKey that passes the measured height of one FeedMarquee set from child to parent
private struct MarqueeSetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A card that follows the visual style of the real feed (FeedListCard, 2026-07-10 cardless spec):
/// the header (avatar + name) is placed outside and above the image, no card background/border,
/// only the image has rounded corners 18, the image is fit + blurred fill of the same image, like ♥ /
/// comment 💬 are overlaid as icons only at the bottom right inside the image, and an "例" ("Example")
/// badge sits at the bottom left inside the image.
/// Avatars will be provided by the user (shown if the asset exists, otherwise a placeholder). No
/// network, self-contained.
/// 2026-09-26: removed the display of made-up reaction counts (likes from a few hundred to about
/// 80,000 / comments from a few dozen to about 4,200), and replaced the bottom-left badge with the "例"
/// ("Example") label (so it does not look like real posts/reactions. The numbers are not filled with
/// other values)
private struct HookPostCard: View {
    let post: HookFeedPost
    let imgW: CGFloat
    let imgH: CGFloat

    // For choosing the language of the "例" ("Example") badge: reads the same AppStorage key as
    // FeedPreviewHookView directly (the init signature is not changed = lang is not added as an argument)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: avatar + user name (outside the image. Cardless, so no background/border)
            HStack(spacing: 9) {
                avatar
                Text(post.username)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            // 4:5 image frame. The whole image is shown (not cut off = scaledToFit).
            // The remaining space is filled with a blur of the same image (IG/BeReal style with no black bars).
            // Only the image has rounded corners
            ZStack {
                if UIImage(named: post.image) != nil {
                    Image(post.image).resizable().scaledToFill()
                        .frame(width: imgW, height: imgH).clipped().blur(radius: 18).opacity(0.55)
                        // The blur is recomputed every frame by the marquee driven by TimelineView at 30fps and its GPU cost
                        // is high, so only this layer is rasterized once offscreen with Metal
                        // (the same kind of cost as the S16 10fps incident. Looks the same, affects only this layer. Same
                        // pattern as imageFitBlur in FeedListCard.swift)
                        .drawingGroup()
                    Image(post.image).resizable().scaledToFit()
                        .frame(width: imgW, height: imgH)
                } else {
                    LinearGradient(colors: [Color(white: 0.26), Color(white: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: imgW, height: imgH)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) { exampleBadge }
            .overlay(alignment: .bottomTrailing) { actionIcons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bottom left inside the image: "例" ("Example") badge (same position and look as the old like-count
    /// badge. The number was removed on 2026-09-26)
    private var exampleBadge: some View {
        Text(lang == .japanese ? "例" : "Example") // Text waiting for user review
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(10)
    }

    /// Bottom right inside the image: like + comment (same BeReal-style icon-only overlay as the real feed).
    /// The count numbers under the icons (made-up values) were removed on 2026-09-26. No numbers are shown
    private var actionIcons: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 25))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(width: 40, height: 32)
            }
            .frame(width: 40)

            VStack(spacing: 2) {
                Image(systemName: "ellipsis.bubble.fill")
                    .font(.system(size: 23))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(width: 40, height: 32)
            }
            .frame(width: 40)
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var avatar: some View {
        if let name = post.avatar, UIImage(named: name) != nil {
            Image(name).resizable().scaledToFill()
                .frame(width: 30, height: 30).clipShape(Circle())
        } else {
            // Placeholder until the user sends icons (initial of the name)
            Circle()
                .fill(AppColors.secondaryBackground)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(post.username.dropFirst().prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppColors.textSecondary)
                )
        }
    }
}
