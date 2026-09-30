//
//  AvatarImage.swift
//  AppBlocker
//
//  Shared component for showing user avatars.
//  A custom implementation that uses URLSession directly (AsyncImage behaved unstably when the URL
//  changed, and the problems "the image is not updated" and "the spinner keeps going" were
//  reproduced; replaced with URLSession in S15).
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
        // If the URL has not changed, do nothing
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
        // Keep showing the previous image while the spinner runs, so loadedImage is not cleared.
        // However, it differs from the URL in loadedFor, so with the display check (loadedFor == urlString)
        // the old image is not drawn

        let task = Task { @MainActor in
            // L5: share the NSCache of PostThumbnailLoader, avoiding a URLSession re-fetch + full decode every time
            // a cell reappears (avatars are shown at most about 120pt @3x=360px, so a 400px thumbnail has enough
            // quality)
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
