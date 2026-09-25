//
//  UnlockImageStore.swift
//  AppBlocker
//
//  解除課題「自分の画像を見る」で使う画像の保管。
//
//  🔴 端末内だけに保存する。サーバーには絶対に上げない:
//    - 個人的な写真を送ると App Privacy の申告をやり直すことになる
//      (2026-08-04 に 14/14 で確定済み。「写真またはビデオ」の用途が増える)
//    - Storage の egress も増える (M19 で一度踏んでいる)
//    - 他人に見せる必要が一切無い (2026-08-29 ユーザー確認)
//  失うのは「機種変で消える」点だけ。
//

import Foundation
import UIKit
import Combine

@MainActor
final class UnlockImageStore: ObservableObject {

    static let shared = UnlockImageStore()

    /// 登録済み画像の識別子 (新しい順)。実体はファイルとして保存する
    @Published private(set) var imageIds: [String] = []

    /// 登録できる上限。多すぎても選びきれないし、端末容量も食う
    static let maxImages = 20

    private let directory: URL
    private let indexKey = "unlockImages.ids"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("UnlockImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        imageIds = UserDefaults.standard.stringArray(forKey: indexKey) ?? []
        // ファイルが消えている id は落とす (バックアップ復元などでズレることがある)
        let existing = imageIds.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        if existing.count != imageIds.count {
            imageIds = existing
            persistIndex()
        }
    }

    var canAddMore: Bool { imageIds.count < Self.maxImages }

    // MARK: - 読み書き

    func image(for id: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path)
    }

    /// 追加する。⚠️ 長辺を抑えてから保存する。
    /// 原寸のまま持つと1枚で十数MBになり、端末容量とデコード時間を無駄に食う
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

    // MARK: - 内部

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
