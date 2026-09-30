//
//  QuoteCardView.swift
//  AppBlocker
//
//  Typography card for official quotes (2026-07-30 real device feedback: dropped photo backgrounds
//  entirely and changed direction to Pinterest-style "plain paper-like background × typography
//  only". Screenshots provided by the user are the model).
//
//  Font policy (same day, feedback round 2: "System fonts look mechanical and lame. Unusual fonts
//  are fine"):
//  - SF (system sans serif) is not the lead. The bar to pass = the leftmost serif in the post editor
//    (New York Bold). Built around that with distinctive built-in iOS fonts (Didot / Bodoni 72 /
//    Baskerville / Futura / American Typewriter / Avenir Next UltraLight). All built into the
//    device = no bundling, fallback with a UIFont(name:) existence check (same style as the editor)
//  - For Japanese, a Latin-only font silently falls back to Hiragino Sans and the "mechanical"
//    look comes back, so each template specifies it explicitly. The base is Hiragino Mincho (W3/W6).
//    Montserrat is not used because it is reserved for the wordmark by rule
//  - Assignment is deterministic by a hash of the quote ID. ⚠️ Only appending to the end of the
//    template array is safe
//  - Line breaks: QuoteTypography.displayText (Japanese = break at sentence ends + commas, strength
//    per template / English = by sentence, list type only)
//  - All sizes are ratios of the card width: feed 4:5 / grid thumbnail / share 1080×1920 are
//    similar shapes
//

import SwiftUI

// MARK: - Template

struct QuoteCardTemplate {
    /// Font family (bundles a pair of English font × Japanese font)
    enum Family {
        /// New York Black/Bold (a stronger version of the editor's leftmost serif) × Hiragino Mincho W6
        case serifBlack
        /// New York Bold × Hiragino Mincho W6
        case serifBold
        /// Baskerville (bookish) × Hiragino Mincho W3
        case baskerville
        /// Didot (Vogue-style high contrast) × Hiragino Mincho W6
        case didot
        /// Bodoni 72 Book Italic (elegant italic) × Hiragino Mincho W3
        case bodoniItalic
        /// Futura Medium (Nike/Supreme-style geometric) × Hiragino Kaku Gothic W6 equivalent
        case futura
        /// Futura Condensed ExtraBold (tight headline) × Hiragino Kaku Gothic W8 equivalent
        case futuraCondensed
        /// American Typewriter × Hiragino Mincho W3 (stand-in for a Japanese typewriter)
        case typewriter
        /// Avenir Next UltraLight (the editor's time font) × Hiragino Kaku Gothic W3 equivalent
        case avenirThin
    }

    let background: Color
    let ink: Color
    let family: Family
    /// Main text font size = card width × this factor
    let sizeFactor: CGFloat
    /// Uppercase English only (not applied to Japanese)
    var uppercased: Bool = false
    /// Letter spacing = card width × this factor
    var kerningFactor: CGFloat = 0
    /// Line spacing = card width × this factor
    var lineSpacingFactor: CGFloat = 0.02
    var textAlignment: TextAlignment = .center
    /// Where the text block is placed
    var anchor: Alignment = .center
    /// Padding = card width × this factor
    var paddingFactor: CGFloat = 0.10
    /// Target characters per line for Japanese (sentences longer than this are broken at commas)
    var maxLineLength: Int = 14
    /// Break English into lines by sentence too (list type)
    var splitEnSentences: Bool = false
    /// Dark background template (used by overlays such as the watermark to decide their color)
    var isDark: Bool = false

    var horizontalAlignment: HorizontalAlignment {
        switch textAlignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Card View

struct QuoteCardView: View {
    let primary: String
    let secondary: String?
    /// Seed for template assignment (quote ID). The same ID always gets the same template
    let seedId: UUID
    /// For future manual selection (once a quotes.template column is added, feed it in here). nil = hash
    /// assignment
    var templateOverride: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = Self.template(for: seedId, override: templateOverride)
            // Line breaks first (2026-07-30 feedback round 2: "prefer line breaks over making it bigger"):
            // fix the line structure (meaning boundaries) first, then shrink the font size until the longest line
            // fits the card width. "Odd line breaks" that wrap mid-line structurally cannot happen
            let lines = QuoteTypography.displayLines(primary, maxLineLength: t.maxLineLength,
                                                     splitEnglishSentences: t.splitEnSentences)
            let primarySize = Self.fittedSize(for: lines, template: t, width: w,
                                              isJapanese: QuoteTypography.containsJapanese(primary))
            ZStack {
                t.background

                VStack(alignment: t.horizontalAlignment, spacing: w * 0.05) {
                    Text(displayPrimary(t, lines: lines))
                        .font(Self.font(t.family, size: primarySize, text: primary))
                        .foregroundColor(t.ink)
                        .multilineTextAlignment(t.textAlignment)
                        .kerning(w * t.kerningFactor)
                        .lineSpacing(w * t.lineSpacingFactor)
                        .minimumScaleFactor(0.7)

                    if let secondary, !secondary.isEmpty {
                        Text(QuoteTypography.displayText(secondary, maxLineLength: t.maxLineLength + 6,
                                                         splitEnglishSentences: false))
                            .font(Self.font(t.family, size: w * 0.034, text: secondary))
                            .foregroundColor(t.ink.opacity(0.45))
                            .multilineTextAlignment(t.textAlignment)
                            .lineSpacing(w * 0.012)
                            .minimumScaleFactor(0.6)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: t.anchor)
                .padding(w * t.paddingFactor)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func displayPrimary(_ t: QuoteCardTemplate, lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        if t.uppercased && !QuoteTypography.containsJapanese(text) {
            text = text.uppercased()
        }
        return text
    }

    /// Font size at which the longest line fits the card width (measured, minus padding). The design size
    /// is the upper limit. Japanese = full-width, so character width ≈ font size. English uses an
    /// estimate of the average character width (the final guard is minimumScaleFactor). Natural wrapping
    /// in English (still one line) is not estimated; the design size is used
    private static func fittedSize(for lines: [String], template t: QuoteCardTemplate,
                                   width w: CGFloat, isJapanese: Bool) -> CGFloat {
        let designSize = w * t.sizeFactor
        let usable = w * (1 - 2 * t.paddingFactor)
        guard let longest = lines.map({ $0.count }).max(), longest > 0 else { return designSize }
        let floorSize = w * 0.032
        if isJapanese {
            let fit = usable / CGFloat(longest) - w * t.kerningFactor
            return max(min(designSize, fit), floorSize)
        }
        guard lines.count > 1 else { return designSize }
        let averageCharWidth: CGFloat = t.uppercased ? 0.70 : 0.56
        let fit = usable / (CGFloat(longest) * averageCharWidth) - w * t.kerningFactor
        return max(min(designSize, fit), floorSize)
    }

    // MARK: - Font resolution

    /// Resolve the template's font family including the language. Sending Japanese to a Latin-only font
    /// silently falls back to Hiragino Sans and the "mechanical look" comes back, so Japanese is
    /// specified explicitly
    private static func font(_ family: QuoteCardTemplate.Family, size: CGFloat, text: String) -> Font {
        let isJa = QuoteTypography.containsJapanese(text)
        switch family {
        case .serifBlack:
            return isJa ? mincho(size, bold: true) : .system(size: size, weight: .black, design: .serif)
        case .serifBold:
            return isJa ? mincho(size, bold: true) : .system(size: size, weight: .bold, design: .serif)
        case .baskerville:
            return isJa ? mincho(size, bold: false)
                        : installed("Baskerville", size, fallback: .system(size: size, design: .serif))
        case .didot:
            return isJa ? mincho(size, bold: true)
                        : installed("Didot", size, fallback: .system(size: size, weight: .semibold, design: .serif))
        case .bodoniItalic:
            return isJa ? mincho(size, bold: false)
                        : installed("BodoniSvtyTwoITCTT-BookIta", size,
                                    fallback: .system(size: size, design: .serif).italic())
        case .futura:
            return isJa ? .system(size: size, weight: .semibold)
                        : installed("Futura-Medium", size, fallback: .system(size: size, weight: .medium, design: .rounded))
        case .futuraCondensed:
            return isJa ? .system(size: size, weight: .heavy)
                        : installed("Futura-CondensedExtraBold", size, fallback: .system(size: size, weight: .heavy))
        case .typewriter:
            return isJa ? mincho(size, bold: false)
                        : installed("AmericanTypewriter", size, fallback: .system(size: size, design: .monospaced))
        case .avenirThin:
            return isJa ? .system(size: size, weight: .light)
                        : installed("AvenirNext-UltraLight", size, fallback: .system(size: size, weight: .ultraLight))
        }
    }

    private static func mincho(_ size: CGFloat, bold: Bool) -> Font {
        installed(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size,
                  fallback: .system(size: size, weight: bold ? .semibold : .regular, design: .serif))
    }

    /// Same style as the editor (OverlayFontProvider): a font name that is not on the device does not
    /// silently fall back; it goes to an explicit fallback (lesson from 2026-07-15, when Didot-Bold was
    /// missing on a real device)
    private static func installed(_ name: String, _ size: CGFloat, fallback: Font) -> Font {
        UIFont(name: name, size: size) != nil ? .custom(name, size: size) : fallback
    }

    // MARK: - Templates (only appending to the end is safe: reordering/deleting swaps the look of every quote)

    static let templates: [QuoteCardTemplate] = [
        // 0: Serif poster: New York Black placed big on the left (a stronger version of the editor's leftmost font)
        QuoteCardTemplate(background: Color(hex: "F4F3EF"), ink: Color(hex: "141413"),
                          family: .serifBlack, sizeFactor: 0.092,
                          lineSpacingFactor: 0.016, textAlignment: .leading,
                          anchor: .leading, paddingFactor: 0.09, maxLineLength: 11),
        // 1: Book-style list: one line per sentence in Baskerville, quietly centered ("Stay private.")
        QuoteCardTemplate(background: Color(hex: "F7F6F2"), ink: Color(hex: "17181A"),
                          family: .baskerville, sizeFactor: 0.054,
                          lineSpacingFactor: 0.042, paddingFactor: 0.12,
                          maxLineLength: 15, splitEnSentences: true),
        // 2: Didot fashion magazine: high-contrast uppercase in the center (a Vogue cover)
        QuoteCardTemplate(background: Color(hex: "FAFAF7"), ink: Color(hex: "111112"),
                          family: .didot, sizeFactor: 0.082,
                          uppercased: true, kerningFactor: 0.002,
                          lineSpacingFactor: 0.030, paddingFactor: 0.10, maxLineLength: 10),
        // 3: Dark serif: white New York Bold on black
        QuoteCardTemplate(background: Color(hex: "111113"), ink: Color(hex: "F3F1EA"),
                          family: .serifBold, sizeFactor: 0.070,
                          lineSpacingFactor: 0.034, paddingFactor: 0.11, maxLineLength: 12,
                          isDark: true),
        // 4: Futura Condensed headline: tight uppercase stacked on the left (a street poster)
        QuoteCardTemplate(background: Color(hex: "F1F0EC"), ink: Color(hex: "0F0F10"),
                          family: .futuraCondensed, sizeFactor: 0.105,
                          uppercased: true, lineSpacingFactor: 0.014,
                          textAlignment: .leading, anchor: .leading,
                          paddingFactor: 0.09, maxLineLength: 10),
        // 5: Avenir ultra thin: thin text with wide letter spacing in the center (the voice of the editor's
        // time font)
        QuoteCardTemplate(background: .white, ink: Color(hex: "1F1F21"),
                          family: .avenirThin, sizeFactor: 0.055,
                          uppercased: true, kerningFactor: 0.010,
                          lineSpacingFactor: 0.040, paddingFactor: 0.13, maxLineLength: 16),
        // 6: Bottom-left note: Bodoni Italic placed low at the bottom left
        QuoteCardTemplate(background: Color(hex: "ECEAE4"), ink: Color(hex: "141416"),
                          family: .bodoniItalic, sizeFactor: 0.064,
                          lineSpacingFactor: 0.020, textAlignment: .leading,
                          anchor: .bottomLeading, paddingFactor: 0.09, maxLineLength: 13),
        // 7: Typewriter: American Typewriter, plainly on the left
        QuoteCardTemplate(background: Color(hex: "F2F0E9"), ink: Color(hex: "26262A"),
                          family: .typewriter, sizeFactor: 0.046,
                          lineSpacingFactor: 0.024, textAlignment: .leading,
                          anchor: .center, paddingFactor: 0.11, maxLineLength: 17),
        // 8: Blush poster: Didot on paper with a faint red tint (strong, with some allure)
        QuoteCardTemplate(background: Color(hex: "F2E8E4"), ink: Color(hex: "161413"),
                          family: .didot, sizeFactor: 0.086,
                          lineSpacingFactor: 0.022, textAlignment: .leading,
                          anchor: .leading, paddingFactor: 0.09, maxLineLength: 10),
        // 9: Dark Futura: widely spaced Futura uppercase on black (street at night)
        QuoteCardTemplate(background: Color(hex: "141416"), ink: Color(hex: "F4F2EC"),
                          family: .futura, sizeFactor: 0.060,
                          uppercased: true, kerningFactor: 0.008,
                          lineSpacingFactor: 0.036, paddingFactor: 0.12, maxLineLength: 12,
                          isDark: true),
    ]

    static func template(for id: UUID, override index: Int?) -> QuoteCardTemplate {
        if let index, templates.indices.contains(index) { return templates[index] }
        return templates[Int(fnv1a(id.uuidString) % UInt64(templates.count))]
    }

    /// Same FNV-1a as BackgroundImageProvider (a hash that is stable across launches.
    /// Swift's hashValue is not used because its seed changes per process)
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
