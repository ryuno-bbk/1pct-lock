//
//  QuoteTypography.swift
//  AppBlocker
//
//  Typography settings only for displaying quotes
//

import SwiftUI
import NaturalLanguage

/// Typography styles for displaying quotes
enum QuoteTypography {

    // MARK: - Poetic line breaks
    // (2026-07-30 real-device feedback: "bigger text, nice line breaks, fix all the weird line breaks")
    // The "weird line breaks" come from natural wrapping, which breaks mid-sentence (e.g. right after a
    // particle) and looks silly.
    // Japanese quotes always break at the end of a sentence ("。！？"), so line breaks match meaning breaks.
    // Only if one sentence is too long, break once at the comma closest to the center. English quotes keep
    // natural wrapping

    static func containsJapanese(_ text: String) -> Bool {
        text.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression) != nil
    }

    /// Converts a Japanese quote into display text with line breaks at sentence ends (default strength).
    /// Text that is English only / already has manual line breaks is not changed
    static func poeticText(_ text: String) -> String {
        displayText(text, maxLineLength: 18, splitEnglishSentences: false)
    }

    /// Template-aware version (2026-07-30 quote card redesign):
    /// - Japanese: always break at sentence ends ("。！？") + long sentences are balanced at morpheme
    ///   boundaries (NLTokenizer)
    /// - English: split lines by sentence only when splitEnglishSentences=true (for list-style templates)
    static func displayText(_ text: String, maxLineLength: Int, splitEnglishSentences: Bool) -> String {
        displayLines(text, maxLineLength: maxLineLength, splitEnglishSentences: splitEnglishSentences)
            .joined(separator: "\n")
    }

    /// Array-of-lines version (the card uses it to fit the font size to the longest line)
    static func displayLines(_ text: String, maxLineLength: Int, splitEnglishSentences: Bool) -> [String] {
        guard !text.contains("\n") else { return text.components(separatedBy: "\n") }
        if containsJapanese(text) {
            return japaneseLines(text, maxLineLength: maxLineLength)
        }
        guard splitEnglishSentences else { return [text] }
        return englishSentenceLines(text)
    }

    private static func japaneseLines(_ text: String, maxLineLength: Int) -> [String] {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "…"]
        let closers: Set<Character> = ["」", "』", "）", ")", "\u{201D}"]
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard enders.contains(ch) else { continue }
            // Keep runs of "!?" and closing brackets on the same line
            if let next = i + 1 < chars.count ? chars[i + 1] : nil,
               enders.contains(next) || closers.contains(next) { continue }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }

        // Long sentences are balanced at morpheme boundaries (fix for feedback round 2 on 2026-07-30, "the line
        // breaks are terrible": the old implementation dropped sentences without commas into natural wrapping
        // → breaks in the middle of a word)
        return sentences.flatMap { sentence -> [String] in
            let arr = Array(sentence)
            guard arr.count > maxLineLength else { return [sentence] }
            return balancedFill(semanticChunks(sentence), maxLen: maxLineLength)
        }
    }

    private static let lineOpeners: Set<Character> = ["「", "『", "（", "(", "\"", "\u{201C}"]

    /// Cuts a sentence into "units that may be broken": NLTokenizer word boundaries + particles / short
    /// hiragana / punctuation are glued to the preceding word (structurally prevents lines that start with
    /// "は" or "を" etc.).
    /// Punctuation and closing brackets go to the end of the previous word, opening brackets to the start of
    /// the next word (prevents an opening "「" dangling at the end of a line)
    private static func semanticChunks(_ sentence: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        var raw: [String] = []
        var pendingPrefix = ""
        var cursor = sentence.startIndex
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            // NLTokenizer does not return punctuation as words → distribute the gaps between words
            if cursor < range.lowerBound {
                for ch in sentence[cursor..<range.lowerBound] {
                    if lineOpeners.contains(ch) {
                        pendingPrefix.append(ch) // Opening brackets go to the start of the next word
                    } else if raw.isEmpty {
                        pendingPrefix.append(ch)
                    } else {
                        raw[raw.count - 1].append(ch) // Punctuation and closing brackets go to the end of the previous word
                    }
                }
            }
            raw.append(pendingPrefix + String(sentence[range]))
            pendingPrefix = ""
            cursor = range.upperBound
            return true
        }
        if cursor < sentence.endIndex {
            let tail = String(sentence[cursor..<sentence.endIndex])
            if raw.isEmpty { raw.append(tail) } else { raw[raw.count - 1] += tail }
        }
        if !pendingPrefix.isEmpty {
            if raw.isEmpty { raw.append(pendingPrefix) } else { raw[raw.count - 1] += pendingPrefix }
        }

        var glued: [String] = []
        for token in raw {
            if !glued.isEmpty, shouldGlueToPrevious(token) {
                glued[glued.count - 1] += token
            } else {
                glued.append(token)
            }
        }
        return glued
    }

    /// Whether the token should be glued to the previous word. Checked on the body without punctuation and
    /// symbols
    /// (with a comma attached, like "ば、" or "が、", the check broke and particles ended up at the start of
    /// lines):
    /// if the body is all hiragana and 3 characters or fewer (particles, auxiliary verbs, helpers such as
    /// "しない") or symbols only → glue.
    /// Words starting with an opening bracket are the start of a quotation, so they are not glued
    private static func shouldGlueToPrevious(_ token: String) -> Bool {
        guard let first = token.first else { return true }
        if lineOpeners.contains(first) { return false }
        let core = token.unicodeScalars.filter {
            !(CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0))
        }
        if core.isEmpty { return true }
        let isAllHiragana = core.allSatisfy { (0x3041...0x309F).contains($0.value) }
        return isAllHiragana && core.count <= 3
    }

    /// Packs the chunk list with "fewest lines × balanced line lengths".
    /// - Do not break at 3 characters or fewer (prevents orphan lines with just "今" ("now"). A little
    ///   overflow is absorbed by the font's line fitting)
    /// - Lines that end with a comma are preferred as break points
    /// - A trailing orphan line (3 characters or fewer) is absorbed into the previous line
    private static func balancedFill(_ chunks: [String], maxLen: Int) -> [String] {
        let total = chunks.reduce(0) { $0 + $1.count }
        let lineCount = max(1, Int((Double(total) / Double(maxLen)).rounded(.up)))
        let target = Int((Double(total) / Double(lineCount)).rounded(.up))
        var lines: [String] = []
        var currentLine = ""
        for chunk in chunks {
            if !currentLine.isEmpty, currentLine.count >= 4,
               currentLine.count + chunk.count > maxLen
                || currentLine.count >= target
                || currentLine.hasSuffix("、") && currentLine.count + chunk.count > target {
                lines.append(currentLine)
                currentLine = ""
            }
            currentLine += chunk
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        if lines.count >= 2, let last = lines.last, last.count <= 3,
           lines[lines.count - 2].count + last.count <= maxLen + 3 {
            lines[lines.count - 2] += last
            lines.removeLast()
        }
        return lines
    }

    /// Splits English into lines by sentence ("Stay private. Work hard." → 2 lines).
    /// Only splits if there are 2 or more sentences and none is too long (a single sentence / long text is
    /// easier to read with natural wrapping)
    private static func englishSentenceLines(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var prevWasEnder = false
        for ch in text {
            if prevWasEnder && ch == " " {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                prevWasEnder = false
                continue
            }
            current.append(ch)
            prevWasEnder = ".!?".contains(ch)
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences.count >= 2 && sentences.allSatisfy { $0.count <= 42 }
            ? sentences
            : [text]
    }

    /// Font size of the main text on the quote card. Shorter text is larger (steps by total length)
    static func displayFontSize(for text: String) -> CGFloat {
        switch text.count {
        case ...16: return 29
        case ...30: return 25
        case ...50: return 22
        default: return 20
        }
    }

    // MARK: - Quote Text Styles

    /// Main quote text (for the Shield UI)
    static func quoteText(size: QuoteTextSize = .large) -> Font {
        let fontSize: CGFloat
        switch size {
        case .medium:
            fontSize = 24
        case .large:
            fontSize = 32
        case .extraLarge:
            fontSize = 40
        }
        return .system(size: fontSize, weight: .bold)
    }

    /// Author name text
    static let authorText: Font = .system(size: 16, weight: .medium, design: .default)

    /// Category label
    static let categoryLabel: Font = .system(size: 12, weight: .semibold, design: .rounded)

    // MARK: - Shield View Modifiers

    /// Style for quote text
    struct QuoteTextStyle: ViewModifier {
        let size: QuoteTextSize

        func body(content: Content) -> some View {
            content
                .font(QuoteTypography.quoteText(size: size))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
                .tracking(0.5)
        }
    }

    /// Style for author name text
    struct AuthorTextStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(QuoteTypography.authorText)
                .foregroundColor(AppColors.textSecondary)
                .tracking(2)
        }
    }
}

// MARK: - App Typography

/// Typography for the whole app
enum AppTypography {

    // MARK: - Headings

    static let largeTitle: Font = .system(size: 34, weight: .bold, design: .rounded)
    static let title1: Font = .system(size: 28, weight: .bold, design: .rounded)
    static let title2: Font = .system(size: 22, weight: .bold, design: .rounded)
    static let title3: Font = .system(size: 20, weight: .semibold, design: .rounded)

    // MARK: - Body

    static let headline: Font = .system(size: 17, weight: .semibold, design: .default)
    static let body: Font = .system(size: 17, weight: .regular, design: .default)
    static let callout: Font = .system(size: 16, weight: .regular, design: .default)
    static let subheadline: Font = .system(size: 15, weight: .regular, design: .default)

    // MARK: - Supporting

    static let footnote: Font = .system(size: 13, weight: .regular, design: .default)
    static let caption1: Font = .system(size: 12, weight: .regular, design: .default)
    static let caption2: Font = .system(size: 11, weight: .regular, design: .default)

    // MARK: - Button

    static let buttonLarge: Font = .system(size: 18, weight: .semibold, design: .rounded)
    static let buttonMedium: Font = .system(size: 16, weight: .semibold, design: .rounded)
    static let buttonSmall: Font = .system(size: 14, weight: .medium, design: .rounded)
}

// MARK: - View Extensions

extension View {
    /// Apply the quote text style
    func quoteTextStyle(size: QuoteTextSize = .large) -> some View {
        modifier(QuoteTypography.QuoteTextStyle(size: size))
    }

    /// Apply the author name style
    func authorTextStyle() -> some View {
        modifier(QuoteTypography.AuthorTextStyle())
    }
}
