//
//  MyProfileView.swift
//  AppBlocker
//
//  My page (TikTok-style profile screen)
//  Shows your posts and liked quotes. Following opens a separate screen by tapping the number in the
//  header
//

import SwiftUI
import Supabase

struct MyProfileView: View {
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var quoteService = QuoteService.shared
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared
    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var notifService = NotificationService.shared
    @ObservedObject private var pushService = PushNotificationService.shared

    @State private var selectedSection: ProfileSection = .posts
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var jumpQuote: Quote?
    @State private var jumpPost: UserPost?
    /// Post opened from the likes tab (can include other users' posts). Kept separate from jumpPost:
    /// jumpPost navigates to "your own post list", so feeding it another user's post opens a different
    /// post
    @State private var jumpLikedPost: UserPost?
    /// Target of the confirmation dialog for grid long press delete (instant delete invites accidents,
    /// so always ask for confirmation)
    @State private var deleteCandidate: UserPost?
    @State private var followerCount: Int = 0
    @State private var showNotifications: Bool = false
    /// Rank pill → ranking screen (2026-09-05)
    @State private var showRanking: Bool = false
    @State private var showProfileEdit: Bool = false
    // showFollowedAccounts was removed 2026-08-04. When the Following entry was moved to settings
    // (SettingsListView) in plan D rev 2 (2026-07-30), only the place that set it to true was removed,
    // and the @State and navigationDestination stayed behind without ever firing. The more Bool-driven
    // navigationDestination modifiers are stacked on the same view, the easier it is to get stuck (see
    // push(_:) below), so it is removed. The screen itself still opens from "フォロー中のアカウント"
    // ("Accounts you follow") in SettingsListView as before
    /// Plan D: stats sheet. Shown with sheet(item:). Non-nil = shown + the sheet's focus (depends on the
    /// entry point: tap on total lock = lock time / top percentile pill = top percentile). 2026-07-30 real
    /// device feedback: with isPresented + a separate @State there was a bug where the first presentation
    /// was drawn before the focus was set, so it switched to the item approach
    @State private var statsSheetFocus: ProfileStatsSheet.Focus?
    /// Plan D rev 3: tap on the follower count → [Followers|Following] tab list (IG style)
    @State private var showFollowList: Bool = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var totalFollowing: Int {
        followService.followedAuthorIds.count + followService.followedUserIds.count
    }

    private var totalLikesReceived: Int {
        postService.myPosts.reduce(0) { $0 + $1.likeCount }
    }

    /// Top percentile text. When data is insufficient (no record, or fewer than 10 people in the pool)
    /// it shows an em dash placeholder
    private var topPercentText: String {
        guard let percentile = sessionTracker.percentile,
              percentile.hasData,
              (percentile.totalUsers ?? 0) >= 10,
              let topPercent = percentile.topPercent else {
            return "—"
        }
        let roundedPercent = max(1, Int(topPercent.rounded()))
        return L.profileTopPercentValue(roundedPercent, lang)
    }

    /// Completion rate text (last 30 days, timer only). When data is insufficient (0 target sessions)
    /// it shows an em dash placeholder
    private var completionRateText: String {
        guard let completion = sessionTracker.completion,
              completion.hasData,
              let rate = completion.ratePercent else {
            return "—"
        }
        return L.profileCompletionValue(rate, lang)
    }

    /// Value of the completion rate row in the detail sheet (e.g. "92% (12/13回)" ("92% (12/13 times)")).
    /// nil / insufficient data shows an em dash placeholder
    private func completionRowValue(_ c: BlockSessionTracker.CompletionRate?) -> String {
        guard let c, c.hasData, let rate = c.ratePercent,
              let done = c.completedCount, let total = c.eligibleCount else { return "—" }
        return L.statInfoCompletionRow(rate, done, total, lang)
    }

    /// Value of the rank row in the detail sheet (e.g. "3位 / 128人中" ("#3 of 128"))
    private var rankRowValue: String {
        guard let p = sessionTracker.percentile, p.hasData,
              let rank = p.rank, let total = p.totalUsers else { return "—" }
        return L.statInfoRankRow(rank, total, lang)
    }

    /// Plan D: integer shown in gold type at the bottom right of the hero if within the TOP 10%. Outside
    /// it / pool too small = nil (earned design).
    /// 2026-07-31: removed test code that showed a fake 3% in debug builds
    /// (the look was already checked. If kept, numbers that are not real data would appear in screenshots)
    // 🔴 2026-09-09 real device feedback: the rank-only pill ("31位" ("#31")) was removed.
    //    User decision: "Show 'Top ◯%' to people in the top 10%. People below that do not need a
    //    rank pill". rank/onRankTap on the ProfileHero side are kept, so
    //    it can be brought back by passing one line if wanted.

    private var topPercentBadge: Int? {
        guard let p = sessionTracker.percentile, p.hasData,
              (p.totalUsers ?? 0) >= 10,
              let top = p.topPercent else { return nil }
        let rounded = max(1, Int(top.rounded()))
        return rounded <= 10 ? rounded : nil
    }

    // The private rows (first version of plan D) were removed in the 2026-07-30 real device feedback:
    // the streak moved to the top right of the lock tab, and completion rate / current position moved
    // into the sheet opened by tapping total lock time (also visible to others)

    enum ProfileSection: String, CaseIterable, Identifiable {
        case posts, likes
        var id: String { rawValue }
        func label(_ lang: AppLanguage) -> String {
            switch self {
            case .posts: return L.postsMy(lang)
            case .likes: return L.profileLikes(lang)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        sectionPicker
                        content
                    }
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: ProfileHeroHeader.scrollSpace)
                // Attach the hero image flush to the top of the screen (under the status bar) (following BeReal)
                .ignoresSafeArea(edges: .top)
            }
            .navigationTitle(L.profileTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            // The bar background is transparent and sits over the hero image (bell/gear/streak float on the
            // image)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // Title "マイページ" ("My page") (2026-07-16 stats pack: the streak was moved into the stats grid
                // below, so the StreakBadge in the toolbar was removed (the feature itself is gone))
                ToolbarItem(placement: .principal) {
                    Text(L.profileTitle(lang))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    notificationBell
                }
                // 🔴 There was also a bell at the top right, but it was removed (2026-08-29 user instruction).
                //    Making the user notice unread items is the job of **the badge on the person icon in the tab bar**
                //    (.badge in MainTabView). There is no need for the same bell twice, on the left and the right
                // 2026-09-09 user instruction: put the ranking to the left of the gear.
                // If the only entry to the ranking is "inside the card that comes up from the bottom", nobody finds it
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        push($showRanking)
                    } label: {
                        Image(systemName: "trophy.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    NavigationLink {
                        SettingsListView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
            .navigationDestination(isPresented: $showNotifications) {
                NotificationListView()
            }
            .navigationDestination(isPresented: $showRanking) {
                RankingView()
            }
            .navigationDestination(isPresented: $showProfileEdit) {
                ProfileEditView()
            }
            .navigationDestination(isPresented: $showFollowList) {
                FollowListView()
            }
            .sheet(item: $statsSheetFocus) { focus in
                lockStatsSheet(focus: focus)
            }
            // Arrived by tapping a push notification. Picked up from both onChange and task so it opens
            // through the same path whether the tab is already shown or was just created
            .onChange(of: pushService.shouldOpenNotificationList) { _, shouldOpen in
                openNotificationListIfRequested(shouldOpen)
            }
            .task {
                // Always resync likedQuoteIds ⇔ likedQuotes (fixes likes made in the feed not showing right after)
                await likeService.loadLikedQuoteObjects()
                // 2026-08-08: resync the post side too, for the same reason. Without this, a post liked in the
                // feed does not appear when the tab is opened right after
                await likeService.loadLikedPostObjects()
                await postService.loadMyPosts()
                // Always keep the order flushQueue (apply the queue) → loadStats (fetch stats).
                // In the reverse order, the stats would not include the queued items that were not applied yet
                await sessionTracker.flushQueue()
                await sessionTracker.loadStats()
                await loadFollowerCount()
                await notifService.refreshUnreadCount()
                openNotificationListIfRequested(pushService.shouldOpenNotificationList)
            }
            // push navigation (unified on navigationDestination, because right-swipe back structurally does not
            // work with fullScreenCover)
            .navigationDestination(item: $jumpQuote) { quote in
                FilteredQuoteFeedView(
                    title: L.profileLikes(lang),
                    quotes: likeService.likedQuotes,
                    startIndex: likeService.likedQuotes.firstIndex(where: { $0.id == quote.id }) ?? 0
                )
            }
            // Fetch in one call whether restricted posts have a pending appeal (same style as FeedCardListView)
            .task(id: moderatedPostIds) {
                guard !moderatedPostIds.isEmpty else {
                    appealPendingPostIds = []
                    return
                }
                appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: moderatedPostIds)
            }
            .navigationDestination(item: $jumpPost) { post in
                MyPostsFeedView(
                    posts: postService.myPosts,
                    startIndex: postService.myPosts.firstIndex(where: { $0.id == post.id }) ?? 0
                )
            }
            // Post opened from the likes tab (2026-08-08). The author differs per post, so
            // passing several to MyPostsFeedView can only apply one author's info.
            // Pass only the tapped item and state that post's author explicitly.
            // ⚠️ canDelete: false is required (never show a delete button on another user's post)
            .navigationDestination(item: $jumpLikedPost) { post in
                let author = likeService.likedPostAuthors[post.userId]
                MyPostsFeedView(
                    posts: [post],
                    startIndex: 0,
                    authorDisplayName: author?.displayName,
                    authorAvatarUrl: author?.avatarUrl,
                    authorIsPro: author?.isPro ?? false,
                    canDelete: false
                )
            }
        }
    }

    /// Ids of your own posts with a pending appeal (for the "異議申し立て中" ("Appeal under review")
    /// label on the grid, 2026-07-25 real device feedback)
    @State private var appealPendingPostIds: Set<UUID> = []

    private var moderatedPostIds: Set<UUID> {
        Set(postService.myPosts
            .filter { $0.moderationStatus == "rejected" || $0.moderationStatus == "flagged" }
            .map(\.id))
    }

    // MARK: - Grid Tap (fix for real device feedback #7)

    /// Real device feedback #7 (first seen 2026-07-20, repro steps right after posting confirmed
    /// 2026-07-22): when the push of navigationDestination(item:) fails silently, item stays non-nil, and
    /// tapping the same post again gives "value unchanged = navigation does not fire", so the grid stops
    /// responding forever (switching tabs does not fix it. It stays stuck until the NavigationStack
    /// resyncs, e.g. by going to the notifications page and back).
    /// When the stuck state is detected, set it back to nil once and push again on the next run loop so
    /// the second and later taps reliably work. The root cause of the first push failing (triggered right
    /// after posting) needs a separate real device investigation.
    private func openPost(_ post: UserPost) {
        if jumpPost != nil {
            jumpPost = nil
            DispatchQueue.main.async { jumpPost = post }
        } else {
            jumpPost = post
        }
    }

    /// Same guard as openPost (for the liked quotes grid)
    private func openQuote(_ quote: Quote) {
        if jumpQuote != nil {
            jumpQuote = nil
            DispatchQueue.main.async { jumpQuote = quote }
        } else {
            jumpQuote = quote
        }
    }

    /// The same guard for navigationDestination(isPresented:) driven by a Bool (2026-08-04).
    /// Real device bug: after opening "プロフィールを編集" ("Edit profile") once and coming back, it
    /// never responds again. It gets stuck exactly like the item: version (openPost): if the push fails
    /// silently / pop does not write the binding back to false, it stays true, and assigning `= true`
    /// again gives "value unchanged = navigation does not fire", so the button is dead forever.
    /// If it is already true (= stuck), set it back to false once, wait a moment, and push again so the
    /// second and later taps work.
    /// ⚠️ This is a recovery measure, not a root fix (the reason the first push fails is separate).
    ///
    /// asyncAfter 0.05 seconds comes from a 2026-08-04 review: openPost (item version) works not because
    /// of the async re-push but because "the value itself changes on every tap", and a Bool has no such
    /// way out. A plain DispatchQueue.main.async can be drained before the current CATransaction commits,
    /// and if false→true is merged into the same update pass it counts as "no change" and the navigation
    /// does not fire. A 0.05 second delay reliably crosses into a separate transaction
    /// (this path runs only when stuck, so normal taps get no delay at all).
    private func push(_ flag: Binding<Bool>) {
        if flag.wrappedValue {
            flag.wrappedValue = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flag.wrappedValue = true }
        } else {
            flag.wrappedValue = true
        }
    }

    // The post entry point moved to the + in the center of the tab bar (user decision 2026-07-11.
    // Old: FAB at the bottom right)

    /// Consume the push notification tap request exactly once and open the notification list
    private func openNotificationListIfRequested(_ shouldOpen: Bool) {
        guard shouldOpen else { return }
        pushService.shouldOpenNotificationList = false
        push($showNotifications)
    }

    // MARK: - Notification Bell

    /// Entry to notifications (bell + unread badge). The same thing is placed at both top left and top
    /// right, so always build it from this one place (prevents fixing only one and the looks drifting apart)
    private var notificationBell: some View {
        Button {
            push($showNotifications)
        } label: {
            // Real device feedback (2026-07-25): keep the bell at its original size in the center, widen only
            // the invisible container (26×24) slightly, and put the badge on its top right corner. The badge
            // overlaps the bell icon itself and "looks like it sticks out", but it does not leave the container,
            // so it is not clipped (pushing it outside the frame with offset got its top right cut off at the
            // button bounds)
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 26, height: 24)
                if notifService.unreadCount > 0 {
                    unreadBadge(count: notifService.unreadCount)
                }
            }
        }
    }

    // MARK: - Unread Badge

    private func unreadBadge(count: Int) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color.red))
    }

    // MARK: - Header (BeReal-style hero, 2026-07-10 / made a 2×2 grid in the 2026-07-16 stats pack)
    // Stats = followers / following / likes. Total lock / streak / completion rate / top percentile are
    // all moved into the 2×2 grid (chips) under the action buttons.

    private var header: some View {
        ProfileHeroHeader(
            hero: .url(auth.avatarUrl?.absoluteString),
            displayName: auth.displayName?.isEmpty == false ? auth.displayName! : "—",
            isPro: auth.isPro,
            handle: auth.handle,
            bio: auth.bio,
            // Show the dream (declaration) to the owner whether it is public or private. When private, mark it
            // with a padlock
            dreamText: auth.dream,
            dreamLocked: !(auth.dream?.isEmpty ?? true) && !auth.dreamIsPublic,
            // Plan D (2026-07-30): all chips removed. Stats row = followers / total lock / likes,
            // gold type next to the name only for TOP 10%, streak and completion rate (+ current position when
            // outside the top) in a private row visible only to the owner.
            // Following moved from the stats row to followingLink (right under the header), and the details of
            // the old chips were gathered in lockStatsSheet, opened by tapping total lock
            topPercent: topPercentBadge,
            onTopPercentTap: {
                statsSheetFocus = .topPercent
            },
            stats: [
                ProfileHeroStat(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang), action: {
                    push($showFollowList)
                }),
                ProfileHeroStat(value: sessionTracker.formattedTotal(), label: L.profileLockTime(lang), action: {
                    statsSheetFocus = .lockTime
                }),
                ProfileHeroStat(value: "\(totalLikesReceived)", label: L.profileLikes(lang))
            ],
            actionTitle: L.settingsEditProfile(lang),
            actionIsProminent: false,
            onAction: { push($showProfileEdit) }
        )
    }

    // MARK: - Stats sheet (plan D)
    // The Following entry was removed from the profile in the 2026-07-30 real device feedback and moved
    // to the account section of settings (SettingsListView) (a rarely used management feature belongs
    // in settings. Nothing is added to the profile)

    /// Stats sheet (2026-07-30 premium pass: the stat of the entry point becomes the focus. Shared
    /// implementation = ProfileStatsSheet)
    /// The streak row was removed in the 2026-07-30 real device feedback (unified into the owner-only
    /// display at the top right of the lock tab)
    /// 🔴 You cannot navigate from inside the stats sheet (the sheet has no NavigationStack).
    ///    Close the sheet first, and push after it has fully closed (same technique as unlock method
    ///    sheet → paywall)
    private func openRankingFromSheet() {
        statsSheetFocus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            push($showRanking)
        }
    }

    private func lockStatsSheet(focus: ProfileStatsSheet.Focus) -> some View {
        let common: [ProfileStatsSheetRow] = [
            .init(icon: "checkmark.circle", label: L.statSheetCompletion30(lang), value: completionRowValue(sessionTracker.completion)),
            .init(icon: "infinity", label: L.statSheetCompletionAll(lang), value: completionRowValue(sessionTracker.completionAllTime))
        ]
        let rows: [ProfileStatsSheetRow] = focus == .lockTime
            ? common + [
                .init(icon: "percent", label: L.profileTopPercent(lang), value: topPercentText),
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet)
            ]
            : [
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet),
                .init(icon: "lock.fill", label: L.profileLockTime(lang), value: sessionTracker.formattedTotal())
            ] + common
        return ProfileStatsSheet(
            focus: focus,
            lockTimeText: sessionTracker.formattedTotal(),
            topPercentValue: topPercentBadge,
            topPercentText: topPercentText,
            rows: rows
        )
    }

    // MARK: - Picker

    private var sectionPicker: some View {
        Picker("", selection: $selectedSection) {
            ForEach(ProfileSection.allCases) { section in
                Text(section.label(lang)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .posts: postsContent
        case .likes: likesContent
        }
    }

    @ViewBuilder
    private var postsContent: some View {
        if postService.myPosts.isEmpty {
            emptyPlaceholder(
                systemImage: "square.and.pencil",
                title: L.postsNone(lang),
                subtitle: L.postsNoneSubtitle(lang)
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(postService.myPosts) { post in
                    UserPostGridCell(
                        post: post,
                        onTap: { openPost(post) },
                        showsModerationState: true,
                        isAppealPending: appealPendingPostIds.contains(post.id)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteCandidate = post
                        } label: {
                            Label(L.postsDelete(lang), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            // Full deletion (DB + Storage, cannot be restored), so always ask for confirmation twice.
            // 2026-07-22 real device feedback: confirmationDialog → unified on the standard alert in the center
            // of the screen (same format for every delete confirmation)
            .alert(
                L.postsDeleteConfirmTitle(lang),
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                )
            ) {
                Button(L.postsComposerCancel(lang), role: .cancel) {
                    deleteCandidate = nil
                }
                Button(L.postsDeleteAction(lang), role: .destructive) {
                    if let target = deleteCandidate {
                        let pid = target.id
                        Task { @MainActor in await postService.deletePost(pid) }
                    }
                    deleteCandidate = nil
                }
            } message: {
                Text(L.postsDeleteConfirmMessage(lang))
            }
        }
    }

    @ViewBuilder
    private var likesContent: some View {
        // 🔴 2026-08-08: previously this only looked at likedQuotes, so it showed only when the user liked a
        // quote from the official account, and all likes on normal users' posts were missing
        if likeService.likedQuotes.isEmpty && likeService.likedPosts.isEmpty {
            emptyPlaceholder(
                systemImage: "heart.slash",
                title: L.profileNoLikes(lang),
                subtitle: L.profileNoLikesSubtitle(lang)
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                // Liked posts (added 2026-08-08). This is not your own grid, so
                // do not show moderation state (there is no reason to show the review state of other users' posts)
                ForEach(likeService.likedPosts) { post in
                    UserPostGridCell(
                        post: post,
                        // ⚠️ Do not use openPost (it jumps to your own post list).
                        // Other users' posts are not in postService.myPosts, so firstIndex is nil and
                        // an unrelated post of your own opens
                        onTap: { jumpLikedPost = post }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            let pid = post.id
                            Task { @MainActor in
                                await likeService.togglePostLike(postId: pid)
                                likeService.removeFromLikedPosts(postId: pid)
                            }
                        } label: {
                            Label(L.profileUnlike(lang), systemImage: "heart.slash")
                        }
                    }
                }

                ForEach(likeService.likedQuotes) { quote in
                    LikedQuoteGridCell(
                        quote: quote,
                        onTap: { openQuote(quote) }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            let qid = quote.id
                            Task { @MainActor in
                                await likeService.unlike(quoteId: qid)
                                likeService.removeFromLikedQuotes(quoteId: qid)
                            }
                        } label: {
                            Label(L.profileUnlike(lang), systemImage: "heart.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func loadFollowerCount() async {
        guard let uid = auth.userId else {
            followerCount = 0
            return
        }
        struct FollowerRow: Decodable { let id: UUID }
        do {
            let rows: [FollowerRow] = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id")
                .eq("followed_user_id", value: uid.uuidString)
                .execute()
                .value
            self.followerCount = rows.count
        } catch {
            print("⚠️ Failed to load my follower count: \(error)")
        }
    }

    private func emptyPlaceholder(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

#Preview {
    MyProfileView()
}
