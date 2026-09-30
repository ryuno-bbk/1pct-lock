//
//  PostConfirmView.swift
//  AppBlocker
//
//  UGC post v2 Step3: TikTok-style confirm screen.
//  Top: horizontal thumbnail scroll (add up to 4 with [+]) / title input (with # tag suggestions) /
//  "投稿後にロックを開始する" ("Start a lock after posting") toggle (chosen at the moment of posting,
//  remembers the last value) / post button.
//  After a successful post, the same screen morphs into the "投稿完了" ("Posted") done state. If the
//  toggle is ON, PostLockPromptView opens automatically (the old approach of making the user press a
//  button after completion was removed, it is now only the intent stated before posting).
//

import SwiftUI

struct PostConfirmView: View {
    @ObservedObject var draft: PostDraft
    /// Called when [+] is tapped on the confirm screen (PostFlowView pushes .addBackground)
    let onAddImage: () -> Void
    /// Called when a thumbnail is tapped (re-edit that image in the editor)
    let onEditImage: (Int) -> Void
    /// Called on [Close] / when a lock starts successfully. Dismisses the whole flow (PostFlowView).
    let onCloseFlow: () -> Void

    @ObservedObject private var postService = UserPostService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var isSubmitting = false
    @State private var didSucceed = false
    @State private var showLockPrompt = false
    /// Alert text when posting fails (046 rate limit / generic. nil = hidden)
    @State private var submitError: String?
    /// Remaining post slots (shows the 057 limit of 5 posts. nil = not fetched / fetch failed, hidden)
    @State private var remainingSlots: Int?
    // Post-complete animation (2026-07-25 real-device feedback: a checkmark that draws itself → closes
    // with an automatic fade)
    @State private var completeCircleProgress: CGFloat = 0
    @State private var completeCheckProgress: CGFloat = 0
    @State private var completedOpacity: Double = 1
    @FocusState private var isTitleFieldFocused: Bool
    /// Whether to start a lock after posting. A toggle chosen at the moment of posting (remembers the last
    /// value, default is OFF)
    @AppStorage("startLockAfterPost") private var startLockAfterPost = false

    /// The same 16-word vocabulary as PostComposerView.availableTags (duplicated on purpose, because the
    /// existing code must not be edited)
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
            // If the user comes back here by tapping "back" repeatedly after going [+] → background grid → editor,
            // an unbaked DraftImage remains and canSubmit is false forever. Clean it up to prevent that.
            draft.images.removeAll { $0.bakedImageData == nil }
            if draft.editingIndex >= draft.images.count {
                draft.editingIndex = max(0, draft.images.count - 1)
            }
        }
        // Delete/error modals are all a centered .alert (2026-07-22 design rule)
        .alert(
            lang == .japanese ? "投稿できません" : "Can't post",  // Copy waiting for user review
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
                // Real-device feedback round 10 (2026-07-16): dismissing the inner sheet and the whole flow (outer
                // sheet) in the same tick jams the nested sheet transition and the app becomes unusable (freeze).
                // Close the inner one first, wait for the dismiss animation to finish, then close the outer one
                showLockPrompt = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    onCloseFlow()
                }
            }
        }
    }

    // MARK: - Compose (before posting, TikTok-style layout)

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

            // Footer (lock card + full-width CTA). Redesigned after real-device feedback round 8 (2026-07-15)
            VStack(spacing: 12) {
                // The lock start toggle is in a card row (matches the app's standard card style)
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

                // The post button is a full-width CTA (no more small button at the bottom right).
                // The PrimaryButton label already has .frame(maxWidth: .infinity) inside, so just placing it
                // directly in the VStack stretches it to full width (no outer maxWidth needed).
                // Height uses size: .large (56pt): the inner label fixes size.height by itself, and applying
                // .frame(height:) from outside does not change how the background looks and only enlarges the tap
                // area, so the existing size closest to the required "~52pt" is used as is
                PrimaryButton(
                    PostFlowStrings.submitCTA(lang),
                    size: .large,
                    isLoading: isSubmitting,
                    isDisabled: !canSubmit
                ) {
                    Task { await submit() }
                }

                // 057: the remaining slots are shown because of the limit of 5 ("if it's 5, make it clear to users").
                // If the fetch fails, nothing is shown (posting is not blocked)
                if let remainingSlots {
                    Text(lang == .japanese
                         ? "今日はあと\(remainingSlots)件投稿できます"
                         : "\(remainingSlots) posts left today")  // Copy waiting for user review
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .contentShape(Rectangle())
            .onTapGesture { isTitleFieldFocused = false }   // 2-b: tapping empty space in the footer closes it
            .task { remainingSlots = await postService.remainingDailyPostSlots() }
        }
    }

    // MARK: - Thumbnail row (horizontal scroll + [+] tile)

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
        // 2-a: tapping empty space in the thumbnail row closes the title input keyboard
        // (the Buttons of the thumbnails/[+] tile are children and take priority, so existing taps are not
        // broken. Real-device feedback round 8: limited from any outside tap to only the photo area/footer
        // (2026-07-15))
        .contentShape(Rectangle())
        .onTapGesture { isTitleFieldFocused = false }
    }

    private func thumbnailTile(image: DraftImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            // Tap a thumbnail → re-edit that image in the editor
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

            // Show the delete ✕ only when there are 2 or more images (the last one cannot be deleted)
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

    // MARK: - # chip button (inserts # at the end of the title and focuses it)

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

    // MARK: - Completed (after posting)

    // 2026-07-25 real-device feedback: removed the static checkmark.circle.fill + close button.
    // After an animation that draws a circle → check, the whole screen fades and closes automatically.
    // Exception: when lock-after-post is ON, PostLockPromptView (nested sheet) is responsible for closing,
    // so it does not auto-close (dismissing nested sheets at the same time has caused freezes before,
    // real-device feedback round 10)
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
                // Closing through the lock prompt is the main path, but a manual close is kept to avoid getting stuck
                // if the prompt was closed with a swipe
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
                // Finish drawing (~0.6s) + 0.5s pause → fade over 0.6s → close
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.easeIn(duration: 0.6)) { completedOpacity = 0 }
                try? await Task.sleep(nanoseconds: 620_000_000)
                onCloseFlow()
            }
        }
    }

    // MARK: - # tag suggestions

    /// The "#query" fragment at the end of the title (only if there is no whitespace after the last #)
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

    /// Matches #tokens in the title string against the 16-word vocabulary (by either the Japanese or English
    /// display name) and normalizes the matches into an array of vocabulary keys (English) (max 3).
    /// Japanese titles usually have no space before #, so instead of splitting on whitespace,
    /// a regex directly picks up "from # to the next whitespace/#".
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
        // Use the extracted tags to clean the #tag text and standalone # with empty content out of the title
        // (extractTagKeys must come first: after cleaning, the target #tags are no longer in the title,
        // so reversing the order would leave tags empty)
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
            // The post is out = the moment there is a reason for likes/comments to arrive.
            // This is the second place where permission is asked (nothing happens if already decided)
            await PushNotificationService.shared.requestAuthorizationIfNeeded()
        } else {
            // Do not silently swallow failures (046 rate limit has its own message, everything else is generic)
            if postService.lastCreateFailure == .rateLimited {
                // 057: the number is stated explicitly because of the limit of 5 (UserPostService.dailyPostLimit =
                // in sync with the server)
                submitError = lang == .japanese
                    ? "1日の投稿は\(UserPostService.dailyPostLimit)件までです。24時間経つと枠が戻ります"
                    : "You can post up to \(UserPostService.dailyPostLimit) times a day. Slots free up after 24 hours"  // Copy waiting for user review
            } else {
                submitError = lang == .japanese
                    ? "投稿できませんでした。時間をおいて再試行してください"
                    : "Couldn't post. Please try again later"  // Copy waiting for user review
            }
        }
    }
}

// MARK: - DrawnCheckmark (the "drawn" check for post completion)

/// Checkmark whose stroke runs left → right with trim(from:to:). Relative coordinates based on an 88pt frame
private struct DrawnCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.28, y: rect.height * 0.53))
        p.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.69))
        p.addLine(to: CGPoint(x: rect.width * 0.73, y: rect.height * 0.35))
        return p
    }
}

// MARK: - PostTitleField (separate child View, isolated for performance)

private struct PostTitleField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            // Real-device feedback round 8: 3 lines was narrow and hard to tap, so the height of 5 lines is always
            // reserved (2026-07-15)
            // (7 lines overlapped the lock card/footer below, real-device feedback round 9)
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
