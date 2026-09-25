//
//  PostConfirmView.swift
//  AppBlocker
//
//  UGC 投稿 v2 Step3: TikTok式確定画面。
//  上段: サムネ横スクロール ([+] で最大4枚まで追加) / タイトル入力 (# タグ予測付き) /
//  「投稿後にロックを開始する」トグル (投稿の瞬間に選ぶ、前回値を記憶) / 投稿ボタン。
//  投稿成功後は同じ画面が「投稿完了」の完了状態にモーフする。トグル ON なら PostLockPromptView が
//  自動で立ち上がる (完了後にボタンを押させる方式は廃止、投稿前の意思表示に一本化)。
//

import SwiftUI

struct PostConfirmView: View {
    @ObservedObject var draft: PostDraft
    /// 確認画面の [+] タップ時に呼ばれる (PostFlowView が .addBackground を push する)
    let onAddImage: () -> Void
    /// サムネタップ時に呼ばれる (その画像をエディタで再編集)
    let onEditImage: (Int) -> Void
    /// [閉じる] / ロック開始成功時に呼ばれる。フロー全体 (PostFlowView) を dismiss する。
    let onCloseFlow: () -> Void

    @ObservedObject private var postService = UserPostService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var isSubmitting = false
    @State private var didSucceed = false
    @State private var showLockPrompt = false
    /// 投稿失敗時のアラート文言 (046 レート制限/汎用。nil = 非表示)
    @State private var submitError: String?
    /// 残り投稿枠 (057 上限5件化の可視化。nil = 未取得/取得失敗で非表示)
    @State private var remainingSlots: Int?
    // 投稿完了アニメーション (2026-07-25 実機FB: 描かれるチェックマーク → 自動フェードで閉じる)
    @State private var completeCircleProgress: CGFloat = 0
    @State private var completeCheckProgress: CGFloat = 0
    @State private var completedOpacity: Double = 1
    @FocusState private var isTitleFieldFocused: Bool
    /// 投稿後にロックを開始するか。投稿の瞬間に選ぶトグル (前回値を記憶、デフォルトはOFF)
    @AppStorage("startLockAfterPost") private var startLockAfterPost = false

    /// PostComposerView.availableTags と同じ 16 語彙 (複製可、既存コード側は編集禁止のため)
    private let availableTags: [String] = [
        "mindset", "action", "discipline", "work-ethic",
        "growth", "hardship", "self-belief", "consistency",
        "failure", "focus", "fear", "sports",
        "philosophy", "success", "motivation", "life"
    ]

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var canSubmit: Bool {
        !draft.images.isEmpty
            && draft.images.allSatisfy { $0.bakedImageData != nil }
            && !isSubmitting
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if didSucceed {
                completedView
            } else {
                composeView
            }
        }
        .navigationBarBackButtonHidden(didSucceed)
        .onAppear {
            // [+] → 背景グリッド → エディタ と進んだ後に「戻る」連打でここへ帰ってきた場合、
            // 未焼き込みの DraftImage が残り canSubmit が永久に false になる。掃除して防ぐ。
            draft.images.removeAll { $0.bakedImageData == nil }
            if draft.editingIndex >= draft.images.count {
                draft.editingIndex = max(0, draft.images.count - 1)
            }
        }
        // 削除/エラー系モーダルは中央 .alert 統一 (2026-07-22 設計ルール)
        .alert(
            lang == .japanese ? "投稿できません" : "Can't post",  // 文言はユーザー添削待ち
            isPresented: Binding(
                get: { submitError != nil },
                set: { if !$0 { submitError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { submitError = nil }
        } message: {
            Text(submitError ?? "")
        }
        .sheet(isPresented: $showLockPrompt) {
            PostLockPromptView {
                // 実機FB第10弾 (2026-07-16): 内側シートとフロー全体 (外側シート) を同一 tick で
                // 同時に dismiss すると入れ子シートの遷移がスタックし操作不能 (フリーズ) になる。
                // 内側を先に閉じ、dismiss アニメーション完了を待ってから外側を閉じる
                showLockPrompt = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    onCloseFlow()
                }
            }
        }
    }

    // MARK: - Compose (投稿前、TikTok式レイアウト)

    private var composeView: some View {
        VStack(spacing: 0) {
            thumbnailRow
                .padding(.top, 20)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 12) {
                PostTitleField(
                    text: $draft.title,
                    placeholder: PostFlowStrings.titlePlaceholder(lang),
                    isFocused: $isTitleFieldFocused
                )

                hashButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if !candidateTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(candidateTags, id: \.self) { tag in
                            Button {
                                insertTag(tag)
                            } label: {
                                Text("#\(Quote.categoryDisplay(tag, lang: lang))")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(AppColors.cardBackground))
                                    .overlay(
                                        Capsule().stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 8)
            }

            Spacer()

            // フッター (ロックカード + 全幅CTA)。実機FB第8弾で再設計 (2026-07-15)
            VStack(spacing: 12) {
                // ロック開始トグルをカード行に (アプリ標準のカード様式に合わせる)
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary)
                    Text(PostFlowStrings.lockToggleLabel(lang))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    Toggle("", isOn: $startLockAfterPost)
                        .labelsHidden()
                        .tint(AppColors.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))

                // 投稿ボタンは全幅CTA (右下の小ボタンをやめる)。
                // PrimaryButton のラベルは内部で .frame(maxWidth: .infinity) 済みのため、
                // VStack 直下に置くだけで幅いっぱいに広がる (外側からの maxWidth 指定は不要)。
                // 高さは size: .large (56pt) を採用: 内部ラベルが size.height を自前で固定しており
                // 外側から .frame(height:) を当てても背景の見た目には反映されず tap 領域が広がる
                // だけになるため、要件の "~52pt" に一番近い既存サイズをそのまま使う
                PrimaryButton(
                    PostFlowStrings.submitCTA(lang),
                    size: .large,
                    isLoading: isSubmitting,
                    isDisabled: !canSubmit
                ) {
                    Task { await submit() }
                }

                // 057: 上限5件化に伴い残り枠を可視化 (「5にするならユーザーに分かるように」)。
                // 取得失敗時は何も出さない (投稿は妨げない)
                if let remainingSlots {
                    Text(lang == .japanese
                         ? "今日はあと\(remainingSlots)件投稿できます"
                         : "\(remainingSlots) posts left today")  // 文言はユーザー添削待ち
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .contentShape(Rectangle())
            .onTapGesture { isTitleFieldFocused = false }   // 2-b: フッター空白タップで閉じる
            .task { remainingSlots = await postService.remainingDailyPostSlots() }
        }
    }

    // MARK: - サムネ行 (横スクロール + [+] タイル)

    private var thumbnailRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(draft.images.enumerated()), id: \.element.id) { index, image in
                    thumbnailTile(image: image, index: index)
                }

                if draft.images.count < 4 {
                    addTile
                }
            }
            .padding(.horizontal, 20)
        }
        // 2-a: サムネ行の空白タップでタイトル入力のキーボードを閉じる
        // (サムネ/[+] タイルの Button は子が優先されるので既存タップは壊れない。
        // 実機FB第8弾: 全面外タップ→写真エリア/フッターのみに限定 (2026-07-15))
        .contentShape(Rectangle())
        .onTapGesture { isTitleFieldFocused = false }
    }

    private func thumbnailTile(image: DraftImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            // サムネタップ → その画像をエディタで再編集
            Button {
                onEditImage(index)
            } label: {
                Group {
                    if let preview = image.bakedPreviewImage {
                        Image(uiImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AppColors.cardBackground
                    }
                }
                .frame(width: 84, height: 149)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())

            // 2枚目以降が存在する時のみ削除✕を出す (最後の1枚は消せない)
            if draft.images.count > 1 {
                Button {
                    removeImage(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .padding(4)
            }
        }
    }

    private var addTile: some View {
        Button(action: onAddImage) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
                .background(AppColors.cardBackground.opacity(0.4).clipShape(RoundedRectangle(cornerRadius: 8)))
                .frame(width: 84, height: 149)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)
                )
        }
    }

    private func removeImage(at index: Int) {
        guard draft.images.indices.contains(index), draft.images.count > 1 else { return }
        draft.images.remove(at: index)
        if draft.editingIndex >= draft.images.count {
            draft.editingIndex = max(0, draft.images.count - 1)
        }
    }

    // MARK: - # チップボタン (タイトル末尾に # を挿入してフォーカス)

    private var hashButton: some View {
        Button {
            draft.title.append("#")
            isTitleFieldFocused = true
        } label: {
            Text("#")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppColors.cardBackground))
        }
    }

    // MARK: - Completed (投稿後)

    // 2026-07-25 実機FB: 静的な checkmark.circle.fill + 閉じるボタンを廃止。
    // 円→チェックが描かれるアニメーション後、画面ごとフェードして自動で閉じる。
    // 例外: 投稿後ロック ON の時は PostLockPromptView (入れ子シート) が閉じ役なので
    // 自動クローズしない (入れ子シートの同時 dismiss はフリーズ実績あり、実機FB第10弾)
    private var completedView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .trim(from: 0, to: completeCircleProgress)
                    .stroke(AppColors.textPrimary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 88, height: 88)
                DrawnCheckmark()
                    .trim(from: 0, to: completeCheckProgress)
                    .stroke(AppColors.textPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 88, height: 88)
            }

            Text(PostFlowStrings.postedTitle(lang))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .opacity(completeCheckProgress)

            Spacer()

            if startLockAfterPost {
                // ロックプロンプト経由で閉じるのが本線だが、プロンプトをスワイプで
                // 閉じた場合の詰み防止に手動の閉じるだけ残す
                Button {
                    onCloseFlow()
                } label: {
                    Text(PostFlowStrings.closeCTA(lang))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .opacity(completedOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { completeCircleProgress = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.25)) { completeCheckProgress = 1 }
            guard !startLockAfterPost else { return }
            Task { @MainActor in
                // 描き切り (~0.6s) + 余韻 0.5s → 0.6s かけてフェード → 閉じる
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.easeIn(duration: 0.6)) { completedOpacity = 0 }
                try? await Task.sleep(nanoseconds: 620_000_000)
                onCloseFlow()
            }
        }
    }

    // MARK: - # タグ予測

    /// タイトル末尾の "#query" フラグメント (最後の # 以降に空白が無い場合のみ)
    private var activeHashQuery: String? {
        guard let hashIndex = draft.title.lastIndex(of: "#") else { return nil }
        let after = draft.title[draft.title.index(after: hashIndex)...]
        if after.contains(where: { $0.isWhitespace }) { return nil }
        return String(after)
    }

    private var candidateTags: [String] {
        guard let query = activeHashQuery, extractTagKeys(from: draft.title).count < 3 else { return [] }
        if query.isEmpty { return availableTags }
        let lowerQuery = query.lowercased()
        return availableTags.filter { tag in
            let display = Quote.categoryDisplay(tag, lang: lang).lowercased()
            return display.hasPrefix(lowerQuery) || tag.lowercased().hasPrefix(lowerQuery)
        }
    }

    private func insertTag(_ tag: String) {
        guard let hashIndex = draft.title.lastIndex(of: "#") else { return }
        let display = Quote.categoryDisplay(tag, lang: lang)
        draft.title.replaceSubrange(hashIndex..., with: "#\(display) ")
    }

    /// タイトル文字列から #トークンを 16 語彙 (日英どちらの表示名でも) と照合し、
    /// 一致したものを語彙キー (英語) の配列に正規化する (最大3)。
    /// 日本語タイトルは # の前に空白が無いのが普通なので、空白区切りではなく
    /// 「# から次の空白/# まで」を正規表現で直接拾う。
    private func extractTagKeys(from title: String) -> [String] {
        let tokens = title
            .matches(of: /#([^#\s]+)/)
            .map { String($0.1) }

        var keys: [String] = []
        for token in tokens {
            guard !token.isEmpty else { continue }
            for tag in availableTags {
                let ja = Quote.categoryDisplay(tag, lang: .japanese)
                let en = Quote.categoryDisplay(tag, lang: .english)
                if token == ja || token == en || token.caseInsensitiveCompare(tag) == .orderedSame {
                    if !keys.contains(tag) { keys.append(tag) }
                    break
                }
            }
            if keys.count >= 3 { break }
        }
        return Array(keys.prefix(3))
    }

    // MARK: - Submit

    private func submit() async {
        let jpegs = draft.images.compactMap { $0.bakedImageData }
        guard !jpegs.isEmpty, jpegs.count == draft.images.count else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        let tags = extractTagKeys(from: draft.title)
        // 抽出した tags を使って title 側の #タグ表示分/中身が空の単独 # を掃除する
        // (extractTagKeys が先: 掃除後の title には対象の #タグがもう残っておらず、
        // 順序を逆にすると tags が空になってしまう)
        let cleanedTitle = (Quote.displayTitle(from: draft.title, tags: tags) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = await postService.createPostV2(
            id: UUID(),
            title: cleanedTitle.isEmpty ? nil : cleanedTitle,
            tags: tags,
            images: jpegs,
            overlays: draft.flattenedOverlayDTOs
        )

        if result != nil {
            withAnimation(.easeOut(duration: 0.3)) {
                didSucceed = true
            }
            if startLockAfterPost {
                showLockPrompt = true
            }
            // 投稿が出た = いいね/コメントが届く理由ができた瞬間。
            // ここが2つ目の許可を聞く場所 (既に決定済みなら何も起きない)
            await PushNotificationService.shared.requestAuthorizationIfNeeded()
        } else {
            // 失敗を無言で握りつぶさない (046 レート制限は専用文言、それ以外は汎用)
            if postService.lastCreateFailure == .rateLimited {
                // 057: 上限5件化に伴い数字を明示 (UserPostService.dailyPostLimit = サーバーと同期)
                submitError = lang == .japanese
                    ? "1日の投稿は\(UserPostService.dailyPostLimit)件までです。24時間経つと枠が戻ります"
                    : "You can post up to \(UserPostService.dailyPostLimit) times a day. Slots free up after 24 hours"  // 文言はユーザー添削待ち
            } else {
                submitError = lang == .japanese
                    ? "投稿できませんでした。時間をおいて再試行してください"
                    : "Couldn't post. Please try again later"  // 文言はユーザー添削待ち
            }
        }
    }
}

// MARK: - DrawnCheckmark (投稿完了の「描かれる」チェック)

/// trim(from:to:) で左→右へストロークが走るチェックマーク。88pt 枠基準の相対座標
private struct DrawnCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.28, y: rect.height * 0.53))
        p.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.69))
        p.addLine(to: CGPoint(x: rect.width * 0.73, y: rect.height * 0.35))
        return p
    }
}

// MARK: - PostTitleField (独立子View、パフォーマンス局所化)

private struct PostTitleField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            // 実機FB第8弾: 3行分は狭くタップがシビアだったため常時5行分の高さを確保 (2026-07-15)
            // (7行は下のロックカード/フッターと被った、実機FB第9弾)
            .lineLimit(5, reservesSpace: true)
            .font(.system(size: 17))
            .foregroundColor(AppColors.textPrimary)
            .focused(isFocused)
            .onChange(of: text) { _, newValue in
                if newValue.count > 60 {
                    text = String(newValue.prefix(60))
                }
            }
    }
}
