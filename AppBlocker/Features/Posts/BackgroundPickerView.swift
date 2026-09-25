//
//  BackgroundPickerView.swift
//  AppBlocker
//
//  UGC 投稿 Step 2: 背景画像を選ぶ画面
//  - 14 種すべてに「ユーザーが入力した言葉が乗ったプレビュー」を表示
//  - 横 2 列のスマホ形 (9:16) グリッド
//  - タップで選択、右上「投稿」で確定
//

import SwiftUI

struct BackgroundPickerView: View {
    /// PostComposerView で入力されたテキスト/タグ (プレビュー用、編集不可)
    let previewTextJp: String?
    let previewTextEn: String?
    let previewTags: [String]
    /// 「投稿」タップ時に呼ばれる。Int = 選択された背景 index
    let onSubmit: (Int) async -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var postService = UserPostService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    @State private var selectedIndex: Int = 0

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<BackgroundImageProvider.count, id: \.self) { idx in
                        previewCard(index: idx)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedIndex = idx
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(L.postsComposerBackgroundTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L.postsComposerBack(lang)) {
                        dismiss()
                    }
                    .foregroundColor(AppColors.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if postService.isCreating {
                        ProgressView().tint(AppColors.accent)
                    } else {
                        Button(L.postsComposerSubmit(lang)) {
                            Task { await onSubmit(selectedIndex) }
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.accent)
                    }
                }
            }
        }
    }

    // MARK: - Preview card

    private func previewCard(index: Int) -> some View {
        let isSelected = (selectedIndex == index)
        return ZStack(alignment: .topTrailing) {
            previewBody(index: index)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isSelected ? AppColors.accent : Color.white.opacity(0.12),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                .shadow(color: .black.opacity(isSelected ? 0.5 : 0.25), radius: isSelected ? 8 : 4, x: 0, y: 2)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(AppColors.background)
                    .background(Circle().fill(AppColors.accent))
                    .padding(8)
            }
        }
    }

    /// FeedItemCard のミニ版 (背景 + 中央テキスト + 左下著者)
    private func previewBody(index: Int) -> some View {
        ZStack {
            // 背景画像 (FeedItemCard と同じ作り)
            QuoteBackgroundView(quoteId: previewIdSeed, backgroundIndex: index)

            // 中央テキスト (FeedItemCard と同じレイアウト、フォントだけ縮小)
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text("\"\(displayPrimary)\"")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .lineLimit(8)
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 10)

                if let secondary = displaySecondary {
                    Text(secondary)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .lineLimit(3)
                        .padding(.top, 4)
                        .padding(.horizontal, 10)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                }

                Spacer(minLength: 0)
            }

            // 左下: 著者 + タグ
            VStack(alignment: .leading, spacing: 4) {
                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)

                    Text(authorDisplayName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                if let firstTag = previewTags.first {
                    Text("#\(Quote.categoryDisplay(firstTag, lang: lang))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 8)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Helpers

    /// プレビュー時の hash seed (実投稿の id とは別、背景は backgroundIndex 優先なので影響なし)
    private var previewIdSeed: UUID { UUID() }

    private var displayPrimary: String {
        let jp = previewTextJp ?? ""
        let en = previewTextEn ?? ""

        if lang == .japanese && showOriginal && !en.isEmpty {
            return en
        }
        switch lang {
        case .japanese: return jp.isEmpty ? en : jp
        case .english:  return en.isEmpty ? jp : en
        }
    }

    private var displaySecondary: String? {
        guard lang == .japanese, showOriginal,
              let jp = previewTextJp, !jp.isEmpty,
              let en = previewTextEn, !en.isEmpty else { return nil }
        return jp
    }

    private var authorDisplayName: String {
        if let name = auth.displayName, !name.isEmpty { return name }
        return lang == .japanese ? "あなた" : "You"
    }
}
