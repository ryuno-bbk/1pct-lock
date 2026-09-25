//
//  PostThumbnailLoader.swift
//  AppBlocker
//
//  投稿サムネイル (M5) 用のダウンサンプル + メモリキャッシュローダー。
//  投稿v2の焼き込み画像は 1080×1350 前後 (1枚 5.5MB 前後) あり、AsyncImage +
//  Image(uiImage:) の組み合わせだとプロフィールの 3 列グリッドを開くたびに
//  表示枚数分のフルデコードが走ってメモリ・CPU を圧迫していた。
//  ImageIO の CGImageSourceCreateThumbnailAtIndex はデコード時点から縮小するため、
//  400px サムネなら約 0.6MB で済む。NSCache でセル再出現時の再取得・再デコードも防ぐ。
//  アバターも表示サイズが小さい (最大 120pt @3x=360px 程度) ので、
//  AvatarImage (L5) からも同じキャッシュ/デコード経路を共用する。
//

import UIKit
import ImageIO

final class PostThumbnailLoader {

    static let shared = PostThumbnailLoader()

    /// サムネイルの最大辺ピクセル数。グリッド/アバターいずれの表示サイズも十分にカバーする
    private static let maxPixelSize: CGFloat = 400

    /// デコード済み UIImage の URL 単位メモリキャッシュ。
    /// NSCache はスレッドセーフなので、複数セルからの同時アクセスでもロック不要
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    /// URL からダウンサンプル済みサムネイルを取得する。
    /// キャッシュヒット時はネットワーク・デコードを両方スキップして即座に返す
    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        do {
            var request = URLRequest(url: url)
            // URLSession.shared 標準の URLCache に乗せる (M18 で拡張予定のキャッシュ層の恩恵を受ける)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let thumbnail = Self.downsample(data: data) else { return nil }
            cache.setObject(thumbnail, forKey: url as NSURL)
            return thumbnail
        } catch {
            // 実機FB#1 真因: 呼び出し元 (LazyVGrid セル) の再出現/レイアウト揺れで
            // Task がキャンセルされると URLSession は URLError(.cancelled)
            // (まれに CancellationError) を投げるが、従来は「本当のロード失敗」と
            // 同一視して警告ログを出し nil を返していた。呼び出し側がその nil を
            // 恒久失敗として @State に保存し、画像投稿が石背景 (QuoteBackgroundView)
            // に化けたまま戻らなくなる不具合につながっていた。
            // ここではログを分けるだけで返り値契約 (nil を返す) は変えない。
            // キャンセル時に @State を書かない対策は呼び出し側 (UserPostGridCell) で行う。
            let isCancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
            if isCancellation {
                print("ℹ️ PostThumbnailLoader: cancelled for \(url)")
            } else {
                print("⚠️ PostThumbnailLoader: load failed for \(url): \(error)")
            }
            return nil
        }
    }

    /// ImageIO でフルデコードを避けてサムネイルだけを作る
    /// (1080×1350 のフルデコード 約5.5MB が 400px サムネ 約0.6MB になる)
    private static func downsample(data: Data) -> UIImage? {
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
