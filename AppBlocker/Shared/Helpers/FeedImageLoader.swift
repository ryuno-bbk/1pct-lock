//
//  FeedImageLoader.swift
//  AppBlocker
//
//  フィードカード (FeedCardMediaView) 用のフルサイズ画像ローダー。
//  AsyncImage はキャンセルを .failure として phase に固着させ、リトライ機構も無い。
//  スクロール中のキャンセルで画像投稿が quoteMedia (別コンテンツに見える描画) に
//  化けるバグの真因だったため、PostThumbnailLoader と同じ
//  「URLSession + ImageIO + NSCache + キャンセル対応は呼び出し側」の構造に置き換える。
//  ⚠️ PostThumbnailLoader (400px サムネ) とはキャッシュを共有しない。
//  同じ URL をグリッドとフィードが別解像度で使うため、キー衝突するとボケ画像が刺さる。
//

import UIKit
import ImageIO

final class FeedImageLoader {

    static let shared = FeedImageLoader()

    /// 投稿v2 の焼き込み画像は 1080×1350。それを素通しし、想定外の巨大画像だけ抑える上限。
    /// nonisolated 必須: 下の downsample が @concurrent nonisolated なので、
    /// 無印だと MainActor 隔離の static を actor 外から読む形になる (Swift 6 ではエラー)
    nonisolated private static let maxPixelSize: CGFloat = 1400

    /// デコード済みフルサイズ画像のキャッシュ。1枚 ≈ 5.8MB (1080×1350×4byte) なので
    /// 枚数でなくバイト数 (cost) で制限する
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        // AsyncImage 時代はデコード済みキャッシュがゼロだったため、純増を抑えて 32MB に留める
        cache.totalCostLimit = 32 * 1024 * 1024   // 約5枚ぶん。溢れは NSCache が自動追い出し
        cache.countLimit = 24
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        do {
            var request = URLRequest(url: url)
            // 投稿画像の URL は不変 (焼き込み済み) なので再検証不要のキャッシュ優先で良い
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = await Self.downsample(data: data) else { return nil }
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch {
            // キャンセル (スクロールで view が消えた等) と本当の失敗はログだけ分ける。
            // 返り値契約はどちらも nil。キャンセル時に phase を書かない対策は
            // 呼び出し側 (FeedFitBlurImage) が Task.isCancelled で行う
            // ログは DEBUG 限定。スクロール中のキャンセルは頻発する上、この print は
            // MainActor 上で走るため、出荷ビルドで毎回文字列補間を回すコストを避ける
            #if DEBUG
            let isCancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
            if isCancellation {
                print("ℹ️ FeedImageLoader: cancelled for \(url)")
            } else {
                print("⚠️ FeedImageLoader: load failed for \(url): \(error)")
            }
            #endif
            return nil
        }
    }

    /// ImageIO でデコード時点から縮小する (AsyncImage は描画時にフルデコードしていた)。
    /// ⚠️ `@concurrent nonisolated` は必須。このプロジェクトは
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor なので、無注釈だと FeedImageLoader ごと
    /// @MainActor に推論され、フルサイズデコード (実測 17.65ms/枚) がメインスレッドに載って
    /// スクロールのコマ落ちになる。`nonisolated` だけでは NonisolatedNonsendingByDefault に
    /// より呼び出し側 (MainActor) の executor を継承してしまうため、両方を付けて
    /// 明示的にバックグラウンド executor へ逃がす
    @concurrent nonisolated private static func downsample(data: Data) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
