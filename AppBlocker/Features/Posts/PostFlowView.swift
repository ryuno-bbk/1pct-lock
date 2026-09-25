//
//  PostFlowView.swift
//  AppBlocker
//
//  UGC 投稿 v2: フロー全体のコンテナ (Step1 背景グリッド → Step2 ストーリー式エディタ →
//  Step3 確認/投稿 → 完了状態 → (任意) ロック導線)。
//  MyProfileView から sheet(isPresented:) で提示される想定 (引数なし init)。
//  共有状態は PostDraft (ObservableObject) で Step 間を橋渡しする。
//

import SwiftUI
import UIKit
import CoreText
import Combine

// MARK: - PostBackground (Step1 で選ばれる背景の内部表現)

enum PostBackground {
    case photo(UIImage)
    case template(Int)
    case black
    case white
}

// MARK: - オーバーレイ編集用のローカルモデル (確定時に PostOverlayDTO へ変換)

enum OverlayFont: String, CaseIterable {
    case serif
    case sans
    /// 「現在時刻を挿入」ボタン用のオシャレな時刻フォント (Avenir Next Ultra Light)。
    /// オンボの焼き込み画像の時刻表記と同じ font。通常入力では選ばせず、時刻挿入時のみ付く
    case time
    /// おしゃれ英字フォント (Futura。Nike/Supreme系のジオメトリック)。ユーザー決定 2026-07-10
    case futura
    /// おしゃれ英字フォント (Didot。Vogue系ハイコントラスト明朝)。オンボ焼き込みの英字と同じ。
    /// 実機FB第7弾 (2026-07-15): "Didot-Bold" が実機に無く .serif と完全に同じ見た目にフォール
    /// バックしてしまう真因が判明したためピッカーからは外した。ただし既存投稿のデコード互換
    /// (rawValue "didot" で保存済みのデータ) のため case 自体と provider 分岐は残す
    case didot
    /// タイプライター調 (American Typewriter Semibold)。無ければ monospaced semibold にフォールバック
    /// 実機FB第8弾 (2026-07-15): ピル上で serif と見分けがつかずピッカーから除外。デコード互換で case は残す
    case typewriter
    /// 丸ゴシック (system rounded heavy)。システムフォントなのでフォールバック不要
    case rounded
    /// 手書き (Yusei Magic)。日本語グリフを自前で持つ数少ない手書き書体で、かつ太いので
    /// 写真の上でも背景に負けない (2026-08-28 ユーザー選定)
    case handwriting

    /// フォントピルに出す通常の選択肢 (time は時刻ボタン専用なので除外。didot/typewriter は上記コメント参照)
    static var pickable: [OverlayFont] { [.serif, .sans, .futura, .rounded, .handwriting] }

}

/// OverlayFont の実フォント解決 + 時刻文字列生成。ライブエディタ / 焼き込みレンダラー共通。
enum OverlayFontProvider {
    /// 時刻フォント (Avenir Next Ultra Light。無い環境では rounded light にフォールバック)
    static func time(_ size: CGFloat) -> Font {
        custom("AvenirNext-UltraLight", size, fallback: .system(size: size, weight: .ultraLight, design: .rounded))
    }

    /// Futura (おしゃれ英字。Medium)。無ければ rounded medium
    static func futura(_ size: CGFloat) -> Font {
        custom("Futura-Medium", size, fallback: .system(size: size, weight: .medium, design: .rounded))
    }

    /// Didot (おしゃれ英字。Bold)。無ければ serif bold
    static func didot(_ size: CGFloat) -> Font {
        custom("Didot-Bold", size, fallback: .system(size: size, weight: .bold, design: .serif))
    }

    /// タイプライター調 (American Typewriter Semibold)。無ければ monospaced semibold
    static func typewriter(_ size: CGFloat) -> Font {
        custom("AmericanTypewriter-Semibold", size, fallback: .system(size: size, weight: .semibold, design: .monospaced))
    }

    /// 丸ゴシック。英字は SF Rounded、日本語はヒラギノ丸ゴ
    static func rounded(_ size: CGFloat) -> Font {
        let plain = Font.system(size: size, weight: .heavy, design: .rounded)
        guard let latin = UIFont.systemFont(ofSize: size, weight: .heavy)
            .fontDescriptor.withDesign(.rounded) else { return plain }
        return mixed(latin, japanese: "HiraMaruProN-W4", size: size, fallback: plain)
    }

    /// 明朝。英字は New York、日本語はヒラギノ明朝
    static func serif(_ size: CGFloat) -> Font {
        let plain = Font.system(size: size, weight: .bold, design: .serif)
        guard let latin = UIFont.systemFont(ofSize: size, weight: .bold)
            .fontDescriptor.withDesign(.serif) else { return plain }
        return mixed(latin, japanese: "HiraMinProN-W6", size: size, fallback: plain)
    }

    /// ゴシック。日本語の既定の差し替え先がヒラギノ角ゴなので、合成せずそのままでよい
    static func sans(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// 手書き (Yusei Magic)。日本語グリフを自前で持っているので合成不要
    static func handwriting(_ size: CGFloat) -> Font {
        custom("YuseiMagic-Regular", size, fallback: .system(size: size, weight: .semibold, design: .rounded))
    }

    /// OverlayFont → 実 Font の唯一の解決口。
    /// 🔴 ここ以外で .system(design:) を直書きしないこと。以前は編集キャンバス/ピル/
    ///    プレビューの3箇所に散っていて、日本語対応を入れる場所が分からなくなっていた
    static func font(_ kind: OverlayFont, size: CGFloat) -> Font {
        switch kind {
        case .serif:       return serif(size)
        case .sans:        return sans(size)
        case .time:        return time(size)
        case .futura:      return futura(size)
        case .didot:       return didot(size)
        case .typewriter:  return typewriter(size)
        case .rounded:     return rounded(size)
        case .handwriting: return handwriting(size)
        }
    }

    /// 英字と日本語で別々の書体を使う合成フォントを作る。
    ///
    /// 🔴 これが無いと日本語は必ずヒラギノ角ゴに差し替えられる (2026-08-28 シミュレータで実測)。
    ///    英字書体は日本語グリフを持たないので OS が勝手に差し替えてしまい、
    ///    serif も rounded も futura も「日本語では全部同じ見た目」になっていた。
    ///    = 4択が実質1択だったというユーザー報告の正体。
    private static func mixed(
        _ latin: UIFontDescriptor,
        japanese: String,
        size: CGFloat,
        fallback: Font
    ) -> Font {
        guard let ja = UIFont(name: japanese, size: size) else { return fallback }
        let cascadeKey = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        let merged = latin.addingAttributes([cascadeKey: [ja.fontDescriptor]])
        return Font(UIFont(descriptor: merged, size: size))
    }

    private static func custom(_ name: String, _ size: CGFloat, fallback: Font) -> Font {
        UIFont(name: name, size: size) != nil ? .custom(name, size: size) : fallback
    }

    /// 現在時刻を "H:mm" (先頭ゼロなし) で。例: 5:20 / 21:05
    static func currentTimeString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f.string(from: Date())
    }
}

/// テキスト色。プリセット (白/黒/名前付き) + スポイトで拾った任意色 ("#RRGGBB")。
/// enum → トークン構造体に変更 (2026-07-11、スポイト対応)。DTO には token を
/// そのまま保存する。旧データの "offwhite"/"ink"/"red" 等のトークンもそのまま通る
struct OverlayColor: Equatable, Hashable {
    let token: String

    static let offwhite = OverlayColor(token: "offwhite")
    static let ink      = OverlayColor(token: "ink")
    /// プレート背景サイクルの「グレー」(OFF→グレー→黒→白→OFF、2026-07-11)
    static let plateGray = OverlayColor(token: "plategray")

    /// スポイト/パレットで拾った任意色
    static func custom(_ color: UIColor) -> OverlayColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X",
                         Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        return OverlayColor(token: hex)
    }

    /// スウォッチ列のプリセット (白黒グレー → 虹のグラデーション細分 → パステル。
    /// IG 準拠で横スクロール 1 列、2026-07-11 ユーザー指定)。
    /// body 評価のたびに ~41 色の UIColor init + getRed + String(format:) を再計算していたため
    /// (colorScrollRow の ForEach から毎回参照される) stored let で一度だけ構築する (2026-07-11)
    static let palette: [OverlayColor] = {
        var list: [OverlayColor] = [.offwhite, .ink]
        for white in [0.78, 0.55, 0.32] {
            list.append(.custom(UIColor(white: white, alpha: 1)))
        }
        // 虹 (15°刻み24色、ビビッド)
        for i in 0..<24 {
            list.append(.custom(UIColor(hue: CGFloat(i) / 24, saturation: 0.85, brightness: 0.95, alpha: 1)))
        }
        // パステル (30°刻み12色)
        for i in 0..<12 {
            list.append(.custom(UIColor(hue: CGFloat(i) / 12, saturation: 0.32, brightness: 1.0, alpha: 1)))
        }
        return list
    }()

    var uiColor: UIColor {
        switch token {
        case "offwhite":  return UIColor(AppColors.textPrimary)
        case "ink":       return UIColor(AppColors.background)
        case "plategray": return UIColor(white: 0.55, alpha: 1)
        // 旧8色プリセットのトークン (後方互換)
        case "red":      return UIColor(Color(hex: "E53935"))
        case "orange":   return UIColor(Color(hex: "F97316"))
        case "yellow":   return UIColor(Color(hex: "FFD23F"))
        case "green":    return UIColor(Color(hex: "3BB273"))
        case "blue":     return UIColor(Color(hex: "3EA6FF"))
        case "pink":     return UIColor(Color(hex: "FF6FA5"))
        default:
            // "#RRGGBB"
            let hex = token.hasPrefix("#") ? String(token.dropFirst()) : token
            var value: UInt64 = 0
            guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else {
                return UIColor(AppColors.textPrimary)
            }
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    var swiftUIColor: Color { Color(uiColor) }

    /// プレートON時の文字色 (プレート背景 = 自分の色。輝度でコントラスト自動判定)
    var contrastText: OverlayColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = r * 0.299 + g * 0.587 + b * 0.114
        return luminance > 0.55 ? .ink : .offwhite
    }

    /// DTO 互換 (旧 enum の rawValue と同じ意味)
    var rawValue: String { token }
}

enum OverlayAlignment: String {
    case left
    case center
    case right

    var textAlignment: TextAlignment {
        switch self {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }
}

struct EditableOverlay: Identifiable {
    let id: UUID
    var text: String
    var font: OverlayFont
    /// 文字色 (常に文字に適用される。プレートONでも文字色はこれ)
    var color: OverlayColor
    var plate: Bool
    /// プレート背景色。nil = 文字色から自動コントラスト (白文字→黒プレート等)。
    /// カラー行の「文字/背景」切替で明示指定できる (2026-07-11)
    var plateColor: OverlayColor? = nil
    /// 中心位置 / キャンバス幅・高 (0-1、正規化済み)
    var x: Double
    var y: Double
    /// 実 pt 値 (編集中のキャンバス基準)。DTO 化時にキャンバス幅で正規化する。
    var fontSize: Double
    var rotationDegrees: Double
    var alignment: OverlayAlignment

    /// 実際に描画するプレート背景色 (明示指定 or 自動コントラスト)
    var resolvedPlateColor: OverlayColor {
        plateColor ?? color.contrastText
    }
}

extension EditableOverlay {
    /// 別エージェント実装の UserPostService.createPostV2 に渡す DTO へ変換。
    /// fontSize は「pt / キャンバス幅」の正規化値にする。
    /// imageIndex は焼き込み直後は 0 で仮置きし、複数枚投稿では PostDraft.flattenedOverlayDTOs で
    /// 実際の画像インデックスに差し替える (withImageIndex(_:))。
    func toDTO(canvasWidth: CGFloat) -> PostOverlayDTO {
        let normalizedFontSize = canvasWidth > 0 ? fontSize / Double(canvasWidth) : 0.03
        return PostOverlayDTO(
            text: text,
            font: font.rawValue,
            color: color.rawValue,
            plate: plate,
            x: x,
            y: y,
            fontSize: normalizedFontSize,
            rotationDegrees: rotationDegrees,
            alignment: alignment.rawValue,
            plateColor: plateColor?.rawValue
        )
    }
}

/// テンプレ背景 (QuoteBackgroundView) を編集/焼き込みで使う際の固定シードID。
/// backgroundIndex を明示指定するため quoteId 自体は意味を持たない。
let postFlowTemplateSeedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

// MARK: - DraftImage (複数枚投稿の1枚分の下書き状態)

/// 1枚の画像分の下書き (背景 + 自由配置テキスト + 焼き込み結果)。
/// PostDraft.images に最大4件保持し、PostBackgroundGridView で選択される都度追加される。
struct DraftImage: Identifiable {
    let id = UUID()
    var background: PostBackground
    var overlays: [EditableOverlay] = []

    /// Step2「次へ」で焼き込んだ結果 (この画像単体分)
    var bakedImageData: Data?
    var bakedPreviewImage: UIImage?
    /// 焼き込み時点のキャンバス幅で正規化した DTO (imageIndex は仮の 0、送信直前に付け替える)
    var overlayDTOs: [PostOverlayDTO] = []
}

// MARK: - PostDraft (フロー全体で共有する下書き状態)

final class PostDraft: ObservableObject {
    /// 複数枚投稿 (最大4枚) の下書き配列
    @Published var images: [DraftImage] = []
    /// 現在 Step2 (StoryTextEditorView) で編集中の images のインデックス
    @Published var editingIndex: Int = 0

    /// Step3 で入力するタイトル (# タグを含んだまま保存)
    @Published var title: String = ""

    /// 全画像の overlayDTOs を実際の imageIndex 付きでフラット化 (送信直前に呼ぶ)
    var flattenedOverlayDTOs: [PostOverlayDTO] {
        images.enumerated().flatMap { index, image in
            image.overlayDTOs.map { $0.withImageIndex(index) }
        }
    }

    /// 背景確定 (カメラ / グリッド共通)。新しい DraftImage を追加して編集対象にする。
    /// エディタから「戻る」で選び直した場合に残る未焼き込みの幽霊画像は先に取り除く。
    /// 最大4枚。成功で true
    @discardableResult
    func selectBackground(_ background: PostBackground) -> Bool {
        if let last = images.last, last.bakedImageData == nil {
            images.removeLast()
        }
        guard images.count < 4 else { return false }
        images.append(DraftImage(background: background))
        editingIndex = images.count - 1
        return true
    }
}

// MARK: - PostFlowView

struct PostFlowView: View {
    @StateObject private var draft = PostDraft()
    @Environment(\.dismiss) private var dismiss
    // NavigationPath でなく型付き配列にする: 「確認画面が既にスタックにあるか」で
    // エディタ後の遷移を判定するため (count 判定はテンプレ/ライブラリ経由で破綻した)
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case editor
        case confirm
        /// テンプレート選択 / 確定画面の [+] から追加の1枚を選ぶ背景グリッド
        case addBackground
        /// 確定画面のサムネタップ → 焼き込み済みの1枚を再編集 (次へで確定画面に戻る)
        case editImage
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Step1 = 自前カメラ即起動 (2026-07-11 ユーザー確定、TikTok/BeReal式)。
            // テンプレート/カラーは「テンプレートから選ぶ」→ 従来のグリッドへ
            PostCameraView(
                draft: draft,
                onChosen: {
                    path.append(Route.editor)
                },
                onOpenTemplates: {
                    path.append(Route.addBackground)
                }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .editor:
                    StoryTextEditorView(draft: draft) {
                        if path.contains(.confirm) {
                            // 確認画面の [+] → 追加の背景選択 → このエディタ、からの「次へ」
                            // 新しい確認画面は積まず、既存の確認画面まで戻る
                            path.removeLast(2)
                        } else {
                            // 最初の1枚 (カメラ直 / テンプレ・ライブラリのグリッド経由どちらでも)
                            // からの「次へ」→ 確認画面へ進む。
                            // 旧実装の path.count 判定はグリッド経由 (2段) で「2つ戻る」が誤発動し、
                            // カメラに戻される + 焼き込み済み画像が幽霊として残る大バグだった (2026-07-11)
                            path.append(Route.confirm)
                        }
                    }
                case .confirm:
                    PostConfirmView(
                        draft: draft,
                        onAddImage: {
                            path.append(Route.addBackground)
                        },
                        onEditImage: { index in
                            draft.editingIndex = index
                            path.append(Route.editImage)
                        },
                        onCloseFlow: {
                            dismiss()
                        }
                    )
                case .addBackground:
                    // × はフロー全体を閉じる (2026-07-25 実機FB: 従来は × も戻るもカメラに戻り重複)。
                    // ただし確認画面からの画像追加中は、× でドラフト全損しないよう従来の1段戻るに留める
                    PostBackgroundGridView(
                        draft: draft,
                        onChosen: {
                            path.append(Route.editor)
                        },
                        onCloseFlow: path.contains(.confirm) ? nil : { dismiss() }
                    )
                case .editImage:
                    StoryTextEditorView(draft: draft) {
                        // 再焼き込み完了 → 確定画面 (1つ下) へ戻る
                        path.removeLast()
                    }
                }
            }
        }
        // Step1 (カメラ、path が空) では従来通り下スワイプで閉じられる。
        // エディタ/確認画面に進んだら下書きを守るため下スワイプ閉じを無効化する。
        .interactiveDismissDisabled(!path.isEmpty)
        // 戻るでカメラ (ルート) まで完全に戻った = フローをやり直す意思。
        // 焼き込み済みの下書きを残すと、次の撮影で幽霊1枚目として混入するため全消しする
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty && !draft.images.isEmpty {
                draft.images.removeAll()
                draft.editingIndex = 0
                draft.title = ""
            }
        }
    }
}

// MARK: - i18n (既存 L と同じ「lang == .japanese ? jp : en」方式。LocalizedStrings.swift は編集禁止のためここに独立定義)

enum PostFlowStrings {
    static func step1Title(_ lang: AppLanguage) -> String {
        lang == .japanese ? "背景を選ぶ" : "Choose background"
    }

    static func libraryLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ライブラリ" : "Library"
    }

    static func cameraLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "カメラ" : "Camera"
    }

    static func templateSectionLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "テンプレートから選ぶ" : "Choose from templates"
    }

    static func step2Hint(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タップしてテキストを追加" : "Tap to add text"
    }

    static func step2Next(_ lang: AppLanguage) -> String {
        lang == .japanese ? "次へ" : "Next"
    }

    static func step2Done(_ lang: AppLanguage) -> String {
        lang == .japanese ? "完了" : "Done"
    }

    static func colorTargetText(_ lang: AppLanguage) -> String {
        lang == .japanese ? "文字" : "Text"
    }

    static func colorTargetPlate(_ lang: AppLanguage) -> String {
        lang == .japanese ? "背景" : "Fill"
    }

    static func titlePlaceholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タイトルを入力… # でタグ" : "Add a title… # to tag"
    }

    static func submitCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿する" : "Post"
    }

    static func postedTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿完了" : "Posted"
    }

    static func lockToggleLabel(_ lang: AppLanguage) -> String {
        // 2026-07-17 英語をユーザー依頼で整文 (lockPromptHeadline の "Lock in" と揃える)
        lang == .japanese ? "投稿後にロックを開始する" : "Lock in after posting"
    }

    static func closeCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "閉じる" : "Close"
    }

    // 実機FB第10弾 (2026-07-15): 煽り系コピーは撤去して普通の見出しに (サブタイトルは削除)
    static func lockPromptHeadline(_ lang: AppLanguage) -> String {
        // 2026-07-17 英語をユーザー依頼で整文: "Start a lock" は不自然 → "Lock in" (集中に入るの現行スラング、ブランドの規律感とも一致)
        lang == .japanese ? "ロックを開始" : "Lock in" // 文言はユーザー添削待ち (日本語)
    }

    static func lockStartCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ロックを開始" : "Start the lock"
    }

    static func lockLaterCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "あとで" : "Later"
    }

}
