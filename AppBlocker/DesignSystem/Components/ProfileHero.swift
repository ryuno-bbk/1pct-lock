//
//  ProfileHero.swift
//  AppBlocker
//
//  BeReal-style profile hero (spec finalized 2026-07-10).
//  Shared by 3 screens: MyProfileView / UserProfileView / OfficialProfileView.
//    - The avatar image is shown large at full width, with name (largest) → @handle → bio at the
//      bottom left
//    - Below the image: a stats row with followers / following / likes etc.
//    - Wide action button (Follow / Edit profile)
//    - Between the button and the post grid: a 2×2 grid of total lock / streak / completion rate / top
//      percentile (fully consolidated in the 2026-07-16 stats pack. Where BeReal puts its interest chips)
//

import SwiftUI
import UIKit

// MARK: - Data types

// MARK: - Text Outline (BeReal style: a thin black outline on white text over images for readability)

// MARK: - Real text stroke (finalized 2026-07-30)
// SwiftUI's Text has no API for outlines, so this wraps a 2-pass UIKit drawing
// ((1) stroke → (2) fill). All shadow tricks and copy tricks are removed.
// The only tuning points are these 3 constants: color (gray), opacity (alpha), width (pt)

enum HeroTextStrokeStyle {
    /// Outline color (kept opaque; opacity is applied all at once via alpha)
    static let colorOpaque = UIColor(white: 0.12, alpha: 1)
    /// Opacity of the whole outline (0.45→0.32 after 2026-07-30 feedback "a bit lighter")
    static let alpha: CGFloat = 0.32
    /// Outline width (how far it extends outside the glyph, pt)
    static let width: CGFloat = 2.0
}

private final class StrokeLabel: UILabel {
    private let strokeWidth = HeroTextStrokeStyle.width

    // Expand both drawing and sizing outward by the width so the stroke does not overflow the frame and
    // get clipped
    override func drawText(in rect: CGRect) {
        let inset = rect.insetBy(dx: strokeWidth, dy: strokeWidth)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            super.drawText(in: inset)
            return
        }
        let originalColor = textColor
        // (1) Stroke pass: draw "opaque" inside a transparency layer, then apply alpha to the whole layer at once.
        //   Even if edges of adjacent glyphs overlap, inside the layer it is just opaque over opaque and
        //   saturates, so the final darkness is fully uniform (fix for 2026-07-30 feedback "overlaps in
        //   @handle etc. get darker"). Emoji are bitmaps so they are not stroked; they are drawn normally in
        //   the (2) fill pass
        ctx.saveGState()
        ctx.setAlpha(HeroTextStrokeStyle.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(strokeWidth * 2)
        ctx.setLineJoin(.round)
        ctx.setTextDrawingMode(.stroke)
        textColor = HeroTextStrokeStyle.colorOpaque
        super.drawText(in: inset)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // (2) Fill pass
        ctx.setTextDrawingMode(.fill)
        textColor = originalColor
        super.drawText(in: inset)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var s = super.sizeThatFits(CGSize(
            width: max(0, size.width - strokeWidth * 2),
            height: size.height
        ))
        s.width += strokeWidth * 2
        s.height += strokeWidth * 2
        return s
    }
}

/// For text on the hero image. Draws real outlined text from SwiftUI with color, line count and shrink
/// specified
struct StrokedText: UIViewRepresentable {
    let text: String
    let font: UIFont
    var textColor: UIColor = .white
    var lineLimit: Int = 1
    var adjustsFontSize: Bool = false
    var minimumScale: CGFloat = 1.0

    func makeUIView(context: Context) -> UILabel {
        let label = StrokeLabel()
        label.backgroundColor = .clear
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.textColor = textColor
        label.numberOfLines = lineLimit
        label.adjustsFontSizeToFitWidth = adjustsFontSize
        label.minimumScaleFactor = minimumScale
        label.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }
}

struct ProfileHeroStat: Identifiable {
    let value: String
    let label: String
    var gold: Bool = false
    /// Tappable stat (Following → list, etc.). If nil, display only
    var action: (() -> Void)? = nil

    var id: String { label }
}

/// A cell of the stats grid (2026-07-11 medal style → 2026-07-16 made into a 2×2 grid).
/// 2 rows: value (big number) + label (small description). gold = gold decoration only for top percentile.
/// tint = theme color of the icon (2026-07-16 richer look. Only semantic colors from AppColors are allowed,
/// nil means neutral. A gold cell does not need tint; gold takes priority).
/// detail = detail sheet shown on tap (2026-07-17. If nil, display only and not tappable)
struct ProfileHeroChip: Identifiable {
    let icon: String   // SF Symbol
    let value: String
    let label: String
    var gold: Bool = false
    var tint: Color? = nil
    var detail: ProfileHeroChipDetail? = nil

    var id: String { icon + label }
}

/// Content of the detail modal for a stat cell (2026-07-17 user request "tap any badge for an
/// explanation"). description = definition of that stat, rows = extra number rows (e.g. completion rate
/// for last 30 days/all time, top percentile rank). The close button is "OK" for both Japanese and
/// English (default that matches standard dialogs like TikTok's)
struct ProfileHeroChipDetail {
    let title: String
    let description: String
    var rows: [Row] = []
    var okTitle: String = "OK"

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}

// MARK: - Detail modal for stat cells (2026-07-17)
//
// A light centered modal modeled on TikTok's "total likes" dialog (user specified):
// big icon on top → title → description → (number rows) → divider → OK.
// Tapping the background also closes it. We do not use the standard iOS alert because it must hold the
// icon and number rows

private struct ChipDetailModal: View {
    let chip: ProfileHeroChip
    let detail: ProfileHeroChipDetail
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The modal icon also inherits the same theme color as the cell (gold > tint > neutral)
    private var theme: Color {
        chip.gold ? AppColors.gold : (chip.tint ?? AppColors.textSecondary)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)  // Only for a small card (outside the rule that bans scaleEffect on huge Views)
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.opacity(0.14))
                    Image(systemName: chip.icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(theme)
                }
                .frame(width: 72, height: 72)
                .padding(.bottom, 2)

                Text(detail.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(detail.description)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if !detail.rows.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(detail.rows) { row in
                            HStack {
                                Text(row.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer(minLength: 12)
                                Text(row.value)
                                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
                                    .foregroundColor(row.value == "—" ? AppColors.textTertiary : AppColors.textPrimary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppColors.background.opacity(0.5))
                    )
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 20)

            Divider().overlay(Color.white.opacity(0.12))

            Button(action: close) {
                Text(detail.okTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.secondaryBackground)
        )
        .padding(.horizontal, 40)
    }

    private func close() {
        withAnimation(reduceMotion ? .none : .easeIn(duration: 0.15)) { appeared = false }
        // Show the fade-out, then dismiss (dismissing immediately makes it vanish abruptly and it does not
        // feel light)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.15)) { onDismiss() }
    }
}

// MARK: - Hero Header

struct ProfileHeroHeader: View {

    /// Name of the coordinate space set by the parent ScrollView (for the stretch zoom).
    /// Each profile screen must add .coordinateSpace(name: ProfileHeroHeader.scrollSpace) to its ScrollView
    static let scrollSpace = "profileHeroScroll"

    enum HeroImage {
        /// Regular user: avatar_url (placeholder if nil)
        case url(String?)
        /// 1% official account: logo hero
        case onePercent
    }

    /// For localizing the eyebrow text of the TOP badge (this component was designed without lang,
    /// but we follow the precedent of reading @AppStorage directly, like HandleCopyLabel)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    let hero: HeroImage
    let displayName: String
    var isPro: Bool = false
    var isOfficial: Bool = false
    var handle: String? = nil
    var bio: String? = nil
    /// Dream declaration (below the bio). dreamLocked = private mark (owner only)
    var dreamText: String? = nil
    var dreamLocked: Bool = false

    /// Option D (2026-07-30): the number for the gold typographic badge shown only when within TOP10%.
    /// No badge shape; only text in Montserrat BlackItalic, same as the wordmark (to avoid gaudy gold).
    /// It sits "outside" the hero image (directly below, right-aligned). On top of the image it could be faked
    /// by baking it into the hero image (pointed out by the user 2026-07-30). Placing it on the UI surface
    /// is what guarantees it is earned. nil = out of range / not enough data, hidden
    var topPercent: Int? = nil
    /// Action when the TOP badge is tapped (expected to open the stats sheet = the answer to "what is
    /// this?" + real proof with actual data)
    var onTopPercentTap: (() -> Void)? = nil

    /// Rank by total lock time (2026-09-05). Shown as a neutral pill to the right of the top percentile pill.
    /// 🔴 Gold is a brand rule reserved for top percentile, so this one is not gold.
    /// nil = no record / population too small, hidden
    var rank: Int? = nil
    /// Tap on the rank pill (expected to open the ranking screen)
    var onRankTap: (() -> Void)? = nil

    let stats: [ProfileHeroStat]

    /// Wide action button. Hidden if actionTitle is nil (e.g. when viewing yourself on another user's screen)
    var actionTitle: String? = nil
    /// true = filled (not following), false = outlined (following / edit)
    var actionIsProminent: Bool = true
    var actionIcon: String? = nil
    var onAction: (() -> Void)? = nil

    /// Stat chips (2026-07-16 stats pack: fully consolidated into the 2×2 grid below the button.
    /// Assumes 4, but the drawing does not depend on the count. Hidden if empty)
    var chips: [ProfileHeroChip] = []

    /// The tapped stat cell (display state of the detail sheet)
    @State private var detailChip: ProfileHeroChip?

    var body: some View {
        VStack(spacing: 0) {
            heroImage

            VStack(spacing: 14) {
                if let dreamText, !dreamText.isEmpty {
                    HStack(spacing: 5) {
                        if dreamLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textTertiary)
                        }
                        Text(dreamText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                }

                statsRow

                if let actionTitle, let onAction {
                    actionButton(title: actionTitle, action: onAction)
                }

                if !chips.isEmpty {
                    chipsRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // Our own loader for the hero image (2026-07-30). Requirements:
    //   1. Reload when the URL changes (AsyncImage is unreliable here = conclusion of S15)
    //   2. Keep showing the old image while loading or after a failure (do not fall back to the
    //      placeholder right after saving)
    //   3. Right after upload, Storage/CDN may briefly return an error, so retry up to 3 times
    private struct HeroRemoteImage<Placeholder: View>: View {
        let urlString: String
        @ViewBuilder let placeholder: () -> Placeholder

        @State private var image: UIImage?
        @State private var loadedFor: String?
        @State private var loadTask: Task<Void, Never>?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder()
                }
            }
            .onAppear { reload() }
            .onChange(of: urlString) { _, _ in reload() }
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
        }

        private func reload() {
            if loadedFor == urlString, image != nil { return }
            loadTask?.cancel()
            guard let url = URL(string: urlString) else { return }
            loadTask = Task { @MainActor in
                for attempt in 1...3 {
                    if Task.isCancelled { return }
                    if let (data, response) = try? await URLSession.shared.data(from: url),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let loaded = UIImage(data: data) {
                        self.image = loaded
                        self.loadedFor = urlString
                        return
                    }
                    // Retry at 400ms → 800ms → 1200ms intervals (waiting for propagation right after upload)
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt))
                }
                print("⚠️ HeroRemoteImage load failed after retries: \(urlString)")
            }
        }
    }

// MARK: - Hero Image (rounded card + bottom-left text + pull-down stretch zoom)

    private var heroImage: some View {
        Color.clear
            .aspectRatio(1.0 / 1.15, contentMode: .fit)  // slightly tall (close to BeReal)
            .overlay {
                GeometryReader { geo in
                    // minY in the parent ScrollView's coordinate space. 0 at the top, positive when pulled down = stretch
                    // the header by that much
                    let minY = geo.frame(in: .named(Self.scrollSpace)).minY
                    let stretch = max(0, minY)
                    // 2026-07-30 real device feedback: just stretching the frame only "revealed" the top part that
                    // scaledToFill had cropped first, and zoom started only after exceeding the image ratio (2-step behavior).
                    // → Fix the crop at rest (inner frame+clipped) and scale up by the pulled amount =
                    // zoom starts from the first 1px. scaleEffect is limited to the leaf Image (different from the S16 ban
                    // on huge Views)
                    let zoom = 1 + stretch / max(geo.size.height, 1)

                    heroImageContent
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .scaleEffect(zoom, anchor: .bottom)
                        .frame(width: geo.size.width, height: geo.size.height + stretch, alignment: .bottom)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            // Darken the bottom so the text stands out
                            // 2026-07-30 real device feedback: the bottom darkness was also too strong, so eased from 0.75→0.55
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.05), .black.opacity(0.55)],
                                startPoint: .center, endPoint: .bottom
                            )
                        }
                        .overlay(alignment: .bottomLeading) { heroOverlayText }
                        // Following BeReal: the image sits flush with the top edge (no top rounded corners), only the 2 bottom
                        // corners are rounded
                        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                            topLeading: 0, bottomLeading: 24, bottomTrailing: 24, topTrailing: 0
                        )))
                        .offset(y: -stretch)  // Move up by the stretched amount = the image appears to expand upward and zoom
                }
            }
    }

    @ViewBuilder
    private var heroImageContent: some View {
        switch hero {
        case .url(let urlString):
            if let urlString, !urlString.isEmpty {
                // AsyncImage removed (confirmed by S15 + the recurrence in 2026-07-30 real device feedback):
                // a brief error right after upload freezes it in the failure phase, and it neither retries nor keeps
                // the old image, so "the moment you save it goes back to the placeholder and does not recover until
                // restart". Replaced with our own loader based on the same idea as AvatarImage (retry + keep old image)
                HeroRemoteImage(urlString: urlString) { heroPlaceholder }
            } else {
                heroPlaceholder
            }
        case .onePercent:
            // 2026-07-30 real device feedback "the official account background is way too boring": flat #0A0A0B +
            // icon placed directly (2026-07-22 version) → replaced with the same moving smoke (SmokeBackdrop) as
            // the onboarding hero. For the icon, we dropped OnePercentIcon (a square asset = on top of the smoke,
            // the edges of its base color show as a square) and place directly a cut-out white glyph taken from
            // the real icon (HeroClassicGlyph, alpha only). Seams structurally cannot appear. The bottom gradient
            // is handled by the overlay shared by all heroes
            ZStack {
                SmokeBackdrop()
                Image("HeroClassicGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 168, height: 168)
            }
        }
    }

    private var heroPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.fill")
                .font(.system(size: 90, weight: .thin))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // Tap to copy @handle (2026-07-30 real device feedback: wants to paste the ID elsewhere).
    // Copies the raw handle without @ (a form that can be pasted as is into search/SQL).
    // Feedback = press scale (small element only, does not violate the S16 ban on scaleEffect for huge Views)
    // + light haptics + icon changes to a checkmark + a temporary "コピーしました" ("Copied")
    private struct HandleCopyLabel: View {
        let handle: String
        @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
        @State private var copied = false

        private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault }

        var body: some View {
            Button {
                UIPasteboard.general.string = handle
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeIn(duration: 0.25)) { copied = false }
                }
            } label: {
                HStack(spacing: 5) {
                    StrokedText(
                        text: "@\(handle)",
                        font: .systemFont(ofSize: 14, weight: .medium),
                        textColor: UIColor.white.withAlphaComponent(0.9)
                    )
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(copied ? 0.95 : 0.55))
                    if copied {
                        StrokedText(
                            text: lang == .japanese ? "コピーしました" : "Copied",
                            font: .systemFont(ofSize: 11, weight: .semibold),
                            textColor: UIColor.white.withAlphaComponent(0.95)
                        )
                        .transition(.opacity)
                    }
                }
            }
            .buttonStyle(HandleCopyPressStyle())
            .accessibilityLabel(lang == .japanese ? "ユーザーIDをコピー" : "Copy user ID")
        }
    }

    private struct HandleCopyPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .opacity(configuration.isPressed ? 0.75 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// Top percentile badge (rev 8, final user spec 2026-07-30: the grammar of BeReal's streak pill).
    // These 3 are the only tuning points for the gold glass (2026-07-31). Making it darker quickly looks
    // cheap, so do not raise it too much
    /// Gold showing through the glass. Tune between 0.10 and 0.20 (0.14 = the refined side)
    private static let goldTint = AppColors.gold.opacity(0.14)
    /// Hairline on the edge
    private static let goldEdge = AppColors.gold.opacity(0.42)
    /// Text color. Neither pure white nor pure gold: white with a drop of gold
    private static let goldInk = Color(hex: "F6EBD2")

    /// A semi-transparent black capsule + white text above the name. The color-inverted option blended into
    /// real photo backgrounds (white background × bottom gradient) and lost → removed. Eyebrow = mixed
    /// type: Japanese "上位" ("top") in bold system font / English "TOP" in Montserrat; the number + % is
    /// always Montserrat BlackItalic. Tap opens the stats sheet (answer to "what is this?" + real data =
    /// tells it apart from a baked-in fake). Out of range / population too small shows nothing (earned)
    @ViewBuilder
    private var topPercentBadgeView: some View {
        if let topPercent {
            let isJa = (AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault) == .japanese
            let pill = HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(isJa ? "上位" : "TOP")
                    .font(isJa ? .system(size: 11, weight: .heavy) : .custom("Montserrat-BlackItalic", size: 10))
                    .kerning(isJa ? 0 : 1)
                    .opacity(0.9)
                Text("\(topPercent)%")
                    .font(.custom("Montserrat-BlackItalic", size: 16))
            }
            .foregroundColor(Self.goldInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)

            // Pill surface: on iOS 26+ native Liquid Glass (interactive = stretches when pressed, user specified
            // "Apple Native stretchy pill"). Below that, fall back to agar (ultraThinMaterial).
            // 2026-07-31: plain glass → "gold glass" with gold showing through (user request "refined gold").
            // To avoid gaudy gold, add color but keep it light: tint is faint, the text is a very faint gold
            // (neither pure white nor pure gold), and only the edge gets a gold hairline for the outline
            let glassPill = Group {
                if #available(iOS 26.0, *) {
                    pill
                        .glassEffect(.regular.tint(Self.goldTint).interactive())
                        .overlay(Capsule().strokeBorder(Self.goldEdge, lineWidth: 0.6))
                } else {
                    pill
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Self.goldTint, in: Capsule())
                        .overlay(Capsule().strokeBorder(Self.goldEdge, lineWidth: 0.6))
                }
            }

            if let onTopPercentTap {
                Button {
                    // Same light haptics as the handle copy (user specified)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTopPercentTap()
                } label: { glassPill }
                    .buttonStyle(.plain)
                    .accessibilityLabel("上位\(topPercent)パーセント。タップで統計を表示")
            } else {
                glassPill
                    .accessibilityLabel("上位\(topPercent)パーセント")
            }
        }
    }

    /// Rank pill (2026-09-05). Same glass grammar as the top percentile pill but **neutral**.
    /// 🔴 Gold is only for top percentile (brand rule). Using gold here would dilute the meaning of the medal.
    /// Shows only "12位" ("12th") / "#12" (no adjective = user's decision)
    @ViewBuilder
    private var rankPillView: some View {
        if let rank {
            let isJa = (AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault) == .japanese
            let pill = HStack(alignment: .lastTextBaseline, spacing: 2) {
                if !isJa {
                    Text("#")
                        .font(.custom("Montserrat-BlackItalic", size: 11))
                        .opacity(0.9)
                }
                Text("\(rank)")
                    .font(.custom("Montserrat-BlackItalic", size: 16))
                    .monospacedDigit()
                if isJa {
                    Text("位")
                        .font(.system(size: 11, weight: .heavy))
                        .opacity(0.9)
                }
            }
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)

            let glassPill = Group {
                if #available(iOS 26.0, *) {
                    pill
                        .glassEffect(.regular.interactive())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                } else {
                    pill
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                }
            }

            if let onRankTap {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onRankTap()
                } label: { glassPill }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(rank)位。タップでランキングを表示")
            } else {
                glassPill.accessibilityLabel("\(rank)位")
            }
        }
    }

    private var heroOverlayText: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top percentile badge (rev 8): same grammar as BeReal's streak pill: a pill with a semi-transparent
            // black base above the name (user specified 2026-07-30, reference screenshot = 🔥3 on a BeReal profile)
            HStack(spacing: 6) {
                topPercentBadgeView
                rankPillView
            }
            .padding(.bottom, 6)

            HStack(spacing: 7) {
                StrokedText(
                    text: displayName,
                    font: .systemFont(ofSize: 28, weight: .bold),
                    adjustsFontSize: true,
                    minimumScale: 0.6
                )

                if isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.blue)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        // ProfileHero has no lang, so it stays fixed to Japanese as in the old code (the change scope of this
                        // file is a11y only)
                        .accessibilityLabel("公式")
                }

            }

            if let handle, !handle.isEmpty {
                HandleCopyLabel(handle: handle)
            }

            if let bio, !bio.isEmpty {
                // 🔴 Bios already saved with line breaks do exist in production (confirmed 2026-09-09).
                //    This spot shows only 2 lines, so passing the line breaks through would drop everything from line
                //    2 on. Collapse them into spaces on the display side too, and let the lines wrap normally
                let flatBio = bio.split(whereSeparator: \.isNewline).joined(separator: " ")
                StrokedText(
                    text: flatBio,
                    font: .systemFont(ofSize: 13),
                    textColor: UIColor.white.withAlphaComponent(0.85),
                    lineLimit: 2
                )
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(stats) { stat in
                Group {
                    if let action = stat.action {
                        Button(action: action) { statContent(stat) }
                            .buttonStyle(PlainButtonStyle())
                    } else {
                        statContent(stat)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func statContent(_ stat: ProfileHeroStat) -> some View {
        VStack(spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(stat.gold
                    ? (stat.value == "—" ? AppColors.textTertiary : AppColors.gold)
                    : AppColors.textPrimary)
            Text(stat.label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - Action Button (wide, BeReal style. When following, the icon bounces plus→checkmark)

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let actionIcon {
                    Image(systemName: actionIcon)
                        .font(.system(size: 14, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(actionIsProminent ? AppColors.background : AppColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(actionIsProminent ? AppColors.textPrimary : AppColors.cardBackground)
            )
            .overlay(
                Capsule()
                    .stroke(actionIsProminent ? Color.clear : AppColors.textTertiary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        // Animate changes of actionIcon / actionIsProminent / title (follow completed)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: actionIcon)
    }

    // MARK: - Chips (2026-07-16 stats pack: total lock / streak / completion rate / top percentile fully
    // consolidated into a 2×2 grid)
    //
    // One size larger, as the pride metrics of a discipline app, in 2 rows with the number as the focus.
    // Top percentile (gold) is a medal with a thin gold frame + gold text. Under the brand rule, gold is
    // allowed only for this use. Assumes 4, but the drawing does not depend on the count (a VStack that
    // places 2 items per row)

    private var chipsRow: some View {
        let rows = stride(from: 0, to: chips.count, by: 2).map { start in
            Array(chips[start..<min(start + 2, chips.count)])
        }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowChips in
                HStack(spacing: 10) {
                    ForEach(rowChips) { chip in
                        if chip.detail != nil {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                detailChip = chip
                            } label: {
                                chipCell(chip)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            chipCell(chip)
                        }
                    }
                }
            }
        }
        // A light centered alert-style modal (user specified 2026-07-17: TikTok's "total likes" dialog).
        // To float it in the center of the screen instead of a bottom sheet, it is placed in a fullScreenCover
        // with a transparent background
        .fullScreenCover(item: $detailChip) { chip in
            if let detail = chip.detail {
                ChipDetailModal(chip: chip, detail: detail) { detailChip = nil }
                    .presentationBackground(.clear)
            }
        }
        // Kill the default "slide up from the bottom" of fullScreenCover. Without turning it off,
        // the centered modal rises from the bottom of the screen and does not have the immediacy of an alert
        // (the appear/disappear animation is handled by the fade + scale inside ChipDetailModal)
        .transaction { $0.disablesAnimations = true }
    }

    private func chipCell(_ chip: ProfileHeroChip) -> some View {
        let isEmpty = chip.value == "—"
        // Always keep the icon's theme color whether or not there is a value (2026-07-17 real device feedback:
        // before, the dash placeholder (U+2014) also turned the icon neutral, so it did not match the detail
        // modal (always colored) and it looked like "only the profile has no color").
        // Only the number side turns neutral (missing data is about the value, not what the icon stands for)
        let theme: Color = chip.gold ? AppColors.gold : (chip.tint ?? AppColors.textSecondary)
        let valueColor = isEmpty ? AppColors.textTertiary
            : (chip.gold ? AppColors.gold : AppColors.textPrimary)

        return HStack(spacing: 10) {
            // Put the icon in a rounded container with a light color base (2026-07-16 richer look)
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.opacity(0.16))
                Image(systemName: chip.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.value)
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundColor(valueColor)
                Text(chip.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(chip.gold && !isEmpty
                        ? AppColors.gold.opacity(0.75)
                        : AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Expand to full width inside the card (background). If expanded outside,
        // the card itself keeps its intrinsic width and floats in the center of the column, so the 2×2 cell
        // widths become uneven
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(chip.gold && !isEmpty ? AppColors.gold.opacity(0.08) : AppColors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    chip.gold && !isEmpty ? AppColors.gold.opacity(0.45) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Stats sheet (2026-07-30 real device feedback "way too shabby" → made into a shared component
// + upgraded) The focus depends on the entry point: tap total lock = lock time is the hero / tap the
// top percentile pill = top percentile is the hero. The hero number uses Montserrat BlackItalic, same
// as the wordmark. Gold decoration was removed after 2026-07-30 real device feedback (the sheet is
// neutral throughout)

struct ProfileStatsSheetRow: Identifiable {
    /// Simple black-and-white SF Symbol name (2026-07-30 real device feedback "can you add black-and-white
    /// icons?")
    let icon: String
    let label: String
    let value: String
    /// A row that sends you to another screen on tap (2026-09-09: rank row → ranking). If nil, display only
    var action: (() -> Void)? = nil
    var id: String { label }
}

struct ProfileStatsSheet: View {
    // It is Identifiable so it can be shown with sheet(item:) (2026-07-30 real device feedback: the
    // combination of sheet(isPresented:)+ a separate @State had a bug where the first presentation was
    // drawn with the state before the focus change)
    enum Focus: Identifiable {
        case lockTime
        case topPercent
        var id: Self { self }
    }

    let focus: Focus
    let lockTimeText: String
    /// A number if within TOP10%. Out of range / not enough data is nil → falls back to topPercentText
    let topPercentValue: Int?
    let topPercentText: String
    let rows: [ProfileStatsSheetRow]

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }
    private var isJa: Bool { lang == .japanese }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(AppColors.textTertiary.opacity(0.4))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            // Hero number (the stat from the entry point is the focus)
            VStack(alignment: .leading, spacing: 6) {
                // For the top percentile focus, the heading is the description itself, not "上位%" ("top %") (2026-07-30
                // real device feedback: answer "top 3% in what?" at the very top)
                Text(focus == .lockTime ? L.profileLockTime(lang) : L.statSheetTopPercentHeader(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.2)
                    .foregroundColor(AppColors.textTertiary)
                    .textCase(.uppercase)

                switch focus {
                case .lockTime:
                    Text(lockTimeText)
                        .font(.custom("Montserrat-BlackItalic", size: 46))
                        .foregroundColor(AppColors.textPrimary)
                case .topPercent:
                    if let v = topPercentValue {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(isJa ? "上位" : "TOP")
                                .font(isJa ? .system(size: 20, weight: .heavy) : .custom("Montserrat-BlackItalic", size: 18))
                                .foregroundColor(AppColors.textSecondary)
                            Text("\(v)%")
                                .font(.custom("Montserrat-BlackItalic", size: 46))
                                .foregroundColor(AppColors.textPrimary)
                        }
                    } else {
                        Text(topPercentText)
                            .font(.custom("Montserrat-BlackItalic", size: 46))
                            .foregroundColor(AppColors.textPrimary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Rectangle()
                .fill(AppColors.textTertiary.opacity(0.14))
                .frame(height: 0.5)
                .padding(.horizontal, 24)
                .padding(.top, 20)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    let line = HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textTertiary)
                            .frame(width: 20, alignment: .center)
                        Text(row.label)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Text(row.value)
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(AppColors.textPrimary)
                        // Show a chevron only on tappable rows (so it is clear they can be pressed)
                        if row.action != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                    Group {
                        if let action = row.action {
                            Button(action: action) { line.contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                        } else {
                            line
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(AppColors.textTertiary.opacity(0.10))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}
