//
//  AvatarImage.swift
//  AppBlocker
//
//  ユーザーアバター表示用の共通コンポーネント。
//  URLSession を直接使う独自実装 (AsyncImage は URL 変更時の挙動が不安定で
//  「画像が反映されない」「クルクル状態が続く」問題が再現した — S15 で URLSession に置き換え)。
//

import SwiftUI

struct AvatarImage: View {
    let urlString: String?
    let size: CGFloat
    var placeholderColor: Color = AppColors.accent

    @State private var loadedImage: UIImage?
    @State private var loadedFor: String?
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image = loadedImage, loadedFor == urlString {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if urlString != nil && isLoading {
                ZStack {
                    Circle().fill(AppColors.cardBackground)
                    ProgressView()
                        .tint(placeholderColor)
                        .scaleEffect(0.6)
                }
                .frame(width: size, height: size)
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(placeholderColor)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { reload() }
        .onChange(of: urlString) { _, _ in reload() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func reload() {
        // URL が変わっていないなら何もしない
        if urlString == loadedFor, loadedImage != nil { return }

        loadTask?.cancel()

        guard let urlString,
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            loadedImage = nil
            loadedFor = nil
            isLoading = false
            return
        }

        isLoading = true
        // 前の画像はクルクル中も出し続けたいので loadedImage は消さない
        // ただし loadedFor の URL とは別なので、表示判定 (loadedFor == urlString) で
        // 古い画像は描画されない仕組み

        let task = Task { @MainActor in
            // L5: PostThumbnailLoader の NSCache を共用し、セル再出現ごとの URLSession 再取得 +
            // フルデコードを回避する (アバター表示は最大 120pt @3x=360px 程度なので 400px サムネで画質は十分)
            if let img = await PostThumbnailLoader.shared.thumbnail(for: url) {
                if Task.isCancelled { return }
                self.loadedImage = img
                self.loadedFor = urlString
            } else if !Task.isCancelled {
                print("⚠️ AvatarImage load failed for \(url)")
            }
            self.isLoading = false
        }
        loadTask = task
    }
}

#Preview {
    ZStack {
        AppColors.background.ignoresSafeArea()

        VStack(spacing: 24) {
            AvatarImage(urlString: nil, size: 80)
            AvatarImage(urlString: "https://example.invalid/missing.png", size: 64)
            AvatarImage(urlString: nil, size: 40)
        }
    }
}
