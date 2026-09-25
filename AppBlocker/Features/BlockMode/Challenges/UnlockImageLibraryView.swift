//
//  UnlockImageLibraryView.swift
//  AppBlocker
//
//  解除課題「自分の画像を見る」で見せる画像の登録場所。
//  解除方法シートの「自分の画像を見る」行の右にある ＋ から開く (2026-08-29 ユーザー指定)。
//
//  🔴 画像は端末内だけに保存する (UnlockImageStore 参照)。サーバーには上げない。
//

import SwiftUI
import PhotosUI

struct UnlockImageLibraryView: View {

    let lang: AppLanguage

    @ObservedObject private var store = UnlockImageStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var deleteCandidate: String?

    private var ja: Bool { lang == .japanese }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // ⚠️ 文言はユーザー添削待ち
                    Text(ja
                         ? "ロックを解除しようとした時に、ここに登録した画像が順に出ます"
                         : "These images are shown when you try to unlock")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    addButton

                    if !store.imageIds.isEmpty {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.imageIds, id: \.self) { id in
                                thumbnail(id)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(ja ? "自分の画像" : "Your images") // 文言はユーザー添削待ち
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ja ? "完了" : "Done") { dismiss() }
                }
            }
            .alert(ja ? "この画像を削除しますか" : "Delete this image?", isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )) {
                Button(ja ? "キャンセル" : "Cancel", role: .cancel) { deleteCandidate = nil }
                Button(ja ? "削除" : "Delete", role: .destructive) {
                    if let id = deleteCandidate { store.remove(id) }
                    deleteCandidate = nil
                }
            }
        }
    }

    private var addButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(1, UnlockImageStore.maxImages - store.imageIds.count),
            matching: .images
        ) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text(ja ? "写真を追加" : "Add photos") // 文言はユーザー添削待ち
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(store.canAddMore ? AppColors.textPrimary : AppColors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppColors.cardBackground)
            )
        }
        .disabled(!store.canAddMore || isLoading)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .overlay(alignment: .trailing) {
            if isLoading {
                ProgressView().padding(.trailing, 16)
            }
        }
    }

    private func thumbnail(_ id: String) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = store.image(for: id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppColors.secondaryBackground)
                    .frame(height: 120)
            }

            Button {
                deleteCandidate = id
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        isLoading = true
        defer {
            isLoading = false
            pickerItems = []
        }
        for item in items {
            guard store.canAddMore else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            store.add(image)
        }
    }
}
