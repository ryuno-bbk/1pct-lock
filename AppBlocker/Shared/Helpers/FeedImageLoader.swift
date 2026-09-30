//
//  FeedImageLoader.swift
//  AppBlocker
//
//  Full-size image loader for feed cards (FeedCardMediaView).
//  AsyncImage gets stuck in phase with a cancellation as .failure and has no retry mechanism.
//  That was the real cause of the bug where an image post turned into quoteMedia (a rendering that
//  looks like different content) when cancelled during scrolling, so it is replaced with the same
//  structure as PostThumbnailLoader: "URLSession + ImageIO + NSCache + cancellation handled by the
//  caller".
//  ⚠️ Does not share its cache with PostThumbnailLoader (400px thumbnails).
//  The grid and the feed use the same URL at different resolutions, so a key collision would stick a
//  blurry image in.
//

import UIKit
import ImageIO

final class FeedImageLoader {

    static let shared = FeedImageLoader()

    /// Post v2 baked-in images are 1080×1350. This is an upper limit that lets those pass and only reins in
    /// unexpectedly huge images. nonisolated is required: downsample below is @concurrent nonisolated, so
    /// without it we would read a MainActor-isolated static from outside the actor (an error in Swift 6)
    nonisolated private static let maxPixelSize: CGFloat = 1400

    /// Cache of decoded full-size images. 1 image ≈ 5.8MB (1080×1350×4byte), so
    /// limit by bytes (cost), not by count
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        // In the AsyncImage days there was no decoded cache at all, so keep the net increase down at 32MB
        cache.totalCostLimit = 32 * 1024 * 1024   // about 5 images' worth. NSCache evicts overflow automatically
        cache.countLimit = 24
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        do {
            var request = URLRequest(url: url)
            // Post image URLs are immutable (baked in), so cache-first without revalidation is fine
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = await Self.downsample(data: data) else { return nil }
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch {
            // Separate cancellation (the view disappeared by scrolling, etc.) from real failure only in the log.
            // The return contract is nil for both. Not writing phase on cancellation is handled
            // by the caller (FeedFitBlurImage) with Task.isCancelled
            // Logging is DEBUG only. Cancellations happen often during scrolling, and this print
            // runs on the MainActor, so avoid the cost of string interpolation on every call in shipping builds
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

    /// Downscale with ImageIO from decode time (AsyncImage did a full decode at draw time).
    /// ⚠️ `@concurrent nonisolated` is required. This project has
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so without annotations the whole FeedImageLoader is
    /// inferred as @MainActor, and the full-size decode (measured 17.65ms/image) lands on the main thread,
    /// dropping frames while scrolling. With only `nonisolated`, NonisolatedNonsendingByDefault
    /// makes it inherit the caller's (MainActor) executor, so both are added to
    /// explicitly move it to a background executor
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
