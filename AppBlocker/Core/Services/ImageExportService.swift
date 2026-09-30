//
//  ImageExportService.swift
//  AppBlocker
//
//  Render a feed card (FeedItem) into a 1080×1920 UIImage through ShareableQuoteCard, and
//  save it to the camera roll with the Photos framework.
//

import Photos
import SwiftUI
import UIKit

enum ImageExportError: Error, Equatable {
    case permissionDenied
    case renderFailed
    case saveFailed
    /// Post v2: failed to download the baked image (Storage post-images)
    case downloadFailed
}

@MainActor
final class ImageExportService {

    static let shared = ImageExportService()
    private init() {}

    /// Turn a FeedItem into an image and save it to the camera roll.
    /// Post v2 (with imagePath) downloads the baked image,
    /// composites the brand watermark (AreteWatermark) at the bottom right, then saves it.
    /// - Throws: `ImageExportError`
    func saveQuoteImage(item: FeedItem, lang: AppLanguage, showOriginal: Bool) async throws {
        try await ensureAddOnlyPermission()

        if let imageUrl = item.imageUrl {
            let uiImage = try await downloadImage(from: imageUrl)
            let watermarked = compositeWatermark(on: uiImage)
            try await addImageToPhotoLibrary(watermarked)
            return
        }

        let uiImage = try renderImage(item: item, lang: lang, showOriginal: showOriginal)
        try await addImageToPhotoLibrary(uiImage)
    }

    /// Composite AreteWatermark at the bottom right of the baked image (the image is assumed to be 1080px
    /// wide, so the mark sits at the same ratio as ShareableQuoteCard's 1080 canvas). Returns the original
    /// image on failure.
    private func compositeWatermark(on image: UIImage) -> UIImage {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }

        let content = ZStack(alignment: .bottomTrailing) {
            Image(uiImage: image)
                .resizable()

            AreteWatermark()
                .padding(.trailing, 40)
                .padding(.bottom, 40)
        }
        .frame(width: pixelSize.width, height: pixelSize.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage ?? image
    }

    // MARK: - Download (post v2: baked image)

    private func downloadImage(from url: URL) async throws -> UIImage {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                throw ImageExportError.downloadFailed
            }
            return image
        } catch let error as ImageExportError {
            throw error
        } catch {
            throw ImageExportError.downloadFailed
        }
    }

    // MARK: - Permission

    private func ensureAddOnlyPermission() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized || newStatus == .limited else {
                throw ImageExportError.permissionDenied
            }
        case .denied, .restricted:
            throw ImageExportError.permissionDenied
        @unknown default:
            throw ImageExportError.permissionDenied
        }
    }

    // MARK: - Render

    private func renderImage(item: FeedItem, lang: AppLanguage, showOriginal: Bool) throws -> UIImage {
        let view = ShareableQuoteCard(item: item, lang: lang, showOriginal: showOriginal)

        let renderer = ImageRenderer(content: view)
        // ShareableQuoteCard itself is .frame'd with renderSize, so scale=1 gives exactly 1080×1920
        renderer.scale = 1.0

        guard let uiImage = renderer.uiImage else {
            throw ImageExportError.renderFailed
        }
        return uiImage
    }

    // MARK: - Save

    private func addImageToPhotoLibrary(_ uiImage: UIImage) async throws {
        // The async version of performChanges has strict Sendable requirements, so wrap it in a continuation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: uiImage)
            } completionHandler: { success, _ in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ImageExportError.saveFailed)
                }
            }
        }
    }
}
