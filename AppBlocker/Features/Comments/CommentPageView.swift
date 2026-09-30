//
//  CommentPageView.swift
//  AppBlocker
//
//  BeReal-style full comment page (replaces the old CommentsSheet, spec finalized 2026-07-10).
//  A fully separate page reached by push:
//    - Top: fixed header with the post image (collapsible). Right after opening it is collapsed,
//      and it stays fixed no matter how far the comments scroll. Pulling down further at the top of
//      the list expands the image to almost full screen, and a tap / the chevron collapses it again
//    - Middle: scroll list of parent comments + replies (1 level)
//    - Bottom: CommentInputBar (separate View, keeps typing redraws local)
//  Supports both UGC posts (post) and official quotes (quote) (CommentTarget).
//

import SwiftUI
import UIKit

/// Push request to the comment page (for navigationDestination(item:))
struct CommentPageRequest: Identifiable, Hashable {
    /// For the image header. nil means a plain display with no image (e.g. navigation from a notification)
    let item: FeedItem?
    let target: CommentTarget
    /// Meaningful only when target is .post (the post author's user_id, used to decide whether to show the
    /// delete-all menu)
    let postOwnerId: UUID?

    var id: UUID { target.id }

    /// Build the standard request from a FeedItem
    init(item: FeedItem) {
        self.item = item
        switch item.kind {
        case .post:
            self.target = .post(item.itemId)
            self.postOwnerId = item.authorId
        case .quote:
            self.target = .quote(item.itemId)
            self.postOwnerId = nil
        }
    }

    init(item: FeedItem?, target: CommentTarget, postOwnerId: UUID?) {
        self.item = item
        self.target = target
        self.postOwnerId = postOwnerId
    }
}

struct CommentPageView: View {

    let request: CommentPageRequest

    @ObservedObject private var commentService = CommentService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    @State private var replyingTo: UserComment?
    @State private var requestFocus: Bool = false
    @State private var showDeleteAllConfirm: Bool = false
    @State private var deleteTargetComment: UserComment?
    @State private var selectedUserId: UUID?
    @State private var showUserProfile: Bool = false
    @State private var reportTarget: ReportSheetView.Target?
    @State private var showReportThanks = false
    /// Ids of parent comments whose replies are expanded (like TikTok, all collapsed by default,
    /// 2026-07-25 real device feedback)
    @State private var expandedParentIds: Set<UUID> = []

    private var target: CommentTarget { request.target }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var allComments: [UserComment] {
        commentService.comments(for: target)
    }

    private var topLevelComments: [UserComment] {
        allComments.filter { $0.parentCommentId == nil }
    }

    private func replies(to parentId: UUID) -> [UserComment] {
        allComments.filter { $0.parentCommentId == parentId }
    }

    private var isPostOwner: Bool {
        guard let me = auth.userId, let owner = request.postOwnerId else { return false }
        return me == owner
    }

    // Following BeReal (behavior finalized in real device feedback round 6, 2026-07-11):
    // The header image always exists inside the scroll at "full width, actual size (width×5/4)", and on
    // open it is already scrolled so that only the top 1/3 is visible.
    // Pulling down reveals as much of the image as you pull, and it stays there when released (no spring
    // back). At actual size it is the top of the content, so it stops naturally. Just a plain scroll.
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let headerFullHeight = width * 5.0 / 4.0
            // Height shown initially = a bit over 1/3 of the full screen height (including the status bar)
            let baseVisible = (geo.size.height + geo.safeAreaInsets.top) * 0.36
            let initialOffset = max(0, headerFullHeight - baseVisible)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if let item = request.item {
                            // Header at actual size (width×5/4). Only when pulled down further at the top of the content does it
                            // zoom while pinned to the top, like the profile hero (only while minY > 0)
                            Color.clear
                                .frame(height: headerFullHeight)
                                .overlay {
                                    GeometryReader { g in
                                        let minY = g.frame(in: .named("commentPageScroll")).minY
                                        let stretch = max(0, minY)
                                        let zoom = 1 + stretch / headerFullHeight

                                        FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal)
                                            .frame(width: width, height: headerFullHeight)
                                            // The top edge is flush with the screen, so only the bottom 2 corners are rounded
                                            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                                                topLeading: 0, bottomLeading: 24, bottomTrailing: 24, topTrailing: 0
                                            )))
                                            .scaleEffect(zoom, anchor: .top)
                                            .offset(y: -stretch)
                                    }
                                }
                                // Marker for the initial scroll position (when this reaches the top of the screen, 1/3 is visible)
                                .overlay(alignment: .topLeading) {
                                    Color.clear
                                        .frame(width: 1, height: 1)
                                        .offset(y: initialOffset)
                                        .id("commentInitialAnchor")
                                }
                        }

                        // The comment area gets at least "viewport - initial header" of height.
                        // Even with few comments the initial position (1/3 visible) works, and the scroll range is
                        // exactly a round trip of "1/3 ⇔ actual size".
                        // Plain mode (item == nil, e.g. quote comments opened from a notification) has no hero image, so
                        // there is no need to subtract the expected 36% height. If it stays subtracted, a scrollable blank
                        // space (dead scroll region) the size of the missing header appears at the top
                        VStack(spacing: 0) {
                            commentsSectionHeader
                            commentsContent
                            Spacer(minLength: 0)
                        }
                        .frame(
                            minHeight: request.item != nil
                                ? geo.size.height + geo.safeAreaInsets.top - baseVisible
                                : geo.size.height,
                            alignment: .top
                        )
                    }
                }
                .coordinateSpace(name: "commentPageScroll")
                .scrollDismissesKeyboard(.interactively)
                // 2026-07-25 real device feedback: tapping outside the input (comment list or hero image) closes the
                // keyboard. Where a Button sits, the Button takes priority, so
                // only taps on "unrelated places" reach here
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                }
                // Attach flush to the top of the screen (under the status bar) only when there is a hero image.
                // Plain mode does not ignore the safe area, so the comment heading does not slide under the status
                // bar / back chevron (content starts below the normal navigation bar)
                .ignoresSafeArea(edges: request.item != nil ? .top : [])
                .onAppear {
                    guard request.item != nil else { return }
                    // After layout is settled, jump to the initial position (image 1/3 visible) (no animation)
                    DispatchQueue.main.async {
                        proxy.scrollTo("commentInitialAnchor", anchor: .top)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // BeReal style: pin a native semi-transparent capsule input to the bottom edge
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommentInputBar(
                target: target,
                lang: lang,
                replyingTo: $replyingTo,
                requestFocus: $requestFocus
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Comments are a fully separate page, so hide the tab bar (Feed/Timer/My page) (real device feedback
        // 2026-07-11)
        .toolbar(.hidden, for: .tabBar)
        .toolbarRole(.editor)
        .toolbar {
            // "全削除" ("Delete all") menu only for the post author
            if isPostOwner && !allComments.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label(L.commentsDeleteAll(lang), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .task(id: target) {
            // 🔴 Do not change this to "fetch only when the cache is empty".
            //    CommentService is a singleton and its cache lives as long as the app, so
            //    a post that was opened once would never hit the network again, and new comments would never show
            //    (the preview under the card is updated by a separate RPC, fetch_feed_extras, so
            //     you get a mismatch: "it shows in the preview but not when opened". Real device report 2026-08-28).
            //    The spinner shows only when allComments.isEmpty, so while there is a cache
            //    the old content stays on screen and is refetched in the background, without flicker
            await commentService.loadComments(target: target)
        }
        .alert(L.commentsDeleteAllConfirmTitle(lang), isPresented: $showDeleteAllConfirm) {
            Button(L.postsComposerCancel(lang), role: .cancel) {}
            Button(L.commentsDelete(lang), role: .destructive) {
                if case .post(let postId) = target {
                    Task { _ = await commentService.deleteAllComments(postId: postId) }
                }
            }
        } message: {
            Text(L.commentsDeleteAllConfirmMessage(lang))
        }
        // 2026-07-22 real device feedback: confirmationDialog (action sheet at the screen edge) appears far
        // from the pressed delete button and feels wrong → changed to the standard alert in the center of the
        // screen (also matches the existing delete-all alert)
        .alert(
            L.commentsDeleteConfirmTitle(lang),
            isPresented: Binding(
                get: { deleteTargetComment != nil },
                set: { if !$0 { deleteTargetComment = nil } }
            )
        ) {
            Button(L.postsComposerCancel(lang), role: .cancel) {
                deleteTargetComment = nil
            }
            Button(L.commentsDelete(lang), role: .destructive) {
                if let comment = deleteTargetComment {
                    let cid = comment.id
                    let commentTarget = target
                    Task { await commentService.deleteComment(cid, target: commentTarget) }
                }
                deleteTargetComment = nil
            }
        } message: {
            Text(L.commentsDeleteConfirmMessage(lang))
        }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = selectedUserId {
                UserProfileView(userId: uid, initialDisplayName: nil)
            }
        }
        .sheet(item: $reportTarget) { ReportSheetView(target: $0, onSubmitted: { showReportThanks = true }) }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Comments Section (inside a single scroll)

    private var commentsSectionHeader: some View {
        HStack(spacing: 8) {
            Text(L.commentsTitle(lang))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text("\(allComments.count)")
                .font(.system(size: 16))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var commentsContent: some View {
        if commentService.isLoading(target: target) && allComments.isEmpty {
            loadingView
        } else if allComments.isEmpty {
            emptyView
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(topLevelComments) { parent in
                    CommentRow(
                        comment: parent,
                        indent: 0,
                        canDelete: canDelete(parent),
                        canReport: canReport(parent),
                        lang: lang,
                        ownerAvatarUrl: request.item?.authorAvatarUrl,
                        onLike: { Task { await commentService.toggleLike(commentId: parent.id, target: target, viewerIsPostOwner: isPostOwner) } },
                        onReply: { startReply(to: parent) },
                        onAvatarTap: { openUserProfile(userId: parent.authorUserId) },
                        onDelete: { deleteTargetComment = parent },
                        onReport: { reportTarget = .comment(parent.id) }
                    )

                    // Following TikTok (2026-07-25 real device feedback): replies are all collapsed by default,
                    // expanded with "── 返信N件を表示 ∨" ("── View N replies ∨"). After expanding:
                    // "── 返信を隠す ∧" ("── Hide replies ∧")
                    let replyList = replies(to: parent.id)
                    if !replyList.isEmpty {
                        if expandedParentIds.contains(parent.id) {
                            ForEach(replyList) { reply in
                                CommentRow(
                                    comment: reply,
                                    indent: 1,
                                    canDelete: canDelete(reply),
                                    canReport: canReport(reply),
                                    lang: lang,
                                    ownerAvatarUrl: request.item?.authorAvatarUrl,
                                    onLike: { Task { await commentService.toggleLike(commentId: reply.id, target: target, viewerIsPostOwner: isPostOwner) } },
                                    onReply: { startReply(to: parent) },  // Replies to a child are also attached to the parent (keeps 1 level)
                                    onAvatarTap: { openUserProfile(userId: reply.authorUserId) },
                                    onDelete: { deleteTargetComment = reply },
                                    onReport: { reportTarget = .comment(reply.id) }
                                )
                            }
                        }
                        repliesToggleRow(parentId: parent.id, count: replyList.count)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func canDelete(_ comment: UserComment) -> Bool {
        guard let me = auth.userId else { return false }
        if comment.authorUserId == me { return true }
        if let owner = request.postOwnerId, owner == me { return true }
        return false
    }

    /// You cannot report your own comment (auth.userId nil = not signed in, also not allowed)
    private func canReport(_ comment: UserComment) -> Bool {
        guard let me = auth.userId else { return false }
        return comment.authorUserId != me
    }

    private func startReply(to parent: UserComment) {
        replyingTo = parent
        requestFocus = true  // CommentInputBar takes the focus and resets the flag
        // Expand the existing replies of the reply target even if they are collapsed (so the sent reply does
        // not vanish inside the collapsed part)
        expandedParentIds.insert(parent.id)
    }

    /// "── 返信N件を表示 ∨" ("── View N replies ∨") / "── 返信を隠す ∧" ("── Hide replies ∧")
    /// (following TikTok, aligned with where the parent's body text starts)
    private func repliesToggleRow(parentId: UUID, count: Int) -> some View {
        let isExpanded = expandedParentIds.contains(parentId)
        return Button {
            // Force-disable animation (2026-07-25 real device feedback: seeing the rows slide into place is not
            // wanted. Removing withAnimation alone left the implicit animation, so it is killed with a Transaction)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if isExpanded {
                    expandedParentIds.remove(parentId)
                } else {
                    expandedParentIds.insert(parentId)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(AppColors.textTertiary.opacity(0.5))
                    .frame(width: 26, height: 1)
                Text(isExpanded
                     ? (lang == .japanese ? "返信を隠す" : "Hide replies")  // Wording is waiting for the user's review
                     : (lang == .japanese ? "返信\(count)件を表示" : "View \(count) replies"))  // Wording is waiting for the user's review
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textTertiary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.leading, 56)  // parent avatar (32) + spacing (10) + left padding (14) = where the body text starts
            .padding(.trailing, 14)
            .padding(.top, 0)
            .padding(.bottom, 6)  // Reduce the distance to the reply button (2026-07-25 real device feedback)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openUserProfile(userId: UUID) {
        selectedUserId = userId
        showUserProfile = true
    }

    // MARK: - Empty / Loading

    private var emptyView: some View {
        VStack(spacing: 12) {
            // 2026-07-25 real device feedback: the quotation mark made no sense → changed to a comment speech
            // bubble icon
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 34, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(L.commentsNone(lang))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary)
            Text(L.commentsNoneSubtitle(lang))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var loadingView: some View {
        ProgressView()
            .tint(AppColors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }
}

// MARK: - CommentInputBar (separate View)
//
// Important: this is a separate View to fully isolate the inputText changes and focus changes while
// typing from the body redraws of CommentPageView itself.
// Without it, every character re-evaluates the header / commentList / AvatarImage views too, and it
// stutters on a real device.

private struct CommentInputBar: View {

    let target: CommentTarget
    let lang: AppLanguage
    @Binding var replyingTo: UserComment?
    /// Set to true every time the parent requests focus. The receiver sets it back to false after focusing
    @Binding var requestFocus: Bool

    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var commentService = CommentService.shared

    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    /// Alert text when sending fails (046 rate limit / generic. nil = hidden)
    @State private var sendError: String?
    @FocusState private var focused: Bool

    // BeReal style: the bar itself has no background and floats, with only a semi-transparent material
    // capsule input + a white round send button (2026-07-10 real device feedback)
    var body: some View {
        VStack(spacing: 6) {
            if let target = replyingTo {
                replyHeader(target: target)
            }

            HStack(spacing: 10) {
                if auth.userId == nil {
                    Text(L.commentsLoginRequired(lang))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.vertical, 12)
                    Spacer()
                } else {
                    // BeReal glass look: ultraThinMaterial + a thin white stroke +
                    // a brighter placeholder. Comments passing underneath show through, blurred
                    TextField(
                        "",
                        text: $inputText,
                        prompt: Text(placeholderText).foregroundColor(.white.opacity(0.55))
                    )
                    .focused($focused)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .environment(\.colorScheme, .dark)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await submit() }
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.white))
                            .contentShape(Circle())
                    }
                    .opacity(canSubmit ? 1 : 0.45)
                    .animation(.easeOut(duration: 0.15), value: canSubmit)
                    .disabled(!canSubmit || isSending)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onChange(of: requestFocus) { _, newValue in
            if newValue {
                focused = true
                requestFocus = false
            }
        }
        // Delete/error modals are unified as a centered .alert (2026-07-22 design rule)
        .alert(
            lang == .japanese ? "コメントできません" : "Can't comment",  // Wording is waiting for the user's review
            isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
    }

    private var canSubmit: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 500 && !isSending
    }

    private var placeholderText: String {
        if let r = replyingTo, let name = r.authorName, !name.isEmpty {
            return L.commentsReplyPlaceholder(name, lang)
        }
        return L.commentsPlaceholder(lang)
    }

    private func replyHeader(target: UserComment) -> some View {
        HStack {
            Text(L.commentsReplyingTo(target.authorName ?? "—", lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
    }

    private func submit() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }

        let parentId = replyingTo?.id
        let ok = await commentService.createComment(
            target: target,
            text: trimmed,
            parentCommentId: parentId
        )
        if ok {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            inputText = ""
            replyingTo = nil
            focused = false  // Close the keyboard on a successful send
        } else {
            // Do not silently swallow failures (046 rate limit has its own text, everything else is generic)
            sendError = commentService.lastCreateWasRateLimited
                ? (lang == .japanese
                    ? "本日のコメント上限に達しました。また明日コメントできます"
                    : "You've reached today's comment limit. You can comment again tomorrow")  // Wording is waiting for the user's review
                : (lang == .japanese
                    ? "コメントを送信できませんでした。時間をおいて再試行してください"
                    : "Couldn't send your comment. Please try again later")  // Wording is waiting for the user's review
        }
    }
}

// MARK: - CommentRow

private struct CommentRow: View {
    let comment: UserComment
    let indent: Int  // 0 = parent, 1 = reply
    let canDelete: Bool
    let canReport: Bool
    let lang: AppLanguage
    /// For the "投稿者がいいねしました" ("Liked by the author") badge (the post author's avatar. nil for
    /// quote comments etc.)
    let ownerAvatarUrl: String?
    let onLike: () -> Void
    let onReply: () -> Void
    let onAvatarTap: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    // TikTok-style layout (2026-07-25 real device feedback):
    //   Row 1 = name + date / row 2 = body / row 3 = reply (left) + heart and count side by side
    //   (bottom right).
    //   Report/delete are no longer text buttons and live in the row's long press menu (same structure as
    //   TikTok. Keeping a way to report comment UGC also satisfies App Store 1.2)
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onAvatarTap) {
                // 2026-07-25 real device feedback: icons in the comment area are one size smaller
                AvatarImage(urlString: comment.authorAvatarUrl, size: indent == 0 ? 32 : 24)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(comment.authorName ?? "—")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)

                    Text(relativeTime(comment.createdAt))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                }

                // The body is the focus: one size larger, with enough line spacing
                // @mentions use a blue like YouTube (with the accent color = off-white they blend into the text)
                if let replyTo = comment.replyToName, indent == 1 {
                    (Text("@\(replyTo) ").foregroundColor(Color(hex: "3EA6FF"))
                     + Text(comment.text).foregroundColor(AppColors.textPrimary))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(comment.text)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Row 3: reply (left) + author-liked badge + like (right edge, count to the right of the heart = like
                // TikTok)
                HStack(spacing: 12) {
                    Button(action: onReply) {
                        Text(L.commentsReply(lang))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textTertiary)
                            .frame(minHeight: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Badge for "liked by the author" (TikTok's creator heart. Author avatar + red heart at the bottom
                    // right, the heart is separated from the avatar by a ring in the background color)
                    if comment.isLikedByOwner {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarImage(urlString: ownerAvatarUrl, size: 18)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.red)
                                .padding(2)
                                .background(Circle().fill(AppColors.background))
                                .offset(x: 4, y: 4)
                        }
                        .padding(.trailing, 4)  // Padding for the heart that sticks out
                    }

                    Spacer(minLength: 0)

                    Button(action: onLike) {
                        // To keep the heart in a fixed position, always reserve a fixed-width slot for the count
                        // (the heart does not move even when a like changes 0→1, 999→1K etc. Expected max = "999K")
                        HStack(spacing: 5) {
                            Image(systemName: comment.isLikedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 15))
                                .foregroundColor(comment.isLikedByMe ? .red : AppColors.textTertiary)
                                .likePopEffect(isLiked: comment.isLikedByMe, particleRadius: 14)
                            Text(comment.likeCount > 0 ? Self.compactCount(comment.likeCount) : "")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textTertiary)
                                .frame(width: 34, alignment: .leading)
                        }
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indent == 0 ? 14 : 56)
        .padding(.trailing, 14)
        .padding(.vertical, 6)  // 2026-07-25 real device feedback: reduce the spacing between comments
        .contentShape(Rectangle())
        // Long press menu: other users' comments = report / own (or post author permission) = delete
        .contextMenu {
            if canReport {
                Button {
                    onReport()
                } label: {
                    Label(L.moderationReport(lang), systemImage: "flag")
                }
            }
            if canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(L.commentsDelete(lang), systemImage: "trash")
                }
            }
        }
    }

    /// TikTok-style short notation (999 → 999 / 1500 → 1K / 1_200_000 → 1M).
    /// Guarantees a length that fits in the fixed-width slot (34pt)
    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return L.timeJustNow(lang) }
        if seconds < 3600 { return L.timeMinutesAgo(Int(seconds / 60), lang) }
        if seconds < 86400 { return L.timeHoursAgo(Int(seconds / 3600), lang) }
        if seconds < 604800 { return L.timeDaysAgo(Int(seconds / 86400), lang) }
        return L.timeWeeksAgo(Int(seconds / 604800), lang)
    }
}
