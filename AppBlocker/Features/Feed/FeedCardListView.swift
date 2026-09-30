//
//  FeedCardListView.swift
//  AppBlocker
//
//  Shared detail feed that stacks FeedListCard vertically (spec finalized 2026-07-10).
//  Profile grid tap / likes list / author topic / tag feed
//  all use this one View (old: the full-screen TikTok-style scroll views of FeedItemCard).
//
//  - Opens already scrolled to startItemKey (FeedItem.id)
//  - When a post card is shown, count a view with record_post_view (this is what the tap count is)
//  - Comments are pushed to CommentPageView (sheet removed)
//  - If canDeletePosts = true (own posts), show delete in the … menu and show the rejected badge
//

import SwiftUI

struct FeedCardListView: View {

    let items: [FeedItem]
    /// Whether this list should count record_post_view as a tap that "opened the post detail".
    /// Set false on surfaces where posts are only scrolled past, such as the home feed
    /// (Recommended/Following) and the tag/author/likes lists (so scrolling past does not pollute
    /// post_views, which the w_seen penalty in 029 reads). No default, so every caller must set it
    /// explicitly
    let recordsViews: Bool
    /// Position to scroll to when opened (FeedItem.id). nil means the top
    var startItemKey: String? = nil
    /// Whether this is your own post feed (show delete in the … menu / show the rejected badge)
    var canDeletePosts: Bool = false
    /// Post ids rejected by AI moderation (badge shown only on your own posts)
    var rejectedPostIds: Set<UUID> = []
    /// Post ids flagged by AI moderation (top banner shown only on your own posts. Since 039 the policy
    /// is to make it visible to the owner)
    var flaggedPostIds: Set<UUID> = []
    /// Set this when the parent wants to replace the behavior, e.g. disabling tag taps inside a tag feed
    var onTagTapOverride: ((String) -> Void)? = nil
    /// Inside the author topic feed itself, disable the tap on "- author name" (it is already that
    /// author's list)
    var disableTopicTap: Bool = false
    /// Notify the parent after a like toggle (e.g. to sync the likes list grid). (item, state after the
    /// like)
    var onLikeToggled: ((FeedItem, Bool) -> Void)? = nil
    /// Notify the parent after blocking a user (e.g. to reload the list)
    var onBlocked: (() -> Void)? = nil
    /// pull-to-refresh (disabled if nil). For the home feed Recommended/Following
    var onRefresh: (() async -> Void)? = nil
    /// Extra top padding (e.g. for the home segment bar)
    var topContentInset: CGFloat = 0
    /// Whether to insert an AdMob native ad every N items (2026-07-31 ads v1).
    /// true only for the home feed (Recommended/Following). Never shown in derived feeds such as the
    /// profile/tag/likes lists (user instruction: "do not show them anywhere except the feed screen").
    /// They are inserted at render time, not mixed into the items array = no effect on the scoring/caps
    /// of 062/063
    var showsAds: Bool = false
    /// Tell the parent when "is the card more than half visible on screen" changes
    /// (used to measure dwell time for the unlock challenge). nil does nothing = no effect on normal feeds.
    /// 🔴 onAppear/onDisappear is too strict: moving the view slightly stops the measurement
    var onItemVisibilityChanged: ((FeedItem, Bool) -> Void)? = nil

    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var blockService = BlockService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var extrasService = FeedExtrasService.shared
    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var commentService = CommentService.shared

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    @Environment(\.dismiss) private var dismiss

    @State private var scrollTargetKey: String?
    /// true while a finger is touching the screen (used to run pull-to-refresh "at the moment of release")
    @State private var isFingerDown = false
    @State private var showOfficialProfile = false
    @State private var selectedTopicAuthor: Author?
    @State private var selectedTopicQuotes: [Quote] = []
    @State private var selectedTopicStartIndex: Int = 0
    @State private var showTopicFeed = false
    @State private var selectedUserId: UUID?
    @State private var selectedUserName: String?
    @State private var showUserProfile = false
    @State private var selectedTag: String?
    @State private var showTagFeed = false
    @State private var commentPageRequest: CommentPageRequest?
    /// Holds the item key of the most recently opened comment page, so the extras cache can be
    /// invalidated the moment commentPageRequest goes back to nil (F6)
    @State private var lastCommentItemKey: String?
    @State private var reportTarget: ReportSheetView.Target?
    /// Target of the appeal sheet (from the "異議申し立て" ("Appeal") button on the rejected scrim or on
    /// the flagged banner)
    @State private var appealTarget: AppealTarget?
    /// Ids of your own posts with a pending appeal under review (switches the pill on the restriction
    /// overlay to "異議申し立て中" ("Appeal under review"). 2026-07-23 real device feedback)
    @State private var appealPendingPostIds: Set<UUID> = []
    @State private var blockCandidateUserId: UUID?
    @State private var showBlockConfirm = false
    @State private var showReportThanks = false
    @State private var saveToastMessage: String?
    @State private var saveAlert: SaveImageAlert?
    @State private var deleteCandidatePostId: UUID?
    /// Target of the likers list sheet (opened by tapping the stack)
    @State private var likersSheetItem: FeedItem?
    /// Posts deleted inside this view (the parent's array is a let, so exclude them locally)
    @State private var deletedPostIds: Set<UUID> = []

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var visibleItems: [FeedItem] {
        items.filter { !($0.kind == .post && deletedPostIds.contains($0.itemId)) }
    }

    var body: some View {
        if let onRefresh {
            scrollBody
                // Watches whether a finger is touching the screen (the refreshable below uses it to "wait until
                // release"). It is a simultaneousGesture, so scrolling and taps work as before
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in if !isFingerDown { isFingerDown = true } }
                        .onEnded { _ in isFingerDown = false }
                )
                .refreshable {
                    // ① Wait until the finger is released (2026-07-31 real device feedback).
                    // SwiftUI's refreshable fires "the moment the pull distance crosses the threshold", so
                    // without this the content would be replaced while the finger is still down. Fetch after release.
                    // Safety cap of 2 seconds (so it does not hang if the gesture is interrupted and onEnded never comes)
                    let waitStarted = Date()
                    while isFingerDown, Date().timeIntervalSince(waitStarted) < 2.0 {
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }

                    let fetchStarted = Date()
                    // ② Fetch in an unstructured Task detached from the view's lifetime.
                    // SwiftUI runs the refreshable action as "a task tied to that view", so
                    // if the view is rebuilt during the fetch, the task is cancelled and the
                    // URLSession request is aborted with it (-999 confirmed on a real device).
                    // Task { } does not inherit the enclosing cancellation, so the fetch always runs to completion
                    await Task { await onRefresh() }.value

                    // ③ If the fetch is too fast the spinner disappears almost instantly, so show it for at least
                    // 0.5 seconds
                    let elapsed = Date().timeIntervalSince(fetchStarted)
                    if elapsed < 0.5 {
                        try? await Task.sleep(nanoseconds: UInt64((0.5 - elapsed) * 1_000_000_000))
                    }
                }
        } else {
            scrollBody
        }
    }

    private var rawScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // The layout has no cards, so leave generous space between posts (with no border lines, the spacing
            // is the separator)
            LazyVStack(spacing: 28) {
                if topContentInset > 0 {
                    Color.clear.frame(height: topContentInset)
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    card(item: item)
                        .id(item.id)
                        // 2026-07-22 real device feedback, revised: the small top banner for flagged was rejected because
                        // (1) it overlaps the author header (2) taps on the text pass through to the avatar below (3) it is
                        // unclear that the post is restricted → rejected/flagged now both use the same "dark overlay +
                        // centered content". overlayPreferenceValue is used to place the trash can at "the top right of the
                        // image" (FeedMediaBoundsKey) (2026-07-25 real device feedback)
                        .overlayPreferenceValue(FeedMediaBoundsKey.self) { mediaAnchor in
                            if canDeletePosts, item.kind == .post,
                               rejectedPostIds.contains(item.itemId) || flaggedPostIds.contains(item.itemId) {
                                GeometryReader { geo in
                                    moderationStateOverlay(
                                        postId: item.itemId,
                                        isRejected: rejectedPostIds.contains(item.itemId),
                                        mediaFrame: mediaAnchor.map { geo[$0] }
                                    )
                                }
                            }
                        }
                        .onAppear {
                            if recordsViews, item.kind == .post {
                                extrasService.recordPostView(postId: item.itemId)
                            }
                        }
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            onItemVisibilityChanged?(item, isVisible)
                        }

                    // Ad slot: 1 in 10 items (NativeAdService.adInterval). With no inventory, FeedAdSlot returns
                    // empty and the whole slot disappears (no blank space left). The slot number is kept stable as
                    // "which slot it is", so the same ad shows in the same position when scrolling back and forth
                    if showsAds, (index + 1) % NativeAdService.adInterval == 0 {
                        FeedAdSlot(slot: (index + 1) / NativeAdService.adInterval - 1)
                    }
                }
            }
            // Cards are full screen width (no side padding). Only rounded corners mark a card (user instruction
            // 2026-07-10)
            .padding(.vertical, 16)
            .scrollTargetLayout()
        }
    }

    /// Bind the scroll position only for the "open at item N" use case (navigation from the
    /// grid/notifications).
    ///
    /// Root cause of the 2026-07-31 real device bug (user reported several times: "pull-to-refresh does
    /// not change the content"): when scrollPosition(id:) is bound, on every scroll SwiftUI writes "the
    /// ID of the card currently visible at the top" back to the binding, and even after the data is
    /// replaced it looks for the card with that ID and keeps it at the top of the screen. So the order
    /// was new, but the same card always sat at the top, and it looked as if "nothing had changed".
    /// (After an app restart the binding starts from nil, so the new order is visible = matches the
    /// symptom)
    ///
    /// The home feed (startItemKey == nil) does not need to remember the position, so the binding is
    /// removed entirely.
    @ViewBuilder
    private var positionedScroll: some View {
        if startItemKey == nil {
            rawScroll
        } else {
            rawScroll.scrollPosition(id: $scrollTargetKey, anchor: .top)
        }
    }

    private var scrollBody: some View {
        positionedScroll
        .overlay {
            // Empty state (e.g. the last item of the likes list was unliked, or deleting a post left 0 items).
            // The caller (MixedFeedView etc.) owns the loading state, so here the check is simply
            // "0 items to show"
            if visibleItems.isEmpty {
                emptyStateView
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .toolbarBackground(AppColors.background, for: .navigationBar)
        // Mitigation for real device feedback #6 (2026-07-22, unverified): the parent (MyProfileView etc.)
        // uses toolbarBackground(.hidden) for the hero, and we suspect that unless the pushed screen sets
        // the visibility explicitly, the layout around the bar inherits the parent's transparent state.
        // Set visible explicitly in addition to the style
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarRole(.editor)
        .onAppear {
            // Mitigation for real device feedback #6 (2026-07-22, unverified): skip setting the anchor when the
            // start position is the first item. The list already shows the top, so no scrolling is needed, but
            // if the initial anchor of scrollPosition is applied before the safe area is settled, it can cause
            // the symptom "the first card's header goes under the nav bar, and snaps back after pulling and
            // releasing" (the situation in the #6 screenshot = a single item shown from a notification / a tap
            // on the first grid item). Jumps to other items (grid item 2 and later) work as before
            if scrollTargetKey == nil, let startItemKey,
               startItemKey != visibleItems.first?.id {
                scrollTargetKey = startItemKey
            }
        }
        .task {
            // The first trigger for ads is the home feed appearing (not mixed into the launch sequence)
            if showsAds {
                // Load only after the ATT decision is settled. In the reverse order, the first load
                // is fixed as non-personalized. If AdTrackingConsent.isEnabled == false
                // (the default) it returns immediately, so preload runs at the same timing as before
                await AdTrackingConsent.shared.requestIfNeeded()
                NativeAdService.shared.preloadIfNeeded()
            }
            await extrasService.loadExtras(for: items)
        }
        // Fetch in one call whether your restricted (rejected/flagged) posts have a pending appeal, and
        // switch the overlay pill to "異議申し立て中" ("Appeal under review") (2026-07-23 real device
        // feedback). Passing the union to id: refetches only when the restricted set changes after a feed
        // reload
        .task(id: rejectedPostIds.union(flaggedPostIds)) {
            guard canDeletePosts else { return }
            let moderatedIds = rejectedPostIds.union(flaggedPostIds)
            guard !moderatedIds.isEmpty else { return }
            appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: moderatedIds)
        }
        // When items change on a feed reload (refresh etc.), extras follow.
        // An Equatable comparison of the whole items ([FeedItem]) walks everything on every update, so
        // change detection uses only a light id array (if the order/count changes, the id array changes too)
        .onChange(of: items.map(\.id)) { _, _ in
            // If the items really changed (= a real reload such as pull-to-refresh),
            // ignore the TTL cache and always refetch the latest like/comment counts
            Task { await extrasService.loadExtras(for: items, force: true) }
        }
        .navigationDestination(isPresented: $showOfficialProfile) {
            OfficialProfileView()
        }
        .navigationDestination(isPresented: $showTopicFeed) {
            if let author = selectedTopicAuthor {
                AuthorQuoteFeedView(
                    author: author,
                    quotes: selectedTopicQuotes,
                    startIndex: selectedTopicStartIndex
                )
            }
        }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = selectedUserId {
                UserProfileView(userId: uid, initialDisplayName: selectedUserName)
            }
        }
        .navigationDestination(isPresented: $showTagFeed) {
            if let tag = selectedTag {
                TagFeedView(tag: tag, lang: lang, showOriginal: showOriginal)
            }
        }
        .navigationDestination(item: $commentPageRequest) { request in
            CommentPageView(request: request)
        }
        // When the comment page is closed and the user comes back, mark that item's extras (comment
        // preview) for refetch, ignoring the TTL. Prevents a regression where your own new comment does not
        // appear in the preview for up to 60 seconds (F6)
        .onChange(of: commentPageRequest) { _, newValue in
            if newValue == nil, let key = lastCommentItemKey {
                extrasService.invalidate(key: key)
                lastCommentItemKey = nil
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheetView(target: target, onSubmitted: { showReportThanks = true })
        }
        .sheet(item: $appealTarget) { target in
            // On a successful submit, switch the pill to "異議申し立て中" ("Appeal under review") right away,
            // without reloading the feed
            AppealSheetView(target: target, onFiled: {
                if case .post(let pid) = target {
                    appealPendingPostIds.insert(pid)
                }
            })
        }
        .sheet(item: $likersSheetItem) { item in
            LikersSheet(item: item)
        }
        .alert(L.moderationBlockConfirmTitle(lang), isPresented: $showBlockConfirm) {
            Button(L.moderationReportCancel(lang), role: .cancel) { }
            Button(L.moderationBlock(lang), role: .destructive) {
                if let uid = blockCandidateUserId {
                    Task {
                        await blockService.block(userId: uid)
                        onBlocked?()
                    }
                }
            }
        } message: {
            Text(L.moderationBlockConfirmMessage(lang))
        }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) { }
        }
        .alert(
            L.feedMenuDownloadFailedTitle(lang),
            isPresented: Binding(
                get: { saveAlert != nil },
                set: { if !$0 { saveAlert = nil } }
            )
        ) {
            if saveAlert?.isPermissionError == true {
                Button(L.feedMenuOpenSettings(lang)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveAlert?.message ?? "")
        }
        // 2026-07-22 real device feedback: confirmationDialog (a sheet at the screen edge) is far from the
        // pressed button and looks like a "speech bubble", which felt wrong → use the standard alert in the
        // center of the screen, same as comment deletion
        .alert(
            L.postsDeleteConfirmTitle(lang),
            isPresented: Binding(
                get: { deleteCandidatePostId != nil },
                set: { if !$0 { deleteCandidatePostId = nil } }
            )
        ) {
            Button(L.postsComposerCancel(lang), role: .cancel) {
                deleteCandidatePostId = nil
            }
            Button(L.postsDeleteAction(lang), role: .destructive) {
                if let pid = deleteCandidatePostId {
                    deletedPostIds.insert(pid)
                    Task { @MainActor in
                        let success = await postService.deletePost(pid)
                        if success {
                            if visibleItems.isEmpty { dismiss() }
                        } else {
                            // It failed, so bring the card back (dismiss only on success)
                            deletedPostIds.remove(pid)
                        }
                    }
                }
                deleteCandidatePostId = nil
            }
        } message: {
            Text(L.postsDeleteConfirmMessage(lang))
        }
        .overlay(alignment: .bottom) {
            if let toast = saveToastMessage {
                Text(toast)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.black.opacity(0.8)))
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Card

    private func card(item: FeedItem) -> some View {
        FeedListCard(
            item: item,
            lang: lang,
            showOriginal: showOriginal,
            isLiked: isLikedItem(item),
            isFollowing: isFollowingAuthor(item),
            extras: extrasService.extras(for: item),
            onLikeTap: { handleLikeTap(item: item) },
            onFollowTap: { handleFollowTap(item: item) },
            onAuthorTap: { handleAuthorTap(item: item) },
            onTagTap: { tag in
                if let onTagTapOverride {
                    onTagTapOverride(tag)
                } else {
                    selectedTag = tag
                    showTagFeed = true
                }
            },
            onTopicTap: disableTopicTap ? nil : { handleTopicTap(item: item) },
            menuContent: moderationMenu(for: item),
            onCommentTap: {
                lastCommentItemKey = item.id
                commentPageRequest = CommentPageRequest(item: item)
            },
            onLikersTap: {
                likersSheetItem = item
            }
        )
    }

    // MARK: - Handlers (same style as MixedFeedView)

    private func isLikedItem(_ item: FeedItem) -> Bool {
        switch item.kind {
        case .quote: return likeService.isLiked(quoteId: item.itemId)
        case .post:  return likeService.isLikedPost(postId: item.itemId)
        }
    }

    private func isFollowingAuthor(_ item: FeedItem) -> Bool {
        switch item.kind {
        case .quote:
            return followService.isFollowing(authorId: OnePercentAccount.authorId)
        case .post:
            guard let authorId = item.authorId else { return false }
            return followService.isFollowingUser(userId: authorId)
        }
    }

    private func handleLikeTap(item: FeedItem) {
        let willLike = !isLikedItem(item)
        Task {
            switch item.kind {
            case .quote: await likeService.toggleLike(quoteId: item.itemId)
            case .post:  await likeService.togglePostLike(postId: item.itemId)
            }
        }
        onLikeToggled?(item, willLike)
        // Invalidate the TTL cache for this item only, so your own like shows in the likers stack right away
        // (fixes a regression where, on remount within the 60-second TTL, your own like seems to vanish, F6)
        extrasService.invalidate(key: item.id)
    }

    private func handleFollowTap(item: FeedItem) {
        Task {
            switch item.kind {
            case .quote:
                await followService.toggleFollow(authorId: OnePercentAccount.authorId)
            case .post:
                guard let authorId = item.authorId else { return }
                await followService.toggleUserFollow(userId: authorId)
            }
        }
    }

    private func handleAuthorTap(item: FeedItem) {
        switch item.kind {
        case .quote:
            showOfficialProfile = true
        case .post:
            guard let authorId = item.authorId else { return }
            selectedUserName = item.authorName
            selectedUserId   = authorId
            showUserProfile  = true
        }
    }

    /// Tap on "- author name" → fetch all quotes by that author and go to the author topic feed
    private func handleTopicTap(item: FeedItem) {
        guard item.kind == .quote, let authorId = item.authorId else { return }
        guard let author = QuoteService.shared.authors.first(where: { $0.id == authorId }) else { return }
        Task {
            do {
                let authorQuotes = try await QuoteService.shared.fetchQuotesByAuthor(authorId: authorId)
                await MainActor.run {
                    selectedTopicAuthor = author
                    selectedTopicQuotes = authorQuotes
                    selectedTopicStartIndex = authorQuotes.firstIndex { $0.id == item.itemId } ?? 0
                    showTopicFeed = true
                }
            } catch {
                print("⚠️ Failed to load author quotes for topic feed: \(error)")
            }
        }
    }

    // MARK: - Menu

    /// Common: share / download. Other users' UGC: report + block. Official quotes: report.
    /// Own UGC (canDeletePosts): delete
    private func moderationMenu(for item: FeedItem) -> AnyView {
        let shareText = L.feedMenuShareText(item, lang, showOriginal)
        let isMine: Bool = {
            guard item.kind == .post, let authorId = item.authorId, let me = auth.userId else { return false }
            return me == authorId
        }()
        let isOtherUGC: Bool = item.kind == .post && !isMine

        return AnyView(
            Group {
                ShareLink(item: shareText) {
                    Label(L.feedMenuShare(lang), systemImage: "square.and.arrow.up")
                }
                Button {
                    handleSaveImage(item: item)
                } label: {
                    Label(L.feedMenuDownload(lang), systemImage: "arrow.down.circle")
                }
                if isOtherUGC, let authorId = item.authorId {
                    let postId = item.itemId
                    Button {
                        reportTarget = .post(postId)
                    } label: {
                        Label(L.moderationReport(lang), systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        blockCandidateUserId = authorId
                        showBlockConfirm = true
                    } label: {
                        Label(L.moderationBlock(lang), systemImage: "hand.raised")
                    }
                }
                if item.kind == .quote {
                    Button {
                        reportTarget = .quote(item.itemId)
                    } label: {
                        Label(L.moderationReport(lang), systemImage: "flag")
                    }
                }
                if canDeletePosts, isMine {
                    Button(role: .destructive) {
                        deleteCandidatePostId = item.itemId
                    } label: {
                        Label(L.postsDelete(lang), systemImage: "trash")
                    }
                }
            }
        )
    }

    // MARK: - Save Image

    private func handleSaveImage(item: FeedItem) {
        Task {
            do {
                try await ImageExportService.shared.saveQuoteImage(
                    item: item,
                    lang: lang,
                    showOriginal: showOriginal
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    saveToastMessage = L.feedMenuDownloadSuccess(lang)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        saveToastMessage = nil
                    }
                }
            } catch ImageExportError.permissionDenied {
                saveAlert = SaveImageAlert(
                    message: L.feedMenuDownloadPermissionMessage(lang),
                    isPermissionError: true
                )
            } catch {
                saveAlert = SaveImageAlert(
                    message: L.feedMenuDownloadGenericMessage(lang),
                    isPermissionError: false
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.white.opacity(0.35))
            Text(L.feedEmptyGeneric(lang))
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - AI Moderation Overlay (shared by rejected/flagged, own posts only)

    /// Full overlay for restricted posts (rejected/flagged unified in the 2026-07-22 real device feedback
    /// revision). The dark overlay does not let taps through = it blocks all likes/comments etc. on
    /// restricted posts at once (user instruction: "fine to remove them if they cause bugs"). Because of
    /// this the "…" menu below can no longer be reached, so delete is offered by a button inside the
    /// overlay. The full verdict reason and the appeal are gathered in "詳細・異議申し立て" ("Details &
    /// appeal") → AppealSheetView (the 2-line notification preview cannot show the full text).
    private func moderationStateOverlay(postId: UUID, isRejected: Bool, mediaFrame: CGRect? = nil) -> some View {
        // For posts with a pending appeal, switch the pill/CTA to the "appeal filed" display (2026-07-23
        // real device feedback)
        let isAppealPending = appealPendingPostIds.contains(postId)
        return ZStack {
            // Left hit-testable = blocks interaction with the card below (like/comment/avatar navigation)
            Color.black.opacity(0.6)

            VStack(spacing: 12) {
                Image(systemName: isAppealPending
                      ? "clock.fill"
                      : (isRejected ? "eye.slash.fill" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                Text(isAppealPending
                     ? (lang == .japanese ? "異議申し立て中" : "Appeal under review")  // Wording is waiting for the user's review
                     : isRejected
                     ? L.postsModerationRejectedBadge(lang)
                     : (lang == .japanese ? "表示が制限されています" : "Visibility limited"))  // Wording is waiting for the user's review
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))

                Button {
                    appealTarget = .post(postId)
                } label: {
                    Text(isAppealPending
                         ? (lang == .japanese ? "詳細を見る" : "View details")  // Wording is waiting for the user's review
                         : (lang == .japanese ? "詳細・異議申し立て" : "Details & appeal"))  // Wording is waiting for the user's review
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.background)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(AppColors.textPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        // 2026-07-22 real device feedback: too many pills in the center made it hard to read → delete moved
        // to a trash icon at the top right (semi-transparent circle background with blur, user instruction).
        // 2026-07-25 real device feedback: position fixed to "top right of the image", not "top right of the
        // card (next to the header)"
        .overlay {
            if let mediaFrame {
                trashButton(for: postId)
                    .position(x: mediaFrame.maxX - 31, y: mediaFrame.minY + 31)  // 12pt margin from the image corner (button is 38pt, radius 19)
            } else {
                // Fallback when the frame could not be obtained (the old top right of the card)
                trashButton(for: postId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func trashButton(for postId: UUID) -> some View {
        Button {
            deleteCandidatePostId = postId
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }
}
