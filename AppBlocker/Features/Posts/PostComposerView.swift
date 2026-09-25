//
//  PostComposerView.swift
//  AppBlocker
//
//  UGC 投稿作成画面 (Step 1: テキスト入力 + タグ選択)
//  - 両言語ともドロップダウンカード化 (メイン言語デフォルト展開)
//  - 既存のシステムフォントを維持、金はフォーカス枠/細線のみアクセント (控えめ)
//

import SwiftUI

struct PostComposerView: View {
    @ObservedObject private var postService = UserPostService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var textJp: String = ""
    @State private var textEn: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var isJpExpanded: Bool = true
    @State private var isEnExpanded: Bool = false
    @State private var showBackgroundPicker: Bool = false
    @FocusState private var focused: FieldFocus?

    private let maxJp = 200
    private let maxEn = 400
    private let maxTags = 3

    enum FieldFocus: Hashable { case jp, en }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var trimmedJp: String { textJp.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEn: String { textEn.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canContinue: Bool {
        let hasJp = !trimmedJp.isEmpty && trimmedJp.count <= maxJp
        let hasEn = !trimmedEn.isEmpty && trimmedEn.count <= maxEn
        return (hasJp || hasEn) && !postService.isCreating
    }

    private let availableTags: [String] = [
        "mindset", "action", "discipline", "work-ethic",
        "growth", "hardship", "self-belief", "consistency",
        "failure", "focus", "fear", "sports",
        "philosophy", "success", "motivation", "life"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // メイン言語側 (デフォルト展開) → サブ言語側 (デフォルト折りたたみ)
                        if lang == .japanese {
                            disclosureCard(
                                title: "日本語",
                                isExpanded: $isJpExpanded,
                                text: $textJp,
                                max: maxJp,
                                focus: .jp,
                                placeholderLang: .japanese
                            )
                            disclosureCard(
                                title: "英語 / English",
                                isExpanded: $isEnExpanded,
                                text: $textEn,
                                max: maxEn,
                                focus: .en,
                                placeholderLang: .english
                            )
                        } else {
                            disclosureCard(
                                title: "English",
                                isExpanded: $isEnExpanded,
                                text: $textEn,
                                max: maxEn,
                                focus: .en,
                                placeholderLang: .english
                            )
                            disclosureCard(
                                title: "日本語 / Japanese",
                                isExpanded: $isJpExpanded,
                                text: $textJp,
                                max: maxJp,
                                focus: .jp,
                                placeholderLang: .japanese
                            )
                        }

                        tagsPicker
                    }
                    .padding(20)
                }
            }
            .navigationTitle(L.postsComposerTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L.postsComposerCancel(lang)) {
                        dismiss()
                    }
                    .foregroundColor(AppColors.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        focused = nil
                        showBackgroundPicker = true
                    } label: {
                        Text(L.postsComposerNext(lang))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(
                                canContinue
                                ? AnyShapeStyle(AppColors.accent)
                                : AnyShapeStyle(AppColors.textTertiary)
                            )
                    }
                    .disabled(!canContinue)
                }
            }
            .onAppear {
                if lang == .japanese {
                    isJpExpanded = true
                    isEnExpanded = false
                    focused = .jp
                } else {
                    isEnExpanded = true
                    isJpExpanded = false
                    focused = .en
                }
            }
            .fullScreenCover(isPresented: $showBackgroundPicker) {
                BackgroundPickerView(
                    previewTextJp: trimmedJp.isEmpty ? nil : trimmedJp,
                    previewTextEn: trimmedEn.isEmpty ? nil : trimmedEn,
                    previewTags: Array(selectedTags),
                    onSubmit: { backgroundIndex in
                        await submit(backgroundIndex: backgroundIndex)
                    }
                )
            }
        }
    }

    // MARK: - Disclosure Card (両言語共通)

    private func disclosureCard(
        title: String,
        isExpanded: Binding<Bool>,
        text: Binding<String>,
        max: Int,
        focus: FieldFocus,
        placeholderLang: AppLanguage
    ) -> some View {
        let isFocused = (focused == focus)
        let isOver = text.wrappedValue.count > max

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
                if isExpanded.wrappedValue {
                    focused = focus
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    Text(lang == .japanese ? "(任意)" : "(optional)")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)

                    Spacer()

                    Text(L.postsComposerCharCount(text.wrappedValue.count, max))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isOver ? AppColors.error : AppColors.textTertiary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded.wrappedValue {
                textEditor(
                    text: text,
                    max: max,
                    focus: focus,
                    placeholderLang: placeholderLang
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.cardBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isFocused
                    ? AnyShapeStyle(AppColors.accent.opacity(0.85))
                    : AnyShapeStyle(AppColors.textTertiary.opacity(0.22)),
                    lineWidth: isFocused ? 1.2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    private func textEditor(
        text: Binding<String>,
        max: Int,
        focus: FieldFocus,
        placeholderLang: AppLanguage
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(L.postsComposerPlaceholder(placeholderLang))
                    .font(.system(size: 17))
                    .foregroundColor(AppColors.textTertiary)
                    .padding(.top, 12)
                    .padding(.leading, 8)
            }

            TextEditor(text: text)
                .focused($focused, equals: focus)
                .font(.system(size: 17))
                .foregroundColor(AppColors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.count > max {
                        text.wrappedValue = String(newValue.prefix(max))
                    }
                }
        }
        .padding(8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tags

    private var tagsPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.postsComposerTags(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                Text("\(selectedTags.count) / \(maxTags)")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
            }

            FlowLayout(spacing: 8) {
                ForEach(availableTags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = selectedTags.contains(tag)
        let canSelect  = selectedTags.count < maxTags
        let disabled   = !isSelected && !canSelect

        return Button {
            if isSelected {
                selectedTags.remove(tag)
            } else if canSelect {
                selectedTags.insert(tag)
            }
        } label: {
            Text("#\(Quote.categoryDisplay(tag, lang: lang))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isSelected
                    ? AnyShapeStyle(AppColors.background)
                    : (disabled
                        ? AnyShapeStyle(AppColors.textTertiary)
                        : AnyShapeStyle(AppColors.textSecondary))
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(
                            isSelected
                            ? AnyShapeStyle(AppColors.accent)
                            : AnyShapeStyle(AppColors.cardBackground)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? Color.clear : AppColors.textTertiary.opacity(0.3),
                            lineWidth: 1
                        )
                )
        }
        .disabled(disabled)
    }

    // MARK: - Submit

    private func submit(backgroundIndex: Int) async {
        let result = await postService.createPost(
            textJp: trimmedJp.isEmpty ? nil : trimmedJp,
            textEn: trimmedEn.isEmpty ? nil : trimmedEn,
            tags: Array(selectedTags),
            backgroundId: backgroundIndex
        )
        if result != nil {
            showBackgroundPicker = false
            dismiss()
        }
    }
}


// MARK: - FlowLayout (タグチップ折返し配置)

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = layout(subviews: subviews, in: width)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for placement in result.placements {
            placement.view.place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Placement {
        let view: LayoutSubview
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
    }

    private struct Result {
        let height: CGFloat
        let placements: [Placement]
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> Result {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placements: [Placement] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(Placement(view: subview, x: x, y: y, size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return Result(height: y + rowHeight, placements: placements)
    }
}

#Preview {
    PostComposerView()
}
