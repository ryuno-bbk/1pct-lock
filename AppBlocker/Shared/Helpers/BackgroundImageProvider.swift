//
//  BackgroundImageProvider.swift
//  AppBlocker
//
//  名言ごとにランダム（だが固定）の背景画像を割り当てる
//  UGC 投稿は user_posts.background_id で明示指定可能 (S14〜)
//

import SwiftUI

enum BackgroundImageProvider {

    // Backgrounds フォルダ内のファイル（名前, 拡張子）
    private static let imageFiles: [(name: String, ext: String)] = [
        ("abstract-background-with-graphic-shapes-color-and-2026-01-09-14-22-32-utc", "jpg"),
        ("background-black-platform-and-dark-grey-rock-displ-2026-01-09-00-52-42-utc", "jpg"),
        ("black-marble-texture-background-2026-03-16-05-04-22-utc", "jpg"),
        ("black-marble-texture-background-2026-03-17-06-32-55-utc", "jpg"),
        ("closeup-shot-of-an-igneous-rock-isolated-on-a-blac-2026-01-07-07-30-31-utc", "jpeg"),
        ("closeup-shot-of-colorful-trees-in-an-autumn-forest-2026-03-18-08-09-13-utc", "jpeg"),
        ("dark-dramatic-redwood-woodland-landscape-2026-03-24-07-01-31-utc", "jpeg"),
        ("deep-sky-astrophoto-2026-03-24-04-53-48-utc", "jpg"),
        ("full-frame-view-of-large-group-on-boulders-at-dusk-2026-03-25-03-17-07-utc", "jpg"),
        ("landscape-of-a-dense-forest-on-a-misty-day-2026-01-07-07-16-45-utc", "jpeg"),
        ("rock-stone-podium-stand-display-isolated-design-s-2026-03-25-04-45-21-utc", "jpg"),
        ("stone-podium-on-dark-background-2026-01-07-02-14-05-utc", "jpg"),
        ("texture-of-marble-exterior-wall-background-2026-01-07-06-30-43-utc", "JPG"),
        ("the-dark-night-sky-above-the-austrian-alps-showing-2026-03-26-11-34-08-utc", "jpg")
    ]

    /// 利用可能な背景画像の総数 (PostComposer のピッカーで使う)
    static var count: Int { imageFiles.count }

    /// 名言IDに基づいて固定の背景画像を返す（同じ名言には常に同じ背景）
    ///
    /// (回収) 旧実装は `abs(quoteId.hashValue) % imageFiles.count` で、
    /// (a) hashValue が Int.min の場合 abs がクラッシュする、
    /// (b) Swift の hashValue はハッシュフラッディング対策でプロセスごとにシードが変わるため
    ///     同じ quoteId でも起動のたびに背景の割当が変わってしまう、の2バグがあった。
    /// quoteId の文字列表現に対する決定的ハッシュ (FNV-1a) + 符号なし演算の剰余に置き換えることで、
    /// 起動を跨いで同じ ID に同じ背景を割り当てる (これが新しい仕様)。
    static func image(for quoteId: UUID) -> UIImage? {
        let hash = fnv1aHash(quoteId.uuidString)
        let index = Int(hash % UInt64(imageFiles.count))
        return image(atIndex: index)
    }

    /// FNV-1a (64bit) ハッシュ。標準ライブラリの hashValue と違ってプロセスをまたいで
    /// 同じ入力に常に同じ値を返す決定的ハッシュで、UInt64 の符号なし演算のみを使うため
    /// abs() のオーバーフロークラッシュも起こり得ない
    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV offset basis
        let prime: UInt64 = 0x100000001b3     // FNV prime
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// index で背景画像を直接取得 (UGC 投稿の background_id 用)
    /// 範囲外 / ロード失敗時は nil
    static func image(atIndex index: Int) -> UIImage? {
        guard index >= 0, index < imageFiles.count else { return nil }
        let file = imageFiles[index]
        if let url = Bundle.main.url(forResource: file.name, withExtension: file.ext) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    /// quoteId と任意の override index から実際に使う画像を返す
    /// (UGC で background_id が指定されていればそれ、なければ hash フォールバック)
    static func image(for quoteId: UUID, overrideIndex: Int?) -> UIImage? {
        if let i = overrideIndex, i >= 0, i < imageFiles.count {
            return image(atIndex: i)
        }
        return image(for: quoteId)
    }
}

// MARK: - Background Image View

struct QuoteBackgroundView: View {
    let quoteId: UUID
    /// 明示的に背景 index を指定 (UGC 投稿の user_posts.background_id)
    /// nil の場合は quoteId の hash で自動割当
    var backgroundIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let uiImage = BackgroundImageProvider.image(for: quoteId, overrideIndex: backgroundIndex) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.5)
                }

                // 上下グラデーションで文字領域を保護
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
