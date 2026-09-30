//
//  MixedFeedView.swift
//  AppBlocker
//
//  Mixed feed (official quotes + UGC user_posts). A "おすすめ / フォロー中"
//  ("Recommended / Following") segment at the top.
//  2026-07-10 BeReal-style rework: full-screen TikTok paging → FeedCardListView (4:5 card list).
//  Card implementation / moderation menu / navigation to the comment page all live in FeedCardListView.
//

import SwiftUI

/// For showing the alert when saving an image fails. If `isPermissionError` is true, an extra
/// "設定を開く" ("Open Settings") button is shown.
struct SaveImageAlert: Identifiable {
    let id = UUID()
    let message: String
    let isPermissionError: Bool
}

struct MixedFeedView: View {
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var selectedSegment: Segment = .recommended
    /// While the tab is being refreshed by a re-tap, show the same spinner as pull-to-refresh under the
    /// segment bar (2026-08-04 real-device feedback). SwiftUI's refreshable cannot be triggered from code
    /// (there is no public API), so the same look is built by hand with a height animation of
    /// safeAreaInset. The height grows = the scroll area is pushed down, so it looks as if it was "pulled"
    @State private var isTabRefreshing = false

    enum Segment: Hashable {
        case recommended
        case following
    }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                Group {
                    switch selectedSegment {
                    case .recommended:
                        recommendedContent
                    case .following:
                        followingContent
                    }
                }
            }
            // The segment bar is pinned at the top with safeAreaInset. This way the pull-to-refresh spinner
            // appears "under" the bar and does not overlap the "おすすめ"/"フォロー中" ("Recommended"/"Following")
            // labels (real-device feedback 2026-07-10)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    segmentBar

                    // Spinner while the tab is being refreshed by a re-tap. It is shown "under" the bar,
                    // in the same position as for pull-to-refresh (it does not overlap the Recommended/Following labels)
                    if isTabRefreshing {
                        ProgressView()
                            .tint(.white)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isTabRefreshing)
            }
            // Do not silently swallow fetch failures (2026-07-31). When a refresh fails, show the reason instead
            // of "nothing happens". It disappears automatically after a few seconds
            .overlay(alignment: .top) {
                if let error = feedService.lastFeedError {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(AppColors.error.opacity(0.9))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { feedService.clearFeedError() }
                        .task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            feedService.clearFeedError()
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: feedService.lastFeedError)
            .navigationBarHidden(true)
        }
        // Re-tap of the selected feed tab → re-fetch the visible segment with the same content as
        // pull-to-refresh (2026-08-04 user request). The fetch function is the same one refreshable calls.
        // The notification is only sent "when already on the feed tab", so it is never received in a
        // background tab
        .onReceive(NotificationCenter.default.publisher(for: .reloadFeedTab)) { _ in
            reloadCurrentSegment()
        }
        .task {
            // Recommended / Following / total lock stats are independent of each other, so load them in parallel
            // (in series, the total wait would be the sum of all 3, and the first display feels slow)
            async let recommended: Void = feedService.recommendedFeed.isEmpty ? feedService.loadRecommended() : ()
            async let following: Void = feedService.followingFeed.isEmpty ? feedService.loadFollowing() : ()
            async let stats: Void = sessionTracker.loadStats()
            _ = await (recommended, following, stats)
        }
    }

    // MARK: - Segment Bar

    private var segmentBar: some View {
        ZStack {
            HStack(spacing: 24) {
                segmentButton(.recommended, title: L.feedRecommended(lang))
                segmentButton(.following,   title: L.feedFollowing(lang))
            }
            // No streak badge in the feed (user-specified 2026-07-06: only on the timer and My Page)
            // The magnifying glass button was removed on 2026-07-15 when the search tab (SearchView) was added
        }
        // When the magnifying glass was removed, the HStack{Spacer()} that stretched the width was also
        // removed, so the bar shrank to the label width and the black background did not reach the full
        // width, a regression (real-device feedback round 11, 2026-07-16). Set it back to full width explicitly
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Real-device feedback round 14 (2026-07-16): the background band was removed entirely and made
        // transparent (the user's first choice).
        // The material (round 12) turned a muddy gray, and the black scrim (round 13) showed the band's border
        // line; both failed.
        // The text stands out with a black shadow inside segmentButton (same structure as TikTok = the band
        // border problem disappears by structure)
    }

    private func segmentButton(_ segment: Segment, title: String) -> some View {
        let isSelected = selectedSegment == segment
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSegment = segment
            }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.5))

                Rectangle()
                    .fill(isSelected ? Color.white : Color.clear)
                    .frame(width: 24, height: 2)
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
        }
    }

    // MARK: - Recommended

    @ViewBuilder
    private var recommendedContent: some View {
        if feedService.isLoadingRecommended && feedService.recommendedFeed.isEmpty {
            loadingView
        } else if feedService.recommendedFeed.isEmpty {
            emptyRecommendedView
        } else {
            FeedCardListView(
                items: feedService.recommendedFeed,
                recordsViews: false,  // Scrolling past posts on home is not a "tap" (prevents polluting post_views)
                onBlocked: { reloadBothFeeds() },
                // Skip the fetch on pull-down while the tab is being refreshed by a re-tap (isTabRefreshing)
                // (2026-08-04 review finding: without the guard, the same fetch runs twice in parallel,
                //  and with last-writer-wins the list looks like it is replaced twice. We are already fetching
                //  the same data anyway, so only show the spinner and do not send a second one)
                onRefresh: { if !isTabRefreshing { await feedService.loadRecommended() } },
                showsAds: true  // Ads only in the home feed (2026-07-31 ads v1)
            )
        }
    }

    // MARK: - Following

    @ViewBuilder
    private var followingContent: some View {
        if feedService.isLoadingFollowing && feedService.followingFeed.isEmpty {
            loadingView
        } else if feedService.followingFeed.isEmpty {
            emptyFollowingView
        } else {
            FeedCardListView(
                items: feedService.followingFeed,
                recordsViews: false,  // Scrolling past posts on home is not a "tap" (prevents polluting post_views)
                onBlocked: { reloadBothFeeds() },
                // Same double-fetch guard as the Recommended side (2026-08-04 review finding)
                onRefresh: { if !isTabRefreshing { await feedService.loadFollowing() } },
                showsAds: true  // Ads only in the home feed (2026-07-31 ads v1)
            )
        }
    }

    /// Re-fetch only the visible segment (for a tab re-tap).
    /// FeedService has no guard against concurrent runs, and the tab is easy to tap repeatedly, so taps are
    /// ignored while fetching.
    /// While fetching, isTabRefreshing shows the spinner (same look as pull-to-refresh).
    private func reloadCurrentSegment() {
        guard !isTabRefreshing else { return }
        let feedIsEmpty: Bool
        switch selectedSegment {
        case .recommended:
            guard !feedService.isLoadingRecommended else { return }
            feedIsEmpty = feedService.recommendedFeed.isEmpty
        case .following:
            guard !feedService.isLoadingFollowing else { return }
            feedIsEmpty = feedService.followingFeed.isEmpty
        }

        // Do not show the spinner under the bar when the feed is empty (2026-08-04 review finding:
        // isLoading && isEmpty shows the loadingView in the center, so showing both would make 2 spinners)
        isTabRefreshing = !feedIsEmpty
        // The fetch runs in an unstructured Task (same reason as refreshable in FeedCardListView:
        // avoids being canceled together with the URLSession when the view is rebuilt)
        Task {
            let started = Date()
            switch selectedSegment {
            case .recommended: await feedService.loadRecommended()
            case .following:   await feedService.loadFollowing()
            }
            // If the fetch is too fast, the spinner disappears like a blink, so show it for at least 0.6 seconds
            // (same idea as the 0.5 seconds on the refreshable side. A bit longer here because there is no wait
            // for the finger to lift)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.6 {
                try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000))
            }
            isTabRefreshing = false
        }
    }

    private func reloadBothFeeds() {
        Task {
            async let recommended: Void = feedService.loadRecommended()
            async let following: Void = feedService.loadFollowing()
            _ = await (recommended, following)
        }
    }

    // MARK: - Empty / Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white).scaleEffect(1.5)
            Text(L.feedLoading(lang))
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRecommendedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.white.opacity(0.4))
            Text(L.feedPostsEmpty(lang))
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFollowingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.white.opacity(0.4))
            Text(L.feedFollowingEmpty(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(L.feedFollowingEmptySubtitle(lang))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Tag Feed View (hashtag tap → mixed feed per tag)

struct TagFeedView: View {
    let tag: String
    let lang: AppLanguage
    let showOriginal: Bool

    @State private var items: [FeedItem] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(L.feedPostsEmpty(lang))
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FeedCardListView(
                    items: items,
                    recordsViews: false,  // The per-tag feed is also a scrolling list, not a tap on a post detail
                    onTagTapOverride: { _ in /* do nothing inside the tag feed */ },
                    onBlocked: {
                        let currentTag = tag
                        Task { items = await FeedService.shared.fetchTagFeed(tag: currentTag) }
                    }
                )
            }
        }
        .navigationTitle("#\(Quote.categoryDisplay(tag, lang: lang))")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            items = await FeedService.shared.fetchTagFeed(tag: tag)
            isLoading = false
        }
    }
}

#Preview {
    MixedFeedView()
}
