//
//  QuoteTypography.swift
//  AppBlocker
//
//  名言表示専用のタイポグラフィ設定
//

import SwiftUI
import NaturalLanguage

/// 名言表示用のタイポグラフィスタイル
enum QuoteTypography {

    // MARK: - 詩的改行 (2026-07-30 実機FB「文字でかく、いい感じに改行、変な改行の全調整」)
    // 成り行き折返しは文の途中 (助詞の直後など) で折れて間抜けに見えるのが「変な改行」の正体。
    // 日本語の名言は文末 (。！？) で必ず改行し、行の切れ目=意味の切れ目に揃える。
    // 1文が長すぎる場合だけ中央に最も近い読点で1回折る。英語名言は自然折返しのまま

    static func containsJapanese(_ text: String) -> Bool {
        text.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression) != nil
    }

    /// 日本語名言を文末で改行した表示用テキストに変換する (既定強度)。
    /// 英語のみ/手動改行済みのテキストは変更しない
    static func poeticText(_ text: String) -> String {
        displayText(text, maxLineLength: 18, splitEnglishSentences: false)
    }

    /// テンプレート対応版 (2026-07-30 名言カード刷新):
    /// - 日本語: 文末 (。！？) で必ず改行 + 長い文は形態素境界 (NLTokenizer) でバランス折り
    /// - 英語: splitEnglishSentences=true のときだけ文単位で行を切る (リスト型テンプレ用)
    static func displayText(_ text: String, maxLineLength: Int, splitEnglishSentences: Bool) -> String {
        displayLines(text, maxLineLength: maxLineLength, splitEnglishSentences: splitEnglishSentences)
            .joined(separator: "\n")
    }

    /// 行の配列版 (カード側がフォントサイズを最長行に合わせるのに使う)
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
            // 「!?」の連続や閉じ括弧は同じ行に抱き込む
            if let next = i + 1 < chars.count ? chars[i + 1] : nil,
               enders.contains(next) || closers.contains(next) { continue }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }

        // 長い文は形態素境界でバランス折り (2026-07-30 FB2巡目「改行が終わってる」対策:
        // 旧実装は読点が無い文を成り行き折返しに落としていた → 語の途中で折れる)
        return sentences.flatMap { sentence -> [String] in
            let arr = Array(sentence)
            guard arr.count > maxLineLength else { return [sentence] }
            return balancedFill(semanticChunks(sentence), maxLen: maxLineLength)
        }
    }

    private static let lineOpeners: Set<Character> = ["「", "『", "（", "(", "\"", "\u{201C}"]

    /// 文を「折ってよい単位」に刻む: NLTokenizer の語境界 + 助詞/短いひらがな/句読点は
    /// 直前の語に接着 (行頭に「は」「を」等が来る事故を構造的に防ぐ)。
    /// 句読点・閉じ括弧は前の語の尻へ、開き括弧は次の語の頭へ (行末に「が浮く事故を防ぐ)
    private static func semanticChunks(_ sentence: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        var raw: [String] = []
        var pendingPrefix = ""
        var cursor = sentence.startIndex
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            // NLTokenizer は句読点を語として返さない → 語間のギャップを振り分ける
            if cursor < range.lowerBound {
                for ch in sentence[cursor..<range.lowerBound] {
                    if lineOpeners.contains(ch) {
                        pendingPrefix.append(ch) // 開き括弧は次の語の頭
                    } else if raw.isEmpty {
                        pendingPrefix.append(ch)
                    } else {
                        raw[raw.count - 1].append(ch) // 句読点・閉じ括弧は前の語の尻
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

    /// 前の語に接着すべきトークンか。句読点・記号を除いた本体で判定する
    /// (「ば、」「が、」のように読点が付くと判定が壊れ、行頭に助詞が来る事故があった):
    /// 本体が全てひらがなで3文字以下 (助詞・助動詞・「しない」等の補助) or 記号のみ → 接着。
    /// 開き括弧で始まる語は引用の頭なので接着しない
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

    /// チャンク列を「行数最小 × 行長バランス」で詰める。
    /// - 3文字以下では折らない (「今」だけの孤児行を防ぐ。多少のはみ出しは
    ///   フォントの行フィット側が吸収する)
    /// - 読点で終わった行は折り目として優先
    /// - 末尾の孤児行 (3文字以下) は前の行へ吸収
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

    /// 英語を文単位の行に分ける ("Stay private. Work hard." → 2行)。
    /// 文が2つ以上あり、どの文も長すぎない場合のみ分割 (1文だけ/長文は自然折返しが読みやすい)
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

    /// 名言カードの主文フォントサイズ。短いほど大きく (全長の段階制)
    static func displayFontSize(for text: String) -> CGFloat {
        switch text.count {
        case ...16: return 29
        case ...30: return 25
        case ...50: return 22
        default: return 20
        }
    }

    // MARK: - Quote Text Styles

    /// メイン名言テキスト（Shield UI用）
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

    /// 著者名テキスト
    static let authorText: Font = .system(size: 16, weight: .medium, design: .default)

    /// カテゴリラベル
    static let categoryLabel: Font = .system(size: 12, weight: .semibold, design: .rounded)

    // MARK: - Shield View Modifiers

    /// 名言テキスト用のスタイル
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

    /// 著者名テキスト用のスタイル
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

/// アプリ全体のタイポグラフィ
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
    /// 名言テキストスタイルを適用
    func quoteTextStyle(size: QuoteTextSize = .large) -> some View {
        modifier(QuoteTypography.QuoteTextStyle(size: size))
    }

    /// 著者名スタイルを適用
    func authorTextStyle() -> some View {
        modifier(QuoteTypography.AuthorTextStyle())
    }
}
