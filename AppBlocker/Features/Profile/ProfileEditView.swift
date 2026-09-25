//
//  ProfileEditView.swift
//  AppBlocker
//
//  S15 プロフィール編集画面 (表示名 + アバター画像)。
//  マイページのヘッダー (NavigationLink) と設定画面の両方から開かれる。
//  画像変更・削除・表示名変更すべて「保存」タップ時に一括反映する。
//

import SwiftUI
import PhotosUI

struct ProfileEditView: View {
    @ObservedObject private var auth = UserAuthService.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var nameDraft: String = ""
    @State private var bioDraft: String = ""
    @State private var dreamDraft: String = ""
    @State private var dreamIsPublicDraft: Bool = false
    @State private var handleDraft: String = ""
    @State private var handleCheckState: HandleCheckState = .idle
    @State private var handleCheckTask: Task<Void, Never>?
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var pendingImagePreview: UIImage?
    @State private var pendingRemoval: Bool = false
    @State private var isPreparingImage: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var showRemoveConfirm: Bool = false

    /// TikTok 式: 各項目は行タップで専用編集ページへ push する (2026-07-25 再構成)
    @State private var editing: EditField?
    @FocusState private var focusedField: EditField?
    /// ドラフト初期化は初回 onAppear のみ。編集ページから pop で戻ると onAppear が再発火するため、
    /// 無ガードだと戻るたびにドラフトがサーバー値へリセットされ編集内容が消える (2026-07-25 レビュー修正)
    @State private var draftsLoaded = false
    /// 編集ページを開いた時点の値。左上「キャンセル」でここへ巻き戻す (右上「保存」はドラフト維持のままpop)。
    /// ページは親ドラフトを直接編集する設計 (ハンドルのライブ可用性チェックを生かすため) なので、
    /// 「キャンセルで捨てる」ためにはスナップショットが必要 (2026-07-25 実機FB)
    @State private var editSnapshotText = ""
    @State private var editSnapshotDreamPublic = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameChanged: Bool {
        trimmedName != (auth.displayName ?? "")
    }

    private var trimmedBio: String {
        bioDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bioChanged: Bool {
        trimmedBio != (auth.bio ?? "")
    }

    private var bioValid: Bool {
        // 🔴 上限は「プロフィール画面 (ProfileHero) の2行に収まる文字数」に合わせる。
        // iOS 実機メトリクスで 13pt / 2行 = iPhone SE 56字 / iPhone 15 58字。
        // DB の CHECK は 160 のままだが、160字書いても100字は全画面で永久に見えないので
        // クライアント側で実際に見える長さまで下げる (既存の自己紹介はどれもこの上限より短いので影響なし)
        trimmedBio.count <= 56
    }

    private var trimmedDream: String {
        dreamDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dreamChanged: Bool {
        trimmedDream != (auth.dream ?? "") || dreamIsPublicDraft != auth.dreamIsPublic
    }

    private var dreamValid: Bool {
        trimmedDream.count <= 120
    }

    private var avatarChanged: Bool {
        pendingImageData != nil || pendingRemoval
    }

    /// ハンドルの正規化済み値 (小文字化 + 記号整理は HandleValidator に集約)
    private var normalizedHandle: String {
        HandleValidator.normalized(handleDraft)
    }

    private var handleFormatValid: Bool {
        !normalizedHandle.isEmpty && HandleValidator.isValidFormat(normalizedHandle)
    }

    private var handleChanged: Bool {
        normalizedHandle != (auth.handle ?? "")
    }

    /// 変更なし (既存のまま) なら可用性チェック不要で OK 扱い。
    /// 変更ありならフォーマット妥当 + サーバー可用性チェック済み (.available) が必須。
    private var handleOK: Bool {
        if !handleChanged { return true }
        return handleFormatValid && handleCheckState == .available
    }

    private var hasChanges: Bool {
        nameChanged || avatarChanged || handleChanged || bioChanged || dreamChanged
    }

    private var nameValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 30
    }

    private var canSave: Bool {
        hasChanges && nameValid && bioValid && dreamValid && handleOK && !isSaving && !isPreparingImage
    }

    /// 表示する現在のアバター状態:
    /// - pendingRemoval → placeholder
    /// - pendingImagePreview → 新しく選んだプレビュー
    /// - それ以外 → サーバー側の auth.avatarUrl
    private var showsRemovedPlaceholder: Bool {
        pendingRemoval && pendingImagePreview == nil
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    avatarSection
                        .padding(.top, 16)

                    // 名前 / ユーザーID を1枚のカードに (TikTok準拠: ラベル左・値右・chevron、
                    // 行タップで専用の編集ページへ push する)
                    settingsCard {
                        editRow(
                            field: .name,
                            label: L.profileEditDisplayNameLabel(lang),
                            value: trimmedName,
                            showsWarning: !nameValid
                        )
                        rowDivider
                        editRow(
                            field: .handle,
                            label: ProfileEditHandleStrings.label(lang),
                            value: normalizedHandle.isEmpty ? "" : "@\(normalizedHandle)",
                            showsWarning: !handleOK
                        )
                    }

                    // 基本情報 = 自己紹介 + 夢
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(lang == .japanese ? "基本情報" : "About you") // 文言はユーザー添削待ち
                        settingsCard {
                            editRow(
                                field: .bio,
                                label: ProfileEditBioStrings.label(lang),
                                value: trimmedBio,
                                showsWarning: !bioValid
                            )
                            rowDivider
                            editRow(
                                field: .dream,
                                label: ProfileEditDreamStrings.label(lang),
                                value: trimmedDream,
                                showsWarning: !dreamValid
                            )
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationTitle(L.profileEditTitle(lang))
        .navigationBarTitleDisplayMode(.inline)
        // 2026-08-04 実機バグ「ヘッダーが貫通する」の修正。
        // 親 (MyProfileView) はヒーロー画像をバーに重ねるため
        // .toolbarBackground(.hidden, for: .navigationBar) を指定しており、push 先が
        // 可視性を明示しないとその透過状態を引きずる。結果このページの ScrollView の中身が
        // ナビバーを素通りして見えていた。FeedCardListView が既に同じ対策を入れている
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // 🔴 テキスト項目はサブページの「保存」で確定するようになったので、
            //    親の「保存」は**アバターを変えた時だけ**出す。
            //    アバターだけはこの画面で直接いじる (サブページが無い) ため、
            //    ボタンを完全に消すと保存する手段が無くなる。
            ToolbarItem(placement: .navigationBarTrailing) {
                if avatarChanged {
                Button {
                    Task { await saveAll() }
                } label: {
                    if isSaving {
                        ProgressView().tint(AppColors.accent)
                    } else {
                        Text(L.profileEditSave(lang))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                canSave ? AnyShapeStyle(AppColors.accent) : AnyShapeStyle(AppColors.textTertiary)
                            )
                    }
                }
                .disabled(!canSave)
                }
            }
        }
        .navigationDestination(item: $editing) { field in
            editorPage(for: field)
        }
        .onAppear {
            guard !draftsLoaded else { return }
            draftsLoaded = true
            nameDraft = auth.displayName ?? ""
            handleDraft = auth.handle ?? ""
            bioDraft = auth.bio ?? ""
            dreamDraft = auth.dream ?? ""
            dreamIsPublicDraft = auth.dreamIsPublic
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await prepareSelectedImage(item: newItem) }
        }
        .onChange(of: handleDraft) { _, _ in
            scheduleHandleCheck()
        }
        .alert(L.profileEditSaveFailed(lang), isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L.profileEditAvatarRemove(lang), isPresented: $showRemoveConfirm) {
            Button(L.profileEditCancel(lang), role: .cancel) { }
            Button(L.profileEditAvatarRemove(lang), role: .destructive) {
                pendingImageData = nil
                pendingImagePreview = nil
                pendingRemoval = true
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                avatarPreview

                if isPreparingImage {
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 120, height: 120)
                        .overlay(ProgressView().tint(.white))
                }

                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppColors.background)
                        .padding(10)
                        .background(Circle().fill(AppColors.accent))
                        .overlay(Circle().stroke(AppColors.background, lineWidth: 3))
                }
                .disabled(isPreparingImage || isSaving)
            }

            HStack(spacing: 16) {
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Text(L.profileEditAvatarChange(lang))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.accent)
                }
                .disabled(isPreparingImage || isSaving)

                if hasExistingOrPendingAvatar {
                    Button {
                        showRemoveConfirm = true
                    } label: {
                        Text(L.profileEditAvatarRemove(lang))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.error)
                    }
                    .disabled(isPreparingImage || isSaving)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let preview = pendingImagePreview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(Circle())
        } else if showsRemovedPlaceholder {
            AvatarImage(urlString: nil, size: 120)
        } else {
            AvatarImage(urlString: auth.avatarUrl?.absoluteString, size: 120)
        }
    }

    private var hasExistingOrPendingAvatar: Bool {
        if pendingImagePreview != nil { return true }
        if pendingRemoval { return false }
        return auth.avatarUrl != nil
    }

    // MARK: - Settings Rows (TikTok 式カード)

    /// 角丸カードのコンテナ。中に editRow / rowDivider を並べる
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.cardBackground))
    }

    /// 編集ページを開く。キャンセル巻き戻し用に現在値をスナップショットしてから push
    private func openEditor(_ field: EditField) {
        switch field {
        case .name:   editSnapshotText = nameDraft
        case .handle: editSnapshotText = handleDraft
        case .bio:    editSnapshotText = bioDraft
        case .dream:
            editSnapshotText = dreamDraft
            editSnapshotDreamPublic = dreamIsPublicDraft
        }
        editing = field
    }

    /// 左上「キャンセル」: 開いた時点の値へ巻き戻して pop
    private func cancelEdit(_ field: EditField) {
        switch field {
        case .name:   nameDraft = editSnapshotText
        case .handle: handleDraft = editSnapshotText
        case .bio:    bioDraft = editSnapshotText
        case .dream:
            dreamDraft = editSnapshotText
            dreamIsPublicDraft = editSnapshotDreamPublic
        }
        editing = nil
    }

    /// ラベル左・現在値右・chevron の行。タップで編集ページへ push。
    /// 値が空なら「未設定」を薄色で表示、不正 (必須未入力/上限超過など) なら赤い注意アイコン
    private func editRow(field: EditField, label: String, value: String, showsWarning: Bool) -> some View {
        Button {
            openEditor(field)
        } label: {
            // 🔴 2026-09-05: 以前はラベルと値が1行を分け合っていた。
            //    iOS 実機メトリクスで測ると値に残る幅は 220pt = 日本語 14字しか出ず、
            //    43字の自己紹介が「14字 + …」になっていた。
            //    → ラベルを上、値を全幅2行に変える。15pt なら日本語44字入る。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textPrimary)

                    if showsWarning {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.error)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                }

                Text(value.isEmpty ? (lang == .japanese ? "未設定" : "Not set") : value)
                    .font(.system(size: 15))
                    .foregroundColor(value.isEmpty ? AppColors.textTertiary : AppColors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppColors.textTertiary.opacity(0.12))
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppColors.textSecondary)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Per-field Editor Pages (TikTok 式 push 編集)
    //
    // 各ページはドラフト (@State/@Binding) を直接編集するだけで、永続化はしない。
    // 保存は従来どおり親ツールバーの「保存」で一括コミット (canSave/saveAll は変更なし)。

    @ViewBuilder
    private func editorPage(for field: EditField) -> some View {
        switch field {
        case .name:   nameEditorPage
        case .handle: handleEditorPage
        case .bio:    bioEditorPage
        case .dream:  dreamEditorPage
        }
    }

    /// 編集ページ共通の枠 (TikTok 準拠 2026-07-25 実機FB):
    /// 左上「キャンセル」= 巻き戻し pop / 右上「保存」= ドラフト維持 pop (サーバー反映は親画面の保存)。
    /// 本文は 大タイトル → 説明文 (灰) → 灰色ボックスの入力欄 の順。push 後に自動フォーカス
    private func editorScaffold<Content: View>(
        title: String,
        description: String,
        field: EditField,
        saveEnabled: Bool,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        ZStack(alignment: .top) {
            AppColors.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                content()
                    .padding(.top, 18)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    cancelEdit(field)
                } label: {
                    Text(L.profileEditCancel(lang))
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // 🔴 2026-09-09 実機FB: 以前はここでドラフトを持ち帰るだけで、
                    //    親画面の「保存」をもう一度押さないとサーバーに反映されなかった。
                    //    「保存」と書いてあるのに保存されないのは明確に嘘なので、
                    //    ここで実際にコミットしてから戻す。
                    //    Y案 (ユーザー選択): 既存の一括保存 saveAll() をそのまま呼ぶ。
                    //    項目ごとの個別保存に割るとハンドル重複チェックやアバター
                    //    アップロードの失敗処理を作り直すことになり、出荷直前に見合わない。
                    editing = nil
                    // 🔴 編集画面は閉じない。閉じると4項目直すのに4回開き直すことになる
                    Task { await saveAll(closeOnSuccess: false) }
                } label: {
                    if isSaving {
                        ProgressView().tint(AppColors.accent)
                    } else {
                        Text(L.profileEditSave(lang))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                saveEnabled ? AnyShapeStyle(AppColors.accent) : AnyShapeStyle(AppColors.textTertiary)
                            )
                    }
                }
                .disabled(!saveEnabled || isSaving)
            }
        }
        .onAppear {
            // push トランジションが落ち着いてからフォーカス (遷移中の起動を避ける)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focusedField = field
            }
        }
    }

    /// TikTok 式の灰色ボックス入力欄 (枠線なし・塗りのみ)
    private func editorBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.cardBackground))
    }

    /// 単一行フィールド末尾のクリア (×) ボタン (TikTok 準拠)
    private func clearButton(_ binding: Binding<String>) -> some View {
        Button {
            binding.wrappedValue = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(AppColors.textTertiary)
        }
        .buttonStyle(.plain)
    }

    private var nameEditorPage: some View {
        editorScaffold(
            title: L.profileEditDisplayNameLabel(lang),
            description: lang == .japanese
                ? "プロフィールに表示される名前です。" // 文言はユーザー添削待ち
                : "This is how your name appears on your profile.", // 文言はユーザー添削待ち
            field: .name,
            saveEnabled: nameValid
        ) {
            VStack(alignment: .leading, spacing: 8) {
                editorBox {
                    HStack(spacing: 8) {
                        TextField(L.profileEditDisplayNamePlaceholder(lang), text: $nameDraft)
                            .font(.system(size: 17))
                            .foregroundColor(AppColors.textPrimary)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .name)

                        if !nameDraft.isEmpty {
                            clearButton($nameDraft)
                        }
                    }
                }

                HStack {
                    if trimmedName.count > 30 {
                        Text(L.profileEditNameTooLong(lang))
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.error)
                    }
                    Spacer()
                    Text(L.profileEditNameCharCount(trimmedName.count))
                        .font(.system(size: 12))
                        .foregroundColor(trimmedName.count > 30 ? AppColors.error : AppColors.textTertiary)
                }
            }
        }
    }

    private var handleEditorPage: some View {
        editorScaffold(
            title: ProfileEditHandleStrings.label(lang),
            description: ProfileEditHandleStrings.hint(lang),
            field: .handle,
            saveEnabled: handleOK
        ) {
            VStack(alignment: .leading, spacing: 8) {
                editorBox {
                    HStack(spacing: 8) {
                        Text("@")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)

                        TextField(ProfileEditHandleStrings.placeholder(lang), text: $handleDraft)
                            .font(.system(size: 17))
                            .foregroundColor(AppColors.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .handle)

                        // TikTok 準拠: 使用可ならボックス内に緑チェック
                        if handleChanged && handleCheckState == .available {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(AppColors.success)
                        }

                        if !handleDraft.isEmpty {
                            clearButton($handleDraft)
                        }
                    }
                }

                handleStatusView
            }
        }
    }

    private var bioEditorPage: some View {
        editorScaffold(
            title: ProfileEditBioStrings.label(lang),
            description: lang == .japanese
                ? "自己紹介はいつでも編集できます。" // 文言はユーザー添削待ち
                : "You can edit your bio anytime.", // 文言はユーザー添削待ち
            field: .bio,
            saveEnabled: bioValid
        ) {
            VStack(alignment: .leading, spacing: 8) {
                editorBox {
                    TextField(ProfileEditBioStrings.placeholder(lang), text: $bioDraft, axis: .vertical)
                        // プロフィールでの見え方 (2行) に近い高さにする。
                        // 56字上限 + 改行なしなので、これ以上大きい箱は空白が余るだけ
                        .lineLimit(2...3)
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textPrimary)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .bio)
                        .onChange(of: bioDraft) { _, newValue in
                            // 🔴 2026-09-09 (2回直している。経緯を残す):
                            //
                            //  1. 最初の実装は `> 160` を見て 56 で切っていたので
                            //     57〜160字が素通りしていた (自己バグ)。上限で判定する。
                            //
                            //  2. 次に改行を空白へ潰したが、ユーザー判断で取り下げ。
                            //     結論は「そもそも改行させない」。自己紹介はプロフィールで
                            //     2行しか出ないので、改行は入れられても得がない。
                            //     🔴 改行キーは「入力の終わり」として扱い、**キーボードを閉じる**。
                            //     こうすると改行が1つも入らないまま、押した人の意図
                            //     (入力を終える) が満たされる。
                            var cleaned = newValue
                            if cleaned.contains(where: \.isNewline) {
                                cleaned = cleaned.filter { !$0.isNewline }
                                focusedField = nil   // = キーボードを閉じる
                            }
                            if cleaned.count > 56 {
                                cleaned = String(cleaned.prefix(56))
                            }
                            if cleaned != newValue { bioDraft = cleaned }
                        }
                }

                HStack {
                    Spacer()
                    Text("\(trimmedBio.count)/56")
                        .font(.system(size: 12))
                        .foregroundColor(trimmedBio.count > 56 ? AppColors.error : AppColors.textTertiary)
                }
            }
        }
    }

    private var dreamEditorPage: some View {
        editorScaffold(
            title: ProfileEditDreamStrings.label(lang),
            description: lang == .japanese
                ? "あなたが達成したい夢をここに宣言してください。他人に見せるかは自分で選べます。" // ユーザー指定文言 (2026-07-25「ここに」必須)
                : "Declare the dream you want to achieve right here. You choose whether others can see it.", // 英語はユーザー添削待ち
            field: .dream,
            saveEnabled: dreamValid
        ) {
            VStack(alignment: .leading, spacing: 8) {
                editorBox {
                    TextField(ProfileEditDreamStrings.placeholder(lang), text: $dreamDraft, axis: .vertical)
                        .lineLimit(4...8)
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textPrimary)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .dream)
                        .onChange(of: dreamDraft) { _, newValue in
                            if newValue.count > 120 {
                                dreamDraft = String(newValue.prefix(120))
                            }
                        }
                }

                HStack {
                    Spacer()
                    Text("\(trimmedDream.count)/120")
                        .font(.system(size: 12))
                        .foregroundColor(trimmedDream.count > 120 ? AppColors.error : AppColors.textTertiary)
                }

                // 公開トグル (夢が空のときは無意味なので無効化)
                Toggle(isOn: $dreamIsPublicDraft) {
                    Text(ProfileEditDreamStrings.publicToggle(lang))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                }
                .tint(AppColors.textPrimary)
                .disabled(trimmedDream.isEmpty)
                .opacity(trimmedDream.isEmpty ? 0.4 : 1)
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var handleStatusView: some View {
        switch handleCheckState {
        case .idle:
            // フォーマット説明は編集ページの説明文 (editorScaffold description) が担うため
            // idle では何も出さない (2026-07-25 TikTok化で重複解消)
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text(ProfileEditHandleStrings.checking(lang))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
            }
        case .available:
            Text(ProfileEditHandleStrings.available(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
        case .unavailable:
            Text(ProfileEditHandleStrings.unavailable(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.error)
        case .error:
            // 通信エラーは「使用中」と区別してリトライ導線を出す
            Button {
                scheduleHandleCheck()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(ProfileEditHandleStrings.checkFailed(lang))
                        .font(.system(size: 12))
                }
                .foregroundColor(AppColors.error)
            }
        case .invalid:
            Text(ProfileEditHandleStrings.hint(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.error)
        }
    }

    /// ハンドル入力を 400ms デバウンスして可用性チェック。
    /// フォーマット不正 or 未変更 (既存値と同一) の場合はサーバー問い合わせしない。
    private func scheduleHandleCheck() {
        handleCheckTask?.cancel()

        guard handleChanged else {
            handleCheckState = .idle
            return
        }
        guard !normalizedHandle.isEmpty else {
            handleCheckState = .idle
            return
        }
        guard handleFormatValid else {
            handleCheckState = .invalid
            return
        }

        handleCheckState = .checking
        let candidate = normalizedHandle
        handleCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await auth.checkHandleAvailable(candidate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 待っている間に別の値へ変わっていたら結果を捨てる
                guard candidate == normalizedHandle else { return }
                switch result {
                case .available: handleCheckState = .available
                case .taken:     handleCheckState = .unavailable
                case .error:     handleCheckState = .error
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func prepareSelectedImage(item: PhotosPickerItem) async {
        isPreparingImage = true
        defer {
            isPreparingImage = false
            pickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                print("⚠️ Avatar prepare: loadTransferable returned nil")
                throw AvatarLoadError.dataUnavailable
            }
            print("ℹ️ Avatar prepare: original size = \(data.count) bytes")
            let jpeg = try downscaleToJPEG(data: data, maxSize: 800, quality: 0.85)
            print("ℹ️ Avatar prepare: jpeg size = \(jpeg.count) bytes")
            guard let preview = UIImage(data: jpeg) else {
                throw AvatarLoadError.notImage
            }
            self.pendingImageData = jpeg
            self.pendingImagePreview = preview
            self.pendingRemoval = false
        } catch {
            print("⚠️ Avatar prepare failed: \(error)")
            errorMessage = L.profileEditAvatarUploadFailed(lang)
            showError = true
        }
    }

    @MainActor
    /// - Parameter closeOnSuccess: 成功したらプロフィール編集画面ごと閉じるか。
    ///   🔴 サブページ (表示名/ID/自己紹介/夢) の「保存」から呼ぶときは false。
    ///   true のままだと、1項目直すたびに編集画面ごと閉じてしまい、4項目直すのに
    ///   編集画面を4回開き直すことになる (2026-09-09 実機FB。私が入れた退行)。
    private func saveAll(closeOnSuccess: Bool = true) async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        // 1. アバター: 削除 → アップロード → 何もしない の順で 1 つだけ実行
        do {
            if pendingRemoval {
                try await auth.removeAvatar()
                print("✅ Avatar remove: success")
            } else if let data = pendingImageData {
                _ = try await auth.uploadAvatar(jpegData: data)
                print("✅ Avatar upload: success")
            }
        } catch {
            print("⚠️ Avatar save failed: \(error)")
            errorMessage = pendingRemoval
                ? L.profileEditAvatarRemoveFailed(lang)
                : L.profileEditAvatarUploadFailed(lang)
            showError = true
            return
        }

        // 2. 表示名 (変更があれば)
        if nameChanged {
            do {
                _ = try await auth.setDisplayName(trimmedName)
            } catch let err as ProfileError {
                errorMessage = err.errorDescription
                showError = true
                return
            } catch {
                print("⚠️ Display name save failed: \(error)")
                errorMessage = L.profileEditSaveFailed(lang)
                showError = true
                return
            }
        }

        // 2.5. ユーザーID (@handle) (変更があれば)。canSave で既に .available 確認済みの前提。
        if handleChanged {
            let ok = await auth.updateHandle(normalizedHandle)
            if !ok {
                errorMessage = ProfileEditHandleStrings.saveFailed(lang)
                showError = true
                return
            }
        }

        // 2.6. 自己紹介 (bio) (変更があれば)
        if bioChanged {
            let ok = await auth.updateBio(trimmedBio)
            if !ok {
                errorMessage = ProfileEditBioStrings.saveFailed(lang)
                showError = true
                return
            }
        }

        // 2.7. 夢 (変更があれば)。本文 or 公開設定のどちらかが変わっていれば保存
        if dreamChanged {
            let ok = await auth.updateDream(trimmedDream, isPublic: dreamIsPublicDraft)
            if !ok {
                errorMessage = ProfileEditDreamStrings.saveFailed(lang)
                showError = true
                return
            }
            // Shield (案A) のサブタイトル用に App Group へミラー
            AppGroupStorage.shared.saveUserDream(auth.dream)
        }

        // 3. アバターか表示名が変わったら、自分の投稿が出る全フィードを再読み込み。
        //    feedback_feed_consistency.md の方針 B (load 再呼び出し) でカバー。
        if avatarChanged || nameChanged {
            await refreshAffectedFeeds()
        }

        // 4. すべて成功したら後始末。閉じるかどうかは呼び出し元が決める
        pendingImageData = nil
        pendingImagePreview = nil
        pendingRemoval = false
        if closeOnSuccess { dismiss() }
    }

    /// 自分のアバター/表示名が出る可能性のあるフィードを並列再読み込み。
    /// 対象: おすすめ / フォロー中 / 自分の投稿。
    /// (TagFeedView は都度取得、UserProfileView は他人プロフィール用なので除外)
    private func refreshAffectedFeeds() async {
        async let mixed: () = FeedService.shared.loadRecommended()
        async let following: () = FeedService.shared.loadFollowing()
        async let mine: () = UserPostService.shared.loadMyPosts()
        _ = await (mixed, following, mine)
    }

    // MARK: - Helpers

    /// 画像を最大辺 maxSize にダウンスケールして JPEG 圧縮。
    /// アバターは表示で 120pt 程度なので 800px もあれば十分。
    private func downscaleToJPEG(data: Data, maxSize: CGFloat, quality: CGFloat) throws -> Data {
        guard let original = UIImage(data: data) else {
            throw AvatarLoadError.notImage
        }
        let ratio = max(original.size.width, original.size.height) / maxSize
        let target: UIImage
        if ratio > 1 {
            let newSize = CGSize(
                width: original.size.width / ratio,
                height: original.size.height / ratio
            )
            let renderer = UIGraphicsImageRenderer(size: newSize)
            target = renderer.image { _ in
                original.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            target = original
        }
        guard let jpeg = target.jpegData(compressionQuality: quality) else {
            throw AvatarLoadError.jpegEncodingFailed
        }
        return jpeg
    }

}

// MARK: - Edit Field (TikTok 式の項目別編集ページの識別子)

private enum EditField: String, Identifiable, Hashable {
    case name, handle, bio, dream
    var id: String { rawValue }
}

// MARK: - Handle Check State

private enum HandleCheckState: Equatable {
    case idle
    case checking
    case available
    case unavailable
    /// サーバー可用性チェックの通信エラー (使用中とは区別してリトライ導線を出す)
    case error
    case invalid
}

// MARK: - Handle Strings (このファイル限定)

private enum ProfileEditHandleStrings {
    static func label(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ユーザーID" : "Username"
    }

    static func placeholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "username" : "username"
    }

    static func hint(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "3〜20字の英小文字・数字・._"
            : "3-20 characters: lowercase letters, numbers, . _"
    }

    static func checking(_ lang: AppLanguage) -> String {
        lang == .japanese ? "確認中…" : "Checking…"
    }

    static func available(_ lang: AppLanguage) -> String {
        lang == .japanese ? "使用できます" : "Available"
    }

    static func unavailable(_ lang: AppLanguage) -> String {
        lang == .japanese ? "使用できません" : "Not available"
    }

    static func checkFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "確認できませんでした。タップで再試行" : "Couldn't check. Tap to retry"
    }

    static func saveFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ユーザーIDの保存に失敗しました" : "Failed to save username"
    }
}

private enum ProfileEditBioStrings {
    static func label(_ lang: AppLanguage) -> String {
        lang == .japanese ? "自己紹介" : "Bio"
    }

    static func placeholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "自己紹介を書く（任意）" : "Write a short bio (optional)"
    }

    static func saveFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "自己紹介の保存に失敗しました" : "Failed to save bio"
    }
}

private enum ProfileEditDreamStrings {
    static func label(_ lang: AppLanguage) -> String {
        lang == .japanese ? "夢" : "Dream"
    }

    static func placeholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "なりたい自分を一行で（任意）" : "Who you want to become (optional)"
    }

    static func publicToggle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "プロフィールに公開する" : "Show on my profile"
    }

    static func saveFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "夢の保存に失敗しました" : "Failed to save dream"
    }
}

// MARK: - Errors

private enum AvatarLoadError: LocalizedError {
    case dataUnavailable
    case notImage
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .dataUnavailable:    return "選択した画像のデータを読み込めませんでした"
        case .notImage:           return "選択したファイルは画像ではありません"
        case .jpegEncodingFailed: return "JPEG への変換に失敗しました"
        }
    }
}

#Preview {
    NavigationStack {
        ProfileEditView()
    }
}
