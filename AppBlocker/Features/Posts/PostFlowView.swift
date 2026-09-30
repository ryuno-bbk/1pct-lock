//
//  PostFlowView.swift
//  AppBlocker
//
//  UGC post v2: container for the whole flow (Step1 background grid → Step2 story-style editor →
//  Step3 confirm/post → completed state → (optional) path to lock).
//  Expected to be presented from MyProfileView with sheet(isPresented:) (init without arguments).
//  Shared state is bridged between steps by PostDraft (ObservableObject).
//

import SwiftUI
import UIKit
import CoreText
import Combine

// MARK: - PostBackground (internal representation of the background chosen in Step1)

enum PostBackground {
    case photo(UIImage)
    case template(Int)
    case black
    case white
}

// MARK: - Local model for overlay editing (converted to PostOverlayDTO on confirm)

enum OverlayFont: String, CaseIterable {
    case serif
    case sans
    /// Stylish time font for the "insert current time" button (Avenir Next Ultra Light).
    /// Same font as the time in onboarding's baked images. Not offered for normal input; only applied
    /// when the time is inserted
    case time
    /// Stylish Latin font (Futura. Geometric, Nike/Supreme style). User decision 2026-07-10
    case futura
    /// Stylish Latin font (Didot. Vogue-style high-contrast serif). Same as the Latin text in
    /// onboarding's baked images.
    /// Real device feedback round 7 (2026-07-15): found the real cause, "Didot-Bold" does not exist on
    /// real devices, so it falls back to exactly the same look as .serif. It was removed from the picker.
    /// However, for decoding compatibility with existing posts (data saved with rawValue "didot"), the
    /// case itself and the provider branch are kept
    case didot
    /// Typewriter style (American Typewriter Semibold). Falls back to monospaced semibold if missing
    /// Real device feedback round 8 (2026-07-15): indistinguishable from serif on the pill, so it was
    /// removed from the picker. The case is kept for decoding compatibility
    case typewriter
    /// Rounded gothic (system rounded heavy). It is a system font, so no fallback is needed
    case rounded
    /// Handwriting (Yusei Magic). One of the few handwriting typefaces with its own Japanese glyphs, and
    /// it is bold, so it holds up against the background even on photos (selected by the user 2026-08-28)
    case handwriting

    /// Normal options shown in the font pills (time is excluded because it is only for the time button.
    /// For didot/typewriter, see the comments above)
    static var pickable: [OverlayFont] { [.serif, .sans, .futura, .rounded, .handwriting] }

}

/// Resolves OverlayFont to real fonts + builds the time string. Shared by the live editor and the
/// bake renderer.
enum OverlayFontProvider {
    /// Time font (Avenir Next Ultra Light. Falls back to rounded light where it is missing)
    static func time(_ size: CGFloat) -> Font {
        custom("AvenirNext-UltraLight", size, fallback: .system(size: size, weight: .ultraLight, design: .rounded))
    }

    /// Futura (stylish Latin. Medium). If missing, rounded medium
    static func futura(_ size: CGFloat) -> Font {
        custom("Futura-Medium", size, fallback: .system(size: size, weight: .medium, design: .rounded))
    }

    /// Didot (stylish Latin. Bold). If missing, serif bold
    static func didot(_ size: CGFloat) -> Font {
        custom("Didot-Bold", size, fallback: .system(size: size, weight: .bold, design: .serif))
    }

    /// Typewriter style (American Typewriter Semibold). If missing, monospaced semibold
    static func typewriter(_ size: CGFloat) -> Font {
        custom("AmericanTypewriter-Semibold", size, fallback: .system(size: size, weight: .semibold, design: .monospaced))
    }

    /// Rounded gothic. SF Rounded for Latin, Hiragino Maru Gothic for Japanese
    static func rounded(_ size: CGFloat) -> Font {
        let plain = Font.system(size: size, weight: .heavy, design: .rounded)
        guard let latin = UIFont.systemFont(ofSize: size, weight: .heavy)
            .fontDescriptor.withDesign(.rounded) else { return plain }
        return mixed(latin, japanese: "HiraMaruProN-W4", size: size, fallback: plain)
    }

    /// Mincho (serif). New York for Latin, Hiragino Mincho for Japanese
    static func serif(_ size: CGFloat) -> Font {
        let plain = Font.system(size: size, weight: .bold, design: .serif)
        guard let latin = UIFont.systemFont(ofSize: size, weight: .bold)
            .fontDescriptor.withDesign(.serif) else { return plain }
        return mixed(latin, japanese: "HiraMinProN-W6", size: size, fallback: plain)
    }

    /// Gothic (sans). The default substitute for Japanese is Hiragino Kaku Gothic, so it can be used
    /// as-is without composing
    static func sans(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Handwriting (Yusei Magic). It has its own Japanese glyphs, so no composing is needed
    static func handwriting(_ size: CGFloat) -> Font {
        custom("YuseiMagic-Regular", size, fallback: .system(size: size, weight: .semibold, design: .rounded))
    }

    /// The only place that resolves OverlayFont → real Font.
    /// 🔴 Do not write .system(design:) directly anywhere else. It used to be spread over 3 places
    ///    (edit canvas / pill / preview), and it became unclear where to add Japanese support
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

    /// Build a composite font that uses different typefaces for Latin and Japanese.
    ///
    /// 🔴 Without this, Japanese is always substituted with Hiragino Kaku Gothic (measured on the
    ///    simulator 2026-08-28). Latin typefaces have no Japanese glyphs, so the OS substitutes them on
    ///    its own, and serif, rounded and futura all "looked the same in Japanese".
    ///    = the real reason behind the user report that the 4 choices were effectively 1.
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

    /// Current time as "H:mm" (no leading zero). e.g. 5:20 / 21:05
    static func currentTimeString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f.string(from: Date())
    }
}

/// Text color. Presets (white/black/named) + any color picked with the eyedropper ("#RRGGBB").
/// Changed from an enum to a token struct (2026-07-11, for eyedropper support). The token is saved
/// as-is in the DTO. Tokens from old data such as "offwhite"/"ink"/"red" also pass through as-is
struct OverlayColor: Equatable, Hashable {
    let token: String

    static let offwhite = OverlayColor(token: "offwhite")
    static let ink      = OverlayColor(token: "ink")
    /// The "gray" in the plate background cycle (OFF→gray→black→white→OFF, 2026-07-11)
    static let plateGray = OverlayColor(token: "plategray")

    /// Any color picked with the eyedropper/palette
    static func custom(_ color: UIColor) -> OverlayColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X",
                         Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        return OverlayColor(token: hex)
    }

    /// Presets for the swatch row (white/black/gray → finely divided rainbow gradient → pastels.
    /// One horizontally scrolling row following IG, specified by the user 2026-07-11).
    /// Every body evaluation used to recompute ~41 UIColor inits + getRed + String(format:)
    /// (referenced every time from the ForEach in colorScrollRow), so it is built only once as a
    /// stored let (2026-07-11)
    static let palette: [OverlayColor] = {
        var list: [OverlayColor] = [.offwhite, .ink]
        for white in [0.78, 0.55, 0.32] {
            list.append(.custom(UIColor(white: white, alpha: 1)))
        }
        // Rainbow (24 colors in 15° steps, vivid)
        for i in 0..<24 {
            list.append(.custom(UIColor(hue: CGFloat(i) / 24, saturation: 0.85, brightness: 0.95, alpha: 1)))
        }
        // Pastel (12 colors in 30° steps)
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
        // Tokens of the old 8-color presets (backward compatibility)
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

    /// Text color when the plate is ON (plate background = own color. Contrast decided automatically by
    /// luminance)
    var contrastText: OverlayColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = r * 0.299 + g * 0.587 + b * 0.114
        return luminance > 0.55 ? .ink : .offwhite
    }

    /// DTO compatibility (same meaning as the rawValue of the old enum)
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
    /// Text color (always applied to the text. With the plate ON, the text color is still this)
    var color: OverlayColor
    var plate: Bool
    /// Plate background color. nil = automatic contrast from the text color (white text → black plate,
    /// etc.). Can be set explicitly with the "text/background" switch in the color row (2026-07-11)
    var plateColor: OverlayColor? = nil
    /// Center position / canvas width and height (0-1, normalized)
    var x: Double
    var y: Double
    /// Actual pt value (relative to the canvas being edited). Normalized by the canvas width when
    /// converted to a DTO.
    var fontSize: Double
    var rotationDegrees: Double
    var alignment: OverlayAlignment

    /// The plate background color actually drawn (explicit or automatic contrast)
    var resolvedPlateColor: OverlayColor {
        plateColor ?? color.contrastText
    }
}

extension EditableOverlay {
    /// Convert to the DTO passed to UserPostService.createPostV2, implemented by another agent.
    /// fontSize becomes the normalized value "pt / canvas width".
    /// imageIndex is set to a placeholder 0 right after baking, and for multi-image posts
    /// PostDraft.flattenedOverlayDTOs replaces it with the real image index (withImageIndex(_:)).
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

/// Fixed seed ID used when the template background (QuoteBackgroundView) is used for editing/baking.
/// backgroundIndex is set explicitly, so the quoteId itself has no meaning.
let postFlowTemplateSeedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

// MARK: - DraftImage (draft state for one image of a multi-image post)

/// Draft for one image (background + freely placed text + baked result).
/// PostDraft.images holds up to 4, and one is added each time a background is selected in
/// PostBackgroundGridView.
struct DraftImage: Identifiable {
    let id = UUID()
    var background: PostBackground
    var overlays: [EditableOverlay] = []

    /// Result baked by "次へ" ("Next") in Step2 (for this image only)
    var bakedImageData: Data?
    var bakedPreviewImage: UIImage?
    /// DTOs normalized by the canvas width at baking time (imageIndex is a placeholder 0, reassigned
    /// right before sending)
    var overlayDTOs: [PostOverlayDTO] = []
}

// MARK: - PostDraft (draft state shared across the whole flow)

final class PostDraft: ObservableObject {
    /// Draft array for a multi-image post (up to 4 images)
    @Published var images: [DraftImage] = []
    /// Index into images of the one currently being edited in Step2 (StoryTextEditorView)
    @Published var editingIndex: Int = 0

    /// Title entered in Step3 (saved with the # tags still included)
    @Published var title: String = ""

    /// Flatten the overlayDTOs of all images with their real imageIndex (call right before sending)
    var flattenedOverlayDTOs: [PostOverlayDTO] {
        images.enumerated().flatMap { index, image in
            image.overlayDTOs.map { $0.withImageIndex(index) }
        }
    }

    /// Confirm a background (shared by camera / grid). Adds a new DraftImage and makes it the edit
    /// target. First removes any unbaked ghost image left behind when the user went back from the editor
    /// to choose again. Max 4 images. Returns true on success
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
    // A typed array instead of NavigationPath: the transition after the editor is decided by "whether
    // the confirm screen is already on the stack" (checking count broke when coming via
    // template/library)
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case editor
        case confirm
        /// Background grid for choosing one more image, opened from template selection / the [+] on the
        /// confirm screen
        case addBackground
        /// Tap a thumbnail on the confirm screen → re-edit that baked image (Next returns to the confirm
        /// screen)
        case editImage
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Step1 = launch our own camera immediately (user decision 2026-07-11, TikTok/BeReal style).
            // Templates/colors go through "テンプレートから選ぶ" ("Choose from templates") → the existing grid
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
                            // "Next" from this editor, reached via [+] on the confirm screen → additional background selection.
                            // Do not push a new confirm screen; go back to the existing one
                            path.removeLast(2)
                        } else {
                            // "Next" from the first image (whether straight from the camera or via the template/library grid)
                            // → go to the confirm screen.
                            // The old path.count check wrongly triggered "go back 2" when coming via the grid (2 levels),
                            // a major bug that sent the user back to the camera + left the baked image as a ghost (2026-07-11)
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
                    // × closes the whole flow (2026-07-25 real device feedback: previously both × and back went to the
                    // camera, duplicating each other). However, while adding an image from the confirm screen, it stays
                    // as the old one-level back so that × does not wipe the whole draft
                    PostBackgroundGridView(
                        draft: draft,
                        onChosen: {
                            path.append(Route.editor)
                        },
                        onCloseFlow: path.contains(.confirm) ? nil : { dismiss() }
                    )
                case .editImage:
                    StoryTextEditorView(draft: draft) {
                        // Re-baking done → go back to the confirm screen (one level down)
                        path.removeLast()
                    }
                }
            }
        }
        // In Step1 (camera, path is empty), swipe down closes it as before.
        // Once the user moves on to the editor/confirm screen, swipe-down dismiss is disabled to protect
        // the draft.
        .interactiveDismissDisabled(!path.isEmpty)
        // Going all the way back to the camera (root) = intent to restart the flow.
        // If baked drafts were kept, they would slip into the next capture as a ghost 1st image, so clear
        // everything
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty && !draft.images.isEmpty {
                draft.images.removeAll()
                draft.editingIndex = 0
                draft.title = ""
            }
        }
    }
}

// MARK: - i18n (same "lang == .japanese ? jp : en" style as the existing L.
// LocalizedStrings.swift must not be edited, so it is defined separately here)

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
        // 2026-07-17 English reworded at the user's request (matches "Lock in" in lockPromptHeadline)
        lang == .japanese ? "投稿後にロックを開始する" : "Lock in after posting"
    }

    static func closeCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "閉じる" : "Close"
    }

    // Real device feedback round 10 (2026-07-15): removed the hype copy and made it a plain heading
    // (subtitle removed)
    static func lockPromptHeadline(_ lang: AppLanguage) -> String {
        // 2026-07-17 English reworded at the user's request: "Start a lock" sounds unnatural → "Lock in"
        // (current slang for getting into focus, and it also fits the brand's sense of discipline)
        lang == .japanese ? "ロックを開始" : "Lock in" // Wording awaiting user review (Japanese)
    }

    static func lockStartCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ロックを開始" : "Start the lock"
    }

    static func lockLaterCTA(_ lang: AppLanguage) -> String {
        lang == .japanese ? "あとで" : "Later"
    }

}
