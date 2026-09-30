//
//  PostBackgroundGridView.swift
//  AppBlocker
//
//  UGC post v2 Step1: choose a background.
//  The main elements are the 2 big tiles [Camera] [Library] (the goal is to have users shoot what they
//  are working on right now, on the spot).
//  Black/white/14 templates are stored in the collapsible "テンプレートから選ぶ" ("Choose from
//  templates") section.
//  The moment one is tapped, the background is fixed and it goes to Step2 (StoryTextEditorView).
//  Photos are downsampled to 2000px on the long side when selected, then kept.
//

import SwiftUI
import PhotosUI
import UIKit

struct PostBackgroundGridView: View {
    @ObservedObject var draft: PostDraft
    /// Callback to push to Step2 after the background is fixed
    let onChosen: () -> Void
    /// The × button closes the whole post flow (sheet) (2026-07-25 real-device feedback: × and back
    /// behaved the same).
    /// When nil, it goes back one level as before (nil is passed while adding images from the confirmation
    /// screen, to protect the draft)
    var onCloseFlow: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var showCamera = false
    // Coming from "テンプレートから選ぶ" ("Choose from templates") on the camera screen became the main
    // path, so it starts expanded
    // (if it is closed, users ask "where are the templates?". 2026-07-11 real-device feedback)
    @State private var isTemplatesExpanded = true

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Main elements: the 2 big tiles Camera / Library
                HStack(spacing: 10) {
                    if isCameraAvailable {
                        heroTile(icon: "camera.fill", label: PostFlowStrings.cameraLabel(lang)) {
                            showCamera = true
                        }
                    }

                    PhotosPicker(selection: $photoPickerItem, matching: .images, photoLibrary: .shared()) {
                        heroTileLabel(icon: "photo.on.rectangle", label: PostFlowStrings.libraryLabel(lang))
                    }
                    .disabled(isLoadingPhoto)
                }

                // Templates are collapsible (black/white/14 templates)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { isTemplatesExpanded.toggle() }
                } label: {
                    HStack {
                        Text(PostFlowStrings.templateSectionLabel(lang))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textTertiary)
                            .rotationEffect(.degrees(isTemplatesExpanded ? 180 : 0))
                    }
                    .padding(.vertical, 10)
                }

                if isTemplatesExpanded {
                    LazyVGrid(columns: columns, spacing: 10) {
                        colorCell(fill: .black) { select(.black) }
                        colorCell(fill: AppColors.textPrimary) { select(.white) }

                        ForEach(0..<BackgroundImageProvider.count, id: \.self) { idx in
                            templateCell(idx)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle(PostFlowStrings.step1Title(lang))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // × = close the whole flow (a separate role from back = go back one level)
                    if let onCloseFlow {
                        onCloseFlow()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image {
                    let resized = downsample(image, maxDimension: 2000)
                    select(.photo(resized))
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Cells

    private func heroTile(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            heroTileLabel(icon: icon, label: label)
        }
    }

    private func heroTileLabel(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            if isLoadingPhoto && icon == "photo.on.rectangle" {
                ProgressView().tint(AppColors.textPrimary)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func colorCell(fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            cellShape {
                fill
            }
        }
    }

    private func templateCell(_ index: Int) -> some View {
        Button {
            select(.template(index))
        } label: {
            cellShape {
                if let image = BackgroundImageProvider.image(atIndex: index) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
        }
    }

    /// Frame/rounded corners/border shared by all cells (ratio 4:5 = same as the post canvas, corner
    /// radius 8). Fixing the container (Color.clear + aspectRatio) first and then overlaying the content
    /// avoids the problem where Image's resizable().fill pushes the layout wider and breaks the cell.
    private func cellShape<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay(
                content()
                    .scaledToFill()
            )
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Actions

    /// Fix the background: PostDraft.selectBackground (logic shared with the camera screen) → go to Step2
    private func select(_ background: PostBackground) {
        if draft.selectBackground(background) {
            onChosen()
        }
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer {
            isLoadingPhoto = false
            photoPickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let original = UIImage(data: data) else {
            print("⚠️ PostBackgroundGridView: failed to load selected photo")
            return
        }
        let resized = downsample(original, maxDimension: 2000)
        select(.photo(resized))
    }

    /// Fit the long side within maxDimension (keeping the aspect ratio). If already smaller, return it as is.
    private func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let ratio = maxDimension / longSide
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - CameraPicker (SwiftUI wrapper for UIImagePickerController)

/// Picker for taking a photo with the camera on the spot and using it as the background photo.
/// PhotosUI has no camera equivalent, so UIImagePickerController is used (isSourceTypeAvailable is
/// false on the simulator).
private struct CameraPicker: UIViewControllerRepresentable {
    /// Shooting finished (nil when canceled)
    let onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (UIImage?) -> Void

        init(onComplete: @escaping (UIImage?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onComplete(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }
    }
}
