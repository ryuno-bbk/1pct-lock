//
//  ProfileEditView.swift
//  AppBlocker
//
//  S15 profile edit screen (display name + avatar image).
//  Opened both from the My Page header (NavigationLink) and from the settings screen.
//  Image change, image removal and display name change are all applied together when "保存"
//  ("Save") is tapped.
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

    /// TikTok style: tapping each item's row pushes a dedicated edit page (restructured 2026-07-25)
    @State private var editing: EditField?
    @FocusState private var focusedField: EditField?
    /// Drafts are initialized only on the first onAppear. Popping back from an edit page fires onAppear
    /// again, so without a guard the drafts would reset to the server values on every return and the
    /// edits would be lost (2026-07-25 review fix)
    @State private var draftsLoaded = false
    /// The value at the time the edit page was opened. Top-left "キャンセル" ("Cancel") rolls back to this
    /// (top-right "保存" ("Save") pops while keeping the draft).
    /// Pages edit the parent draft directly (to keep the live availability check for the handle), so a
    /// snapshot is needed to "discard on cancel" (2026-07-25 real device feedback)
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
        // 🔴 The limit matches "the number of characters that fit in 2 lines on the profile screen
        // (ProfileHero)". Measured with iOS real device metrics, 13pt / 2 lines = 56 chars on iPhone SE,
        // 58 chars on iPhone 15.
        // The DB CHECK stays at 160, but if 160 chars are written, 100 of them are never visible on any
        // screen, so the client lowers it to the length that is actually visible (all existing bios are
        // shorter than this limit, so there is no impact)
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

    /// Normalized handle value (lowercasing + symbol cleanup are centralized in HandleValidator)
    private var normalizedHandle: String {
        HandleValidator.normalized(handleDraft)
    }

    private var handleFormatValid: Bool {
        !normalizedHandle.isEmpty && HandleValidator.isValidFormat(normalizedHandle)
    }

    private var handleChanged: Bool {
        normalizedHandle != (auth.handle ?? "")
    }

    /// If unchanged (same as the existing value), no availability check is needed and it counts as OK.
    /// If changed, a valid format + a completed server availability check (.available) are required.
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

    /// Current avatar state to display:
    /// - pendingRemoval → placeholder
    /// - pendingImagePreview → the newly selected preview
    /// - otherwise → the server-side auth.avatarUrl
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

                    // Name / user ID in one card (following TikTok: label on the left, value on the right, chevron,
                    // tapping the row pushes the dedicated edit page)
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

                    // Basic info = bio + dream
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(lang == .japanese ? "基本情報" : "About you") // Wording awaiting user review
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
        // Fix for the 2026-08-04 real device bug "the header lets content show through".
        // The parent (MyProfileView) overlays the hero image on the bar, so it sets
        // .toolbarBackground(.hidden, for: .navigationBar), and a pushed screen inherits that transparent
        // state unless it sets visibility explicitly. As a result, the contents of this page's ScrollView
        // were visible through the nav bar. FeedCardListView already has the same fix
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // 🔴 Text items are now confirmed by "保存" ("Save") on the subpage, so
            //    the parent's "保存" ("Save") is shown **only when the avatar was changed**.
            //    Only the avatar is edited directly on this screen (it has no subpage), so
            //    removing the button completely would leave no way to save it.
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

    // MARK: - Settings Rows (TikTok-style cards)

    /// Container for a rounded card. editRow / rowDivider are placed inside it
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.cardBackground))
    }

    /// Open an edit page. Snapshot the current value for rolling back on cancel, then push
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

    /// Top-left "キャンセル" ("Cancel"): roll back to the value at the time it was opened, then pop
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

    /// Row with the label on the left, the current value on the right and a chevron. Tap pushes the edit
    /// page. If the value is empty, show "未設定" ("Not set") in a light color. If invalid (required but
    /// empty, over the limit, etc.), show a red warning icon
    private func editRow(field: EditField, label: String, value: String, showsWarning: Bool) -> some View {
        Button {
            openEditor(field)
        } label: {
            // 🔴 2026-09-05: the label and the value used to share one line.
            //    Measured with iOS real device metrics, the width left for the value was 220pt = only 14
            //    Japanese chars, so a 43-char bio showed as "14 chars + …".
            //    → Put the label on top and the value in 2 full-width lines. At 15pt, 44 Japanese chars fit.
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

    // MARK: - Per-field Editor Pages (TikTok-style push editing)
    //
    // Each page only edits the draft (@State/@Binding) directly and does not persist anything.
    // Saving is committed all at once by "保存" ("Save") in the parent toolbar, as before
    // (canSave/saveAll unchanged).

    @ViewBuilder
    private func editorPage(for field: EditField) -> some View {
        switch field {
        case .name:   nameEditorPage
        case .handle: handleEditorPage
        case .bio:    bioEditorPage
        case .dream:  dreamEditorPage
        }
    }

    /// Shared frame for edit pages (following TikTok, 2026-07-25 real device feedback):
    /// Top-left "キャンセル" ("Cancel") = roll back and pop / top-right "保存" ("Save") = keep the draft
    /// and pop (the server update is done by Save on the parent screen).
    /// Body order: large title → description (gray) → input field in a gray box. Auto focus after push
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
                    // 🔴 2026-09-09 real device feedback: previously this only brought the draft back, and
                    //    it was not sent to the server unless "保存" ("Save") on the parent screen was pressed again.
                    //    A button that says "保存" ("Save") but does not save is clearly a lie, so
                    //    it now actually commits here before going back.
                    //    Plan Y (user's choice): call the existing bulk save saveAll() as-is.
                    //    Splitting it into per-item saves would mean rebuilding the duplicate handle check and the
                    //    avatar upload failure handling, which is not worth it right before shipping.
                    editing = nil
                    // 🔴 Do not close the edit screen. Closing it would mean reopening it 4 times to fix 4 items
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
            // Focus after the push transition settles (avoid triggering it during the transition)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focusedField = field
            }
        }
    }

    /// TikTok-style gray box input field (no border, fill only)
    private func editorBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.cardBackground))
    }

    /// Clear (×) button at the end of single-line fields (following TikTok)
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
                ? "プロフィールに表示される名前です。" // Wording awaiting user review
                : "This is how your name appears on your profile.", // Wording awaiting user review
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

                        // Following TikTok: a green check inside the box if the handle is available
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
                ? "自己紹介はいつでも編集できます。" // Wording awaiting user review
                : "You can edit your bio anytime.", // Wording awaiting user review
            field: .bio,
            saveEnabled: bioValid
        ) {
            VStack(alignment: .leading, spacing: 8) {
                editorBox {
                    TextField(ProfileEditBioStrings.placeholder(lang), text: $bioDraft, axis: .vertical)
                        // Height close to how it looks on the profile (2 lines).
                        // 56-char limit + no line breaks, so a bigger box would only leave empty space
                        .lineLimit(2...3)
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textPrimary)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .bio)
                        .onChange(of: bioDraft) { _, newValue in
                            // 🔴 2026-09-09 (fixed twice. Keeping the history):
                            //
                            //  1. The first implementation checked `> 160` and then cut at 56, so
                            //     57 to 160 chars went through (my own bug). Check against the limit instead.
                            //
                            //  2. Next, line breaks were collapsed into spaces, but the user decided to drop that.
                            //     The conclusion is "do not allow line breaks at all". The bio only shows 2 lines on the
                            //     profile, so allowing line breaks gains nothing.
                            //     🔴 The return key is treated as "end of input" and **closes the keyboard**.
                            //     This way not a single line break gets in, and the intent of the person who pressed it
                            //     (finishing input) is met.
                            var cleaned = newValue
                            if cleaned.contains(where: \.isNewline) {
                                cleaned = cleaned.filter { !$0.isNewline }
                                focusedField = nil   // = close the keyboard
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
                ? "あなたが達成したい夢をここに宣言してください。他人に見せるかは自分で選べます。" // Wording specified by the user (2026-07-25, "ここに" ("here") is required)
                : "Declare the dream you want to achieve right here. You choose whether others can see it.", // English awaiting user review
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

                // Public toggle (disabled when the dream is empty, since it is meaningless then)
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
            // The format explanation is handled by the edit page description (editorScaffold description), so
            // nothing is shown in idle (duplicate removed in the 2026-07-25 TikTok-style rework)
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
            // Network errors are distinguished from "taken" and show a retry path
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

    /// Debounce handle input by 400ms and check availability.
    /// If the format is invalid or unchanged (same as the existing value), do not query the server.
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
                // If the value changed to something else while waiting, discard the result
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
    /// - Parameter closeOnSuccess: whether to close the whole profile edit screen on success.
    ///   🔴 false when called from "保存" ("Save") on a subpage (display name/ID/bio/dream).
    ///   If left true, every single-item fix closes the whole edit screen, and fixing 4 items means
    ///   reopening the edit screen 4 times (2026-09-09 real device feedback. A regression I introduced).
    private func saveAll(closeOnSuccess: Bool = true) async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        // 1. Avatar: run exactly one of these, checked in order: remove → upload → do nothing
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

        // 2. Display name (if changed)
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

        // 2.5. User ID (@handle) (if changed). Assumes canSave has already confirmed .available.
        if handleChanged {
            let ok = await auth.updateHandle(normalizedHandle)
            if !ok {
                errorMessage = ProfileEditHandleStrings.saveFailed(lang)
                showError = true
                return
            }
        }

        // 2.6. Bio (if changed)
        if bioChanged {
            let ok = await auth.updateBio(trimmedBio)
            if !ok {
                errorMessage = ProfileEditBioStrings.saveFailed(lang)
                showError = true
                return
            }
        }

        // 2.7. Dream (if changed). Save if either the text or the public setting changed
        if dreamChanged {
            let ok = await auth.updateDream(trimmedDream, isPublic: dreamIsPublicDraft)
            if !ok {
                errorMessage = ProfileEditDreamStrings.saveFailed(lang)
                showError = true
                return
            }
            // Mirror to the App Group for the Shield (plan A) subtitle
            AppGroupStorage.shared.saveUserDream(auth.dream)
        }

        // 3. If the avatar or display name changed, reload every feed where your own posts appear.
        //    Covered by policy B (call load again) in feedback_feed_consistency.md.
        if avatarChanged || nameChanged {
            await refreshAffectedFeeds()
        }

        // 4. Clean up once everything succeeded. Whether to close is decided by the caller
        pendingImageData = nil
        pendingImagePreview = nil
        pendingRemoval = false
        if closeOnSuccess { dismiss() }
    }

    /// Reload in parallel the feeds that may show your own avatar/display name.
    /// Targets: recommended / following / your own posts.
    /// (TagFeedView fetches every time, and UserProfileView is for other people's profiles, so both are
    /// excluded)
    private func refreshAffectedFeeds() async {
        async let mixed: () = FeedService.shared.loadRecommended()
        async let following: () = FeedService.shared.loadFollowing()
        async let mine: () = UserPostService.shared.loadMyPosts()
        _ = await (mixed, following, mine)
    }

    // MARK: - Helpers

    /// Downscale the image so its longest side is maxSize, then JPEG-compress.
    /// The avatar is displayed at about 120pt, so 800px is more than enough.
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

// MARK: - Edit Field (identifier for the TikTok-style per-item edit pages)

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
    /// Network error from the server availability check (distinguished from "taken" and shows a retry
    /// path)
    case error
    case invalid
}

// MARK: - Handle Strings (this file only)

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
