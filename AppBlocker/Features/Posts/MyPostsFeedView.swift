//
//  MyPostsFeedView.swift
//  AppBlocker
//
//  Post detail feed opened by tapping the profile grid (shared by own/other users).
//  2026-07-10 BeReal-style rework: full-screen TikTok scroll → FeedCardListView (4:5 card list).
//  Each time a post is shown, a view is counted by record_post_view (on the FeedCardListView side).
//

import SwiftUI

struct MyPostsFeedView: View {
    let posts: [UserPost]
    let startIndex: Int
    /// Poster name (falls back to auth.displayName if nil)
    var authorDisplayName: String? = nil
    /// Poster avatar URL
    var authorAvatarUrl: String? = nil
    /// Poster is_pro (Pro badge display)
    var authorIsPro: Bool = false
    /// Whether to show the delete menu (= true only for your own post feed)
    var canDelete: Bool = true

    @ObservedObject private var auth = UserAuthService.shared

    /// 🔴 Must not fall back to auth.displayName when it is not your own feed.
    ///    It turns "poster unknown" into "you are the poster", and your name appears on other people's
    ///    posts (actually happened via a notification on 2026-08-28).
    ///    If nothing is passed, leave it nil (the card shows the em dash placeholder)
    private var resolvedAuthorName: String? {
        canDelete ? (auth.displayName ?? authorDisplayName) : authorDisplayName
    }

    private var resolvedAvatarUrl: String? {
        canDelete ? (auth.avatarUrl?.absoluteString ?? authorAvatarUrl) : authorAvatarUrl
    }

    private var resolvedIsPro: Bool {
        canDelete ? auth.isPro : authorIsPro
    }

    private var items: [FeedItem] {
        posts.map {
            $0.toFeedItem(
                authorName: resolvedAuthorName,
                avatarUrl: resolvedAvatarUrl,
                isProAuthor: resolvedIsPro
            )
        }
    }

    /// IDs of posts rejected by AI moderation (layer 1 safety NG). A badge + appeal path are shown only
    /// in the user's own post list.
    /// In the old spec, flagged (layer 2 ethos NG) was "show nothing (to preserve the shadow behavior)",
    /// but 039_moderation_notifications_appeals.sql changed the policy to notify the user, so
    /// flagged is also made visible to the user (see flaggedIds. The post itself stays visible and a
    /// top banner tells them)
    private var rejectedIds: Set<UUID> {
        guard canDelete else { return [] }
        return Set(posts.filter { $0.moderationStatus == "rejected" }.map { $0.id })
    }

    /// IDs of posts flagged by AI moderation (layer 2 ethos NG). From 039 on, the policy is to show the
    /// user a notification + top banner + appeal path (old: nothing was shown, for the shadow purpose)
    private var flaggedIds: Set<UUID> {
        guard canDelete else { return [] }
        return Set(posts.filter { $0.moderationStatus == "flagged" }.map { $0.id })
    }

    var body: some View {
        let items = self.items
        FeedCardListView(
            items: items,
            recordsViews: true,  // Post detail opened by tapping the profile grid = a real tap count
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            canDeletePosts: canDelete,
            rejectedPostIds: rejectedIds,
            flaggedPostIds: flaggedIds
        )
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 Remove the black header background so only the back button floats over the content
        //    (same look as My Page. User instruction 2026-08-29).
        //    ⚠️ Screens pushed onto this NavigationStack must have these 3 lines
        //    (project_en_screenshots_and_nav_bugs_2026_08_04)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Real device feedback #6: measured correction for the inset collapse (see SafeAreaCollapseFix.swift)
        .safeAreaCollapseFix()
    }
}
