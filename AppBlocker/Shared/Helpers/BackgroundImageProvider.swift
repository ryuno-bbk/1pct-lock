//
//  BackgroundImageProvider.swift
//  AppBlocker
//
//  Assigns a random (but fixed) background image to each quote
//  UGC posts can specify it explicitly with user_posts.background_id (S14 onward)
//

import SwiftUI

enum BackgroundImageProvider {

    // Files in the Backgrounds folder (name, extension)
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

    /// Total number of available background images (used by the picker in PostComposer)
    static var count: Int { imageFiles.count }

    /// Returns a fixed background image based on the quote ID (the same quote always gets the same background)
    ///
    /// (Cleanup) The old implementation used `abs(quoteId.hashValue) % imageFiles.count` and had 2 bugs:
    /// (a) abs crashes when hashValue is Int.min,
    /// (b) Swift's hashValue changes its seed per process to prevent hash flooding, so
    ///     the same quoteId got a different background on every launch.
    /// Replacing it with a deterministic hash (FNV-1a) of the quoteId string + modulo with unsigned
    /// arithmetic assigns the same background to the same ID across launches (this is the new spec).
    static func image(for quoteId: UUID) -> UIImage? {
        let hash = fnv1aHash(quoteId.uuidString)
        let index = Int(hash % UInt64(imageFiles.count))
        return image(atIndex: index)
    }

    /// FNV-1a (64bit) hash. Unlike the standard library's hashValue, it is a deterministic hash that always
    /// returns the same value for the same input across processes, and it only uses unsigned UInt64
    /// arithmetic, so the abs() overflow crash cannot happen
    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV offset basis
        let prime: UInt64 = 0x100000001b3     // FNV prime
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Get a background image directly by index (for background_id of UGC posts)
    /// nil if out of range / load fails
    static func image(atIndex index: Int) -> UIImage? {
        guard index >= 0, index < imageFiles.count else { return nil }
        let file = imageFiles[index]
        if let url = Bundle.main.url(forResource: file.name, withExtension: file.ext) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    /// Returns the image actually used, from the quoteId and an optional override index
    /// (if background_id is set for UGC, use it, otherwise fall back to the hash)
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
    /// Explicitly specify the background index (user_posts.background_id of a UGC post)
    /// If nil, it is assigned automatically by the hash of quoteId
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

                // Top and bottom gradient to protect the text area
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
