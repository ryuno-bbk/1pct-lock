//
//  QuoteCardView.swift
//  AppBlocker
//
//  公式名言のタイポグラフィカード (2026-07-30 実機FB: 写真背景を全廃し、Pinterest 系の
//  「紙のような無地背景 × タイポだけ」に方向転換。ユーザー支給のスクショ群が手本)。
//
//  フォント方針 (同日FB2巡目「システム系は機械っぽくてダサい。珍しいフォントでいい」):
//  - SF (システムサンセリフ) は主役にしない。合格基準=投稿エディタ最左の serif
//    (New York Bold) — そこを軸に、iOS 内蔵の個性派 (Didot / Bodoni 72 / Baskerville /
//    Futura / American Typewriter / Avenir Next UltraLight) で組む。全て端末内蔵 =
//    バンドル不要、UIFont(name:) の存在チェック付きフォールバック (エディタと同じ流儀)
//  - 日本語はラテン専用フォントだと Hiragino Sans に暗黙フォールバックして「機械っぽい」
//    が再発するため、テンプレごとに明示指定 — 軸はヒラギノ明朝 (W3/W6)。
//    Montserrat はワードマーク専用ルールのため使わない
//  - 割当は名言IDのハッシュで決定的。⚠️ テンプレ配列は末尾追加のみ安全
//  - 改行: QuoteTypography.displayText (日本語=文末+読点折り・強度テンプレ別 /
//    英語=リスト型のみ文単位)
//  - サイズは全てカード幅比 — フィード 4:5 / グリッドサムネ / 共有 1080×1920 が相似形
//

import SwiftUI

// MARK: - Template

struct QuoteCardTemplate {
    /// フォント族 (英語フォント × 日本語フォントのペアを束ねる)
    enum Family {
        /// New York Black/Bold (エディタ最左 serif の増強版) × ヒラギノ明朝 W6
        case serifBlack
        /// New York Bold × ヒラギノ明朝 W6
        case serifBold
        /// Baskerville (書物) × ヒラギノ明朝 W3
        case baskerville
        /// Didot (Vogue 系ハイコントラスト) × ヒラギノ明朝 W6
        case didot
        /// Bodoni 72 Book Italic (斜体の色気) × ヒラギノ明朝 W3
        case bodoniItalic
        /// Futura Medium (Nike/Supreme 系ジオメトリック) × ヒラギノ角ゴ W6 相当
        case futura
        /// Futura Condensed ExtraBold (詰めた見出し) × ヒラギノ角ゴ W8 相当
        case futuraCondensed
        /// American Typewriter × ヒラギノ明朝 W3 (和文タイプライターの代役)
        case typewriter
        /// Avenir Next UltraLight (エディタの時刻フォント) × ヒラギノ角ゴ W3 相当
        case avenirThin
    }

    let background: Color
    let ink: Color
    let family: Family
    /// 主文フォントサイズ = カード幅 × この係数
    let sizeFactor: CGFloat
    /// 英語のみ大文字化 (日本語には適用しない)
    var uppercased: Bool = false
    /// 字間 = カード幅 × この係数
    var kerningFactor: CGFloat = 0
    /// 行間 = カード幅 × この係数
    var lineSpacingFactor: CGFloat = 0.02
    var textAlignment: TextAlignment = .center
    /// テキストブロックの置き場所
    var anchor: Alignment = .center
    /// 余白 = カード幅 × この係数
    var paddingFactor: CGFloat = 0.10
    /// 日本語の1行の目安文字数 (これを超える文は読点で折る)
    var maxLineLength: Int = 14
    /// 英語も文単位で行を切る (リスト型)
    var splitEnSentences: Bool = false
    /// 暗背景テンプレ (ウォーターマーク等の重ね物が色を判断するのに使う)
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
    /// テンプレ割当のシード (名言ID)。同じIDは常に同じテンプレ
    let seedId: UUID
    /// 将来の手動指定用 (quotes.template 列を足したらここに流す)。nil=ハッシュ割当
    var templateOverride: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = Self.template(for: seedId, override: templateOverride)
            // 改行優先の原則 (2026-07-30 FB2巡目「でかくするより改行優先」):
            // 行構造 (意味の切れ目) を先に確定し、フォントサイズを最長行が
            // カード幅に収まるまで縮める。行の途中で巻かれる「変な改行」は構造的に起きない
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

    /// 最長行がカード幅 (余白を引いた実測) に収まるフォントサイズ。デザインサイズが上限。
    /// 日本語=全角なので字幅≈フォントサイズ。英語は平均字幅の概算 (最終ガードは
    /// minimumScaleFactor)。英語の自然折返し (1行のまま) は見積もらずデザインサイズ
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

    /// テンプレのフォント族を言語込みで解決する。ラテン専用フォントに日本語を流すと
    /// Hiragino Sans へ暗黙フォールバックして「機械っぽさ」が再発するため、日本語は明示指定
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

    /// エディタ (OverlayFontProvider) と同じ流儀: 端末に無いフォント名は silent fallback せず
    /// 明示フォールバックへ (Didot-Bold が実機に無かった 2026-07-15 の教訓)
    private static func installed(_ name: String, _ size: CGFloat, fallback: Font) -> Font {
        UIFont(name: name, size: size) != nil ? .custom(name, size: size) : fallback
    }

    // MARK: - Templates (末尾追加のみ安全 — 並べ替え/削除は全名言の見た目が入れ替わる)

    static let templates: [QuoteCardTemplate] = [
        // 0: セリフ・ポスター — New York Black を左にドンと (エディタ最左フォントの増強版)
        QuoteCardTemplate(background: Color(hex: "F4F3EF"), ink: Color(hex: "141413"),
                          family: .serifBlack, sizeFactor: 0.092,
                          lineSpacingFactor: 0.016, textAlignment: .leading,
                          anchor: .leading, paddingFactor: 0.09, maxLineLength: 11),
        // 1: 書物の箇条書き — Baskerville で文ごとに1行、静かに中央へ (「Stay private.」)
        QuoteCardTemplate(background: Color(hex: "F7F6F2"), ink: Color(hex: "17181A"),
                          family: .baskerville, sizeFactor: 0.054,
                          lineSpacingFactor: 0.042, paddingFactor: 0.12,
                          maxLineLength: 15, splitEnSentences: true),
        // 2: Didot ファッション誌 — ハイコントラストの大文字を中央に (Vogue の表紙)
        QuoteCardTemplate(background: Color(hex: "FAFAF7"), ink: Color(hex: "111112"),
                          family: .didot, sizeFactor: 0.082,
                          uppercased: true, kerningFactor: 0.002,
                          lineSpacingFactor: 0.030, paddingFactor: 0.10, maxLineLength: 10),
        // 3: ダークセリフ — 黒地に白の New York Bold
        QuoteCardTemplate(background: Color(hex: "111113"), ink: Color(hex: "F3F1EA"),
                          family: .serifBold, sizeFactor: 0.070,
                          lineSpacingFactor: 0.034, paddingFactor: 0.11, maxLineLength: 12,
                          isDark: true),
        // 4: Futura Condensed 見出し — 詰めた大文字を左に積む (ストリートのポスター)
        QuoteCardTemplate(background: Color(hex: "F1F0EC"), ink: Color(hex: "0F0F10"),
                          family: .futuraCondensed, sizeFactor: 0.105,
                          uppercased: true, lineSpacingFactor: 0.014,
                          textAlignment: .leading, anchor: .leading,
                          paddingFactor: 0.09, maxLineLength: 10),
        // 5: Avenir 極細 — 広い字間の細字を中央に (エディタの時刻フォントの声)
        QuoteCardTemplate(background: .white, ink: Color(hex: "1F1F21"),
                          family: .avenirThin, sizeFactor: 0.055,
                          uppercased: true, kerningFactor: 0.010,
                          lineSpacingFactor: 0.040, paddingFactor: 0.13, maxLineLength: 16),
        // 6: 左下の書き置き — Bodoni Italic を左下に沈める
        QuoteCardTemplate(background: Color(hex: "ECEAE4"), ink: Color(hex: "141416"),
                          family: .bodoniItalic, sizeFactor: 0.064,
                          lineSpacingFactor: 0.020, textAlignment: .leading,
                          anchor: .bottomLeading, paddingFactor: 0.09, maxLineLength: 13),
        // 7: タイプライター — American Typewriter で淡々と左に
        QuoteCardTemplate(background: Color(hex: "F2F0E9"), ink: Color(hex: "26262A"),
                          family: .typewriter, sizeFactor: 0.046,
                          lineSpacingFactor: 0.024, textAlignment: .leading,
                          anchor: .center, paddingFactor: 0.11, maxLineLength: 17),
        // 8: 血色ポスター — かすかな赤みの紙に Didot (色気のある強さ)
        QuoteCardTemplate(background: Color(hex: "F2E8E4"), ink: Color(hex: "161413"),
                          family: .didot, sizeFactor: 0.086,
                          lineSpacingFactor: 0.022, textAlignment: .leading,
                          anchor: .leading, paddingFactor: 0.09, maxLineLength: 10),
        // 9: ダーク Futura — 黒地に字間広めの Futura 大文字 (ストリートの夜)
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

    /// BackgroundImageProvider と同じ FNV-1a (起動を跨いで安定したハッシュ。
    /// Swift の hashValue はプロセスごとにシードが変わるため使わない)
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
