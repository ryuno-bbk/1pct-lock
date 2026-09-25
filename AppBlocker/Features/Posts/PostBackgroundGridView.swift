//
//  PostBackgroundGridView.swift
//  AppBlocker
//
//  UGC 投稿 v2 Step1: 背景を選ぶ。
//  主役は [カメラ] [ライブラリ] の2大タイル (今の作業をその場で撮らせるのが目的)。
//  黒/白/テンプレ14種は「テンプレートから選ぶ」の折りたたみに格納する。
//  タップした瞬間に背景を確定して Step2 (StoryTextEditorView) へ進む。
//  写真は選択時に長辺2000pxへダウンサンプルしてから保持する。
//

import SwiftUI
import PhotosUI
import UIKit

struct PostBackgroundGridView: View {
    @ObservedObject var draft: PostDraft
    /// 背景確定後に Step2 へ push するためのコールバック
    let onChosen: () -> Void
    /// × ボタンで投稿フロー全体 (シート) を閉じる (2026-07-25 実機FB: × と戻るが同じ挙動だった)。
    /// nil のときは従来どおり1段戻る (確認画面からの画像追加中はドラフト保護のため nil を渡す)
    var onCloseFlow: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var showCamera = false
    // カメラ画面の「テンプレートから選ぶ」から来るのが主動線になったため、初期状態で展開
    // (閉じていると「テンプレートどこ?」になる。2026-07-11 実機FB)
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
                // 主役: カメラ / ライブラリ の2大タイル
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

                // テンプレートは折りたたみ (黒/白/テンプレ14)
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
                    // × = フロー全体を閉じる (戻る = 1段戻る、と役割を分ける)
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

    /// 全セル共通のフレーム/角丸/枠線 (比率 4:5 = 投稿キャンバスと同じ、角丸8)。
    /// 器 (Color.clear + aspectRatio) を先に確定させてから中身を overlay することで、
    /// Image の resizable().fill がレイアウトを押し広げてセルが崩れる問題を回避する。
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

    /// 背景確定: PostDraft.selectBackground (カメラ画面と共通ロジック) → Step2 へ進む
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

    /// 長辺を maxDimension に収める (アスペクト比維持)。すでに小さければそのまま返す。
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

// MARK: - CameraPicker (UIImagePickerController の SwiftUI ラッパー)

/// その場でカメラ撮影して背景写真に使うためのピッカー。
/// PhotosUI にカメラ相当が無いため UIImagePickerController を使う (シミュレータでは isSourceTypeAvailable が false)。
private struct CameraPicker: UIViewControllerRepresentable {
    /// 撮影完了 (キャンセル時は nil)
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
