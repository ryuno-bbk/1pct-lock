//
//  PostThumbnailLoader.swift
//  AppBlocker
//
//  Downsample + memory cache loader for post thumbnails (M5).
//  Post v2 baked-in images are around 1080×1350 (around 5.5MB each), and with AsyncImage +
//  Image(uiImage:), every time the 3-column profile grid was opened a full decode ran
//  for every visible image, putting pressure on memory and CPU.
//  ImageIO's CGImageSourceCreateThumbnailAtIndex downscales from decode time, so
//  a 400px thumbnail takes only about 0.6MB. NSCache also prevents re-fetching and re-decoding when a
//  cell reappears. Avatars are also shown small (at most about 120pt @3x=360px), so
//  AvatarImage (L5) shares the same cache/decode path.
//

import UIKit
import ImageIO

final class PostThumbnailLoader {

    static let shared = PostThumbnailLoader()

    /// Max pixel size of the longest side of a thumbnail. Covers the display size of both the grid and avatars
    private static let maxPixelSize: CGFloat = 400

    /// Per-URL memory cache of decoded UIImages.
    /// NSCache is thread-safe, so no lock is needed even with concurrent access from multiple cells
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    /// Get a downsampled thumbnail from a URL.
    /// On a cache hit, skip both network and decode and return immediately
    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        do {
            var request = URLRequest(url: url)
            // Use the standard URLCache of URLSession.shared (benefits from the cache layer planned to be expanded
            // in M18)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let thumbnail = Self.downsample(data: data) else { return nil }
            cache.setObject(thumbnail, forKey: url as NSURL)
            return thumbnail
        } catch {
            // Real cause of real device feedback #1: when the Task is cancelled because the caller (LazyVGrid cell)
            // reappears or the layout shifts, URLSession throws URLError(.cancelled)
            // (rarely CancellationError), but before this it was treated the same as a "real load failure",
            // logging a warning and returning nil. The caller saved that nil to @State as
            // a permanent failure, which led to the bug where an image post turned into the stone background
            // (QuoteBackgroundView) and never came back.
            // Here we only separate the logs and do not change the return contract (returns nil).
            // Not writing @State on cancellation is handled by the caller (UserPostGridCell).
            let isCancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
            if isCancellation {
                print("ℹ️ PostThumbnailLoader: cancelled for \(url)")
            } else {
                print("⚠️ PostThumbnailLoader: load failed for \(url): \(error)")
            }
            return nil
        }
    }

    /// Avoid a full decode with ImageIO and make only the thumbnail
    /// (a 1080×1350 full decode of about 5.5MB becomes a 400px thumbnail of about 0.6MB)
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
