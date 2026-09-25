//
//  ImageExportService.swift
//  AppBlocker
//
//  フィードカード (FeedItem) を ShareableQuoteCard 経由で 1080×1920 の UIImage にレンダリングし、
//  Photos フレームワークでカメラロールに保存する。
//

import Photos
import SwiftUI
import UIKit

enum ImageExportError: Error, Equatable {
    case permissionDenied
    case renderFailed
    case saveFailed
    /// 投稿v2: 焼き込み済み画像 (Storage post-images) のダウンロードに失敗
    case downloadFailed
}

@MainActor
final class ImageExportService {

    static let shared = ImageExportService()
    private init() {}

    /// FeedItem を画像化してカメラロールに保存する。
    /// 投稿v2 (imagePath 付き) は焼き込み済み画像をダウンロードし、
    /// 右下にブランドウォーターマーク (AreteWatermark) を合成してから保存する。
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

    /// 焼き込み済み画像の右下に AreteWatermark を合成する (画像は 1080px 幅想定、
    /// ShareableQuoteCard の 1080 キャンバスと同じ比率でマークが乗る)。失敗時は元画像を返す。
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

    // MARK: - Download (投稿v2: 焼き込み済み画像)

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
        // ShareableQuoteCard 自体が renderSize で .frame されているので scale=1 でちょうど 1080×1920
        renderer.scale = 1.0

        guard let uiImage = renderer.uiImage else {
            throw ImageExportError.renderFailed
        }
        return uiImage
    }

    // MARK: - Save

    private func addImageToPhotoLibrary(_ uiImage: UIImage) async throws {
        // performChanges の async 版は Sendable 要求が厳しいので continuation で包む
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
