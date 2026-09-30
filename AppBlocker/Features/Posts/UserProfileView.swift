//
//  UserProfileView.swift
//  AppBlocker
//
//  Profile screen of a regular user (UGC poster)
//  Separate from the official great figures (AuthorProfileView)
//

import SwiftUI
import Supabase

struct UserProfileView: View {

    let userId: UUID
    var initialDisplayName: String?
    var initialAvatarUrl: String?

    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String?
    @State private var bio: String?
    @State private var dream: String?
    @State private var avatarUrl: String?
    @State private var handle: String?
    @State private var isPro: Bool = false
    /// Official badge. 🔴 ProfileHero already had the drawing code, but only this screen
    ///    did not read is_official, so no one got the badge (fixed 2026-08-30).
    ///    The 1% official account showed it because OfficialProfileView hardcodes true
    @State private var isOfficial: Bool = false
    @State private var followerCount: Int = 0
    @State private var followingCount: Int = 0
    @State private var percentile: BlockSessionTracker.BlockPercentile?
    /// Whether the other user follows you (mutual follow display, 058 RPC. false if not applied / on
    /// failure)
    @State private var isFollowedBy = false
    /// Stats sheet (visible on other people's profiles too. Only consecutive days are private to the
    /// user, so they are not shown). sheet(item:) approach: non-nil = shown + the focused item.
    /// Workaround for the first-presentation bug with isPresented + a separate @State (2026-07-30)
    @State private var statsSheetFocus: ProfileStatsSheet.Focus?
    /// Allow going to the ranking from the stats sheet on other people's profiles too (2026-09-09)
    @State private var showRanking: Bool = false

    /// Push only after the sheet has fully closed (there is no NavigationStack inside the sheet)
    private func openRankingFromSheet() {
        statsSheetFocus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showRanking = true
        }
    }
    @State private var totalBlockSeconds: Int = 0
    /// Consecutive lock days (from the get_user_stats RPC). Shown on other people's profiles too, by
    /// design (2026-07-16 stats pack)
    @State private var streakDays: Int = 0
    /// Completion rate (last 30 days, timer only, from the get_user_stats RPC)
    @State private var completion: BlockSessionTracker.CompletionRate?
    /// Completion rate (all time). For the stats cell detail sheet (nil on a DB without 034 applied)
    @State private var completionAllTime: BlockSessionTracker.CompletionRate?
    @State private var isLoadingProfile: Bool = true
    @State private var jumpPost: UserPost?
    @State private var reportTarget: ReportSheetView.Target?
    /// IDs of your own posts with an appeal under review (for the grid display when isSelf, 2026-07-25
    /// real device feedback)
    @State private var appealPendingPostIds: Set<UUID> = []
    @State private var showBlockConfirm: Bool = false
    @State private var showReportThanks: Bool = false

    /// Total lock time display (same format as BlockSessionTracker.formattedTotal())
    private var totalLockText: String {
        let hours = totalBlockSeconds / 3600
        let minutes = (totalBlockSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var viewingPosts: [UserPost] {
        postService.viewingPosts(for: userId)
    }

    /// IDs of restricted (rejected/flagged) posts when isSelf (key for bulk-fetching the appeal status)
    private var selfModeratedPostIds: Set<UUID> {
        guard isSelf else { return [] }
        return Set(viewingPosts
            .filter { $0.moderationStatus == "rejected" || $0.moderationStatus == "flagged" }
            .map(\.id))
    }

    private var totalLikesReceived: Int {
        viewingPosts.reduce(0) { $0 + $1.likeCount }
    }

    /// Top percentile display. Shows the em dash placeholder when data is insufficient (no record, or
    /// fewer than 10 people in the pool)
    /// Plan D: the integer shown in the gold type badge next to the name if within the TOP 10%. nil if
    /// outside it / the pool is too small
    private var topPercentBadge: Int? {
        guard let p = percentile, p.hasData,
              (p.totalUsers ?? 0) >= 10,
              let top = p.topPercent else { return nil }
        let rounded = max(1, Int(top.rounded()))
        return rounded <= 10 ? rounded : nil
    }

    private var topPercentText: String {
        guard let percentile = percentile,
              percentile.hasData,
              (percentile.totalUsers ?? 0) >= 10,
              let topPercent = percentile.topPercent else {
            return "—"
        }
        let roundedPercent = max(1, Int(topPercent.rounded()))
        return L.profileTopPercentValue(roundedPercent, lang)
    }

    /// Completion rate display (last 30 days, timer only). Shows the em dash placeholder when data is
    /// insufficient (0 target sessions)
    private var completionRateText: String {
        guard let completion = completion,
              completion.hasData,
              let rate = completion.ratePercent else {
            return "—"
        }
        return L.profileCompletionValue(rate, lang)
    }

    /// Value of the completion rate row in the detail sheet (e.g. "92% (12/13回)" ("92% (12/13 times)")).
    /// nil / insufficient data shows the em dash placeholder
    private func completionRowValue(_ c: BlockSessionTracker.CompletionRate?) -> String {
        guard let c, c.hasData, let rate = c.ratePercent,
              let done = c.completedCount, let total = c.eligibleCount else { return "—" }
        return L.statInfoCompletionRow(rate, done, total, lang)
    }

    /// Value of the rank row in the detail sheet (e.g. "3位 / 128人中" ("3rd / out of 128"))
    private var rankRowValue: String {
        guard let p = percentile, p.hasData,
              let rank = p.rank, let total = p.totalUsers else { return "—" }
        return L.statInfoRankRow(rank, total, lang)
    }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var isSelf: Bool {
        auth.userId == userId
    }

    private var isFollowing: Bool {
        followService.isFollowingUser(userId: userId)
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    profileHeader
                    postsSection
                }
            }
            .coordinateSpace(name: ProfileHeroHeader.scrollSpace)
            // Attach the hero image flush to the top edge of the screen (under the status bar) (following BeReal)
            .ignoresSafeArea(edges: .top)
        }
        // The name appears large inside the hero, so the bar title is empty. The bar background is also
        // transparent and laid over the image
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            reportTarget = .user(userId)
                        } label: {
                            Label(L.moderationReport(lang), systemImage: "flag")
                        }
                        Button(role: .destructive) {
                            showBlockConfirm = true
                        } label: {
                            Label(L.moderationBlock(lang), systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .task(id: selfModeratedPostIds) {
            guard isSelf, !selfModeratedPostIds.isEmpty else {
                appealPendingPostIds = []
                return
            }
            appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: selfModeratedPostIds)
        }
        .task {
            displayName = initialDisplayName
            avatarUrl = initialAvatarUrl
            await loadProfile()
            await postService.loadPosts(byUser: userId)
            if !isSelf {
                isFollowedBy = await followService.isFollowedBy(userId: userId)
            }
        }
        .navigationDestination(isPresented: $showRanking) {
            RankingView()
        }
        .sheet(item: $statsSheetFocus) { focus in
            lockStatsSheet(focus: focus)
        }
        // viewingPostsByUser is a keyed store keyed by userId, so even if this screen is pushed again
        // on top of itself, they do not overwrite/clear each other's data.
        // So no clearing is needed on pop (when this profile is revisited, .task refetches).
        // Push transition (unified on navigationDestination because swipe-right-to-go-back structurally
        // does not work with fullScreenCover)
        .navigationDestination(item: $jumpPost) { post in
            MyPostsFeedView(
                posts: viewingPosts,
                startIndex: viewingPosts.firstIndex(where: { $0.id == post.id }) ?? 0,
                authorDisplayName: displayName,
                authorAvatarUrl: avatarUrl,
                authorIsPro: isPro,
                canDelete: isSelf
            )
        }
        .sheet(item: $reportTarget) { target in
            ReportSheetView(target: target, onSubmitted: { showReportThanks = true })
        }
        .alert(L.moderationBlockConfirmTitle(lang), isPresented: $showBlockConfirm) {
            Button(L.moderationReportCancel(lang), role: .cancel) {}
            Button(L.moderationBlock(lang), role: .destructive) {
                Task {
                    await BlockService.shared.block(userId: userId)
                    dismiss()
                }
            }
        } message: {
            Text(L.moderationBlockConfirmMessage(lang))
        }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Header (BeReal-style hero, 2026-07-10)

    private var profileHeader: some View {
        ProfileHeroHeader(
            hero: .url(avatarUrl),
            displayName: displayName ?? "—",
            isPro: isPro,
            isOfficial: isOfficial,
            handle: handle,
            bio: bio,
            // For the dream, RLS returns only public (is_public=true) rows (if private, user_dreams has 0 rows
            // = hidden)
            dreamText: dream,
            // Plan D (2026-07-30): all chips removed. Stats row = followers / total lock / likes, and only the
            // TOP 10% gets the gold type next to the name (earned). Consecutive days and completion rate are
            // made private (only on the user's own My Page).
            // The following count is removed from the display (there was never a path to other people's
            // following lists). When following each other, the button changes to "相互フォロー" ("Mutuals") +
            // a two-way icon
            topPercent: topPercentBadge,
            onTopPercentTap: {
                statsSheetFocus = .topPercent
            },
            stats: [
                ProfileHeroStat(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang)),
                ProfileHeroStat(value: totalLockText, label: L.profileLockTime(lang), action: {
                    statsSheetFocus = .lockTime
                }),
                ProfileHeroStat(value: "\(totalLikesReceived)", label: L.profileLikes(lang))
            ],
            actionTitle: isSelf ? nil : (isFollowing && isFollowedBy
                ? (lang == .japanese ? "相互フォロー" : "Mutuals")  // Wording awaiting user review
                : L.authorFollowButton(isFollowing, lang)),
            actionIsProminent: !isFollowing,
            actionIcon: isFollowing ? (isFollowedBy ? "arrow.left.arrow.right" : "checkmark") : "plus",
            onAction: {
                Task { await followService.toggleUserFollow(userId: userId) }
            }
        )
    }

    // MARK: - Stats sheet (plan D: tap on total lock. Other-user profile version = no consecutive days)

    /// Stats sheet (2026-07-30 premium redesign: the stat used as the entry point is the main element.
    /// Shared implementation = ProfileStatsSheet, other-user version = no consecutive days)
    private func lockStatsSheet(focus: ProfileStatsSheet.Focus) -> some View {
        let common: [ProfileStatsSheetRow] = [
            .init(icon: "checkmark.circle", label: L.statSheetCompletion30(lang), value: completionRowValue(completion)),
            .init(icon: "infinity", label: L.statSheetCompletionAll(lang), value: completionRowValue(completionAllTime))
        ]
        let rows: [ProfileStatsSheetRow] = focus == .lockTime
            ? common + [
                .init(icon: "percent", label: L.profileTopPercent(lang), value: topPercentText),
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet)
            ]
            : [
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet),
                .init(icon: "lock.fill", label: L.profileLockTime(lang), value: totalLockText)
            ] + common
        return ProfileStatsSheet(
            focus: focus,
            lockTimeText: totalLockText,
            topPercentValue: topPercentBadge,
            topPercentText: topPercentText,
            rows: rows
        )
    }

    // MARK: - Posts Section

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.authorQuotes(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            if viewingPosts.isEmpty {
                Text(L.authorNoQuotes(lang))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(viewingPosts) { post in
                        UserPostGridCell(
                            post: post,
                            onTap: { jumpPost = post },
                            // Show the restricted state explicitly even when your own profile is opened in this screen from
                            // search etc.
                            showsModerationState: isSelf,
                            isAppealPending: isSelf && appealPendingPostIds.contains(post.id)
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Helpers

    private func loadProfile() async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }

        struct UserRow: Decodable {
            let displayName: String?
            let avatarUrl: String?
            let handle: String?
            let bio: String?
            let isPro: Bool?
            let isOfficial: Bool?
            let totalBlockSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case avatarUrl   = "avatar_url"
                case handle
                case bio
                case isPro       = "is_pro"
                case isOfficial  = "is_official"
                case totalBlockSeconds = "total_block_seconds"
            }
        }

        struct FollowerRow: Decodable {
            let id: UUID
        }

        do {
            let row: UserRow = try await SupabaseManager.shared.client
                .from("users")
                .select("display_name, avatar_url, handle, bio, is_pro, is_official, total_block_seconds")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            self.displayName = row.displayName ?? self.displayName
            self.avatarUrl   = row.avatarUrl   ?? self.avatarUrl
            self.handle      = row.handle
            self.bio         = row.bio
            self.isPro       = row.isPro ?? false
            self.isOfficial  = row.isOfficial ?? false
            self.totalBlockSeconds = row.totalBlockSeconds ?? 0
        } catch {
            print("⚠️ Failed to load user profile: \(error)")
        }

        // Dream: user_dreams (024 v2). RLS does not return private rows to anyone but the owner, so
        // no filtering is needed here (no row returned = hidden). The old approach of filtering only in the
        // app was removed because private dreams could be read by calling the API directly
        do {
            struct DreamRow: Decodable { let dream: String? }
            let rows: [DreamRow] = try await SupabaseManager.shared.client
                .from("user_dreams")
                .select("dream")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            self.dream = rows.first?.dream
        } catch {
            print("⚠️ Failed to load user dream: \(error)")
        }

        do {
            let rows: [FollowerRow] = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id")
                .eq("followed_user_id", value: userId.uuidString)
                .execute()
                .value
            self.followerCount = rows.count
        } catch {
            print("⚠️ Failed to load follower count: \(error)")
        }

        // Following (the number this user follows = 1% official + regular users combined).
        // Get only the count with head + count
        do {
            let response = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .execute()
            self.followingCount = response.count ?? 0
        } catch {
            print("⚠️ Failed to load following count: \(error)")
        }

        // Fetch the stats (top percentile / consecutive days / completion rate) with 1 RPC (033
        // get_user_stats). Total lock seconds are already fetched by the users select above, so they are not
        // used here (not fetched twice, so that the fallback display on RPC failure keeps coming from the
        // users select)
        do {
            struct UserStatsResponse: Decodable {
                let streakDays: Int
                let percentile: BlockSessionTracker.BlockPercentile
                let completion: BlockSessionTracker.CompletionRate
                // Added in 034. On a DB with only 033 applied, the key does not exist, so it is Optional
                let completionAllTime: BlockSessionTracker.CompletionRate?

                enum CodingKeys: String, CodingKey {
                    case streakDays = "streak_days"
                    case percentile
                    case completion
                    case completionAllTime = "completion_all_time"
                }
            }
            let params: [String: AnyJSON] = [
                "target_user_id": .string(userId.uuidString),
                "tz": .string(TimeZone.current.identifier)
            ]
            let result: UserStatsResponse = try await SupabaseManager.shared.client
                .rpc("get_user_stats", params: params)
                .execute()
                .value
            self.streakDays = result.streakDays
            self.percentile = result.percentile
            self.completion = result.completion
            self.completionAllTime = result.completionAllTime
        } catch {
            print("⚠️ Failed to load user stats: \(error)")
        }
    }
}

