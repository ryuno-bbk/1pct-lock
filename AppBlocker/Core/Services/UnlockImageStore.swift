//
//  UnlockImageStore.swift
//  AppBlocker
//
//  Storage for the images used by the unlock challenge "自分の画像を見る" ("View my images").
//
//  🔴 Stored only on the device. Never upload to the server:
//    - Sending personal photos would mean redoing the App Privacy declaration
//      (finalized at 14/14 on 2026-08-04. The "Photos or Videos" use would be added)
//    - Storage egress would also increase (we already hit that once in M19)
//    - There is no need at all to show them to anyone else (confirmed by the user 2026-08-29)
//  The only loss is that "they disappear when you change phones".
//

import Foundation
import UIKit
import Combine

@MainActor
final class UnlockImageStore: ObservableObject {

    static let shared = UnlockImageStore()

    /// Identifiers of registered images (newest first). The actual data is saved as files
    @Published private(set) var imageIds: [String] = []

    /// Upper limit on how many can be registered. Too many is hard to choose from and uses device storage
    static let maxImages = 20

    private let directory: URL
    private let indexKey = "unlockImages.ids"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("UnlockImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        imageIds = UserDefaults.standard.stringArray(forKey: indexKey) ?? []
        // Drop ids whose files are gone (can get out of sync after e.g. a backup restore)
        let existing = imageIds.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        if existing.count != imageIds.count {
            imageIds = existing
            persistIndex()
        }
    }

    var canAddMore: Bool { imageIds.count < Self.maxImages }

    // MARK: - Read/write

    func image(for id: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path)
    }

    /// Add one. ⚠️ Limit the long side before saving.
    /// Kept at original size, one image can be over ten MB, wasting device storage and decode time
    @discardableResult
    func add(_ image: UIImage) -> String? {
        guard canAddMore else { return nil }
        let resized = Self.downsample(image, maxDimension: 1600)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }

        let id = UUID().uuidString
        do {
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            print("⚠️ Failed to save unlock image: \(error)")
            return nil
        }
        imageIds.insert(id, at: 0)
        persistIndex()
        return id
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        imageIds.removeAll { $0 == id }
        persistIndex()
    }

    // MARK: - Internal

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).jpg")
    }

    private func persistIndex() {
        UserDefaults.standard.set(imageIds, forKey: indexKey)
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let ratio = maxDimension / longSide
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
