//
//  FeedService.swift
//  AppBlocker
//
//  Fetching the mixed feed (official quotes + UGC user_posts)
//  RPC: fetch_mixed_feed_random / fetch_following_feed / fetch_tag_feed
//

import Foundation
import Combine
import Supabase

@MainActor
final class FeedService: ObservableObject {

    static let shared = FeedService()

    @Published private(set) var recommendedFeed: [FeedItem] = []
    @Published private(set) var followingFeed: [FeedItem] = []
    @Published private(set) var isLoadingRecommended: Bool = false
    @Published private(set) var isLoadingFollowing: Bool = false
    /// Most recent fetch failure (2026-07-31): previously the catch only printed, so even when
    /// pull-to-refresh failed with a server error, on screen it only looked like "nothing happens", and
    /// isolating the cause took many round trips. Failures are always shown on screen
    @Published private(set) var lastFeedError: String?

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Clear (M20: prevents leftovers on account switch/sign-out)

    /// Discard both feed caches on sign-out/account switch.
    /// Without this, right after signing in again with another account, the previous user's
    /// Recommended/Following feeds stay visible for a moment (until the reload finishes).
    func clear() {
        recommendedFeed = []
        followingFeed = []
    }

    // MARK: - Recommended feed (official + UGC randomly mixed)

    /// Fetch the Recommended feed.
    /// 2026-07-31: create and pass a new order seed every time (063 SQL).
    /// Previously it relied on the server's random(), and the order sometimes did not change on
    /// pull-to-refresh (random() was used inside a function declared STABLE, so the plan could be reused).
    /// A different seed on every call = the app side guarantees that the order always changes
    func loadRecommended(limit: Int = 50) async {
        isLoadingRecommended = true
        defer { isLoadingRecommended = false }

        let params: [String: AnyJSON] = [
            "limit_count": .integer(limit),
            "seed": .string(UUID().uuidString)
        ]

        do {
            let items: [FeedItem] = try await client
                .rpc("fetch_mixed_feed_random", params: params)
                .execute()
                .value
            recommendedFeed = items
            lastFeedError = nil
            print("📚 Loaded \(items.count) recommended feed items")
        } catch {
            lastFeedError = Self.userFacingMessage(for: error)
            print("⚠️ Failed to load recommended feed: \(error)")
        }
    }

    func clearFeedError() {
        lastFeedError = nil
    }

    /// Short text for showing on screen. A raw NSError dump is too long and covers the screen, so it is not
    /// shown. Cancel (-999) means "the fetch was just interrupted" and is not caused by the user's action,
    /// so it is not shown
    /// (2026-07-31: interruptions caused by refreshable's task cancellation were fixed by moving to an
    /// unstructured Task)
    private static func userFacingMessage(for error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
                return "接続できませんでした。通信環境を確認してください" // Text waiting for user review
            default:
                break
            }
        }
        return "フィードを更新できませんでした" // Text waiting for user review
    }

    // MARK: - Following feed (official + UGC from followed accounts, newest first)

    func loadFollowing(limit: Int = 50) async {
        isLoadingFollowing = true
        defer { isLoadingFollowing = false }

        let params: [String: AnyJSON] = [
            "limit_count": .integer(limit)
        ]

        do {
            let items: [FeedItem] = try await client
                .rpc("fetch_following_feed", params: params)
                .execute()
                .value
            followingFeed = items
            lastFeedError = nil
            print("📚 Loaded \(items.count) following feed items")
        } catch {
            lastFeedError = Self.userFacingMessage(for: error)
            print("⚠️ Failed to load following feed: \(error)")
        }
    }

    // MARK: - Optimistic update of the comment count

    /// Increase/decrease comment_count in both the recommended / following caches for the given post
    /// Called from CommentService when a comment is created/deleted
    func adjustCommentCount(forPostId postId: UUID, by delta: Int) {
        adjustCommentCount(kind: .post, itemId: postId, by: delta)
    }

    /// Increase/decrease comment_count in both the recommended / following caches for the given quote
    /// (official quote)
    func adjustCommentCount(forQuoteId quoteId: UUID, by delta: Int) {
        adjustCommentCount(kind: .quote, itemId: quoteId, by: delta)
    }

    private func adjustCommentCount(kind: FeedItem.Kind, itemId: UUID, by delta: Int) {
        recommendedFeed = recommendedFeed.map { item in
            (item.kind == kind && item.itemId == itemId)
                ? replaceCommentCount(item, with: max(0, item.commentCount + delta))
                : item
        }
        followingFeed = followingFeed.map { item in
            (item.kind == kind && item.itemId == itemId)
                ? replaceCommentCount(item, with: max(0, item.commentCount + delta))
                : item
        }
    }

    private func replaceCommentCount(_ item: FeedItem, with newCount: Int) -> FeedItem {
        FeedItem(
            kind: item.kind,
            itemId: item.itemId,
            bodyJp: item.bodyJp,
            bodyEn: item.bodyEn,
            tags: item.tags,
            likeCount: item.likeCount,
            commentCount: newCount,
            createdAt: item.createdAt,
            authorId: item.authorId,
            authorName: item.authorName,
            authorAvatarUrl: item.authorAvatarUrl,
            isOfficialAuthor: item.isOfficialAuthor,
            isProAuthor: item.isProAuthor,
            backgroundId: item.backgroundId,
            title: item.title,
            imagePath: item.imagePath,
            imageCount: item.imageCount
        )
    }

    // MARK: - Tag feed (for hashtag taps, official + UGC mixed at random)

    func fetchTagFeed(tag: String, limit: Int = 50) async -> [FeedItem] {
        let params: [String: AnyJSON] = [
            "target_tag": .string(tag),
            "limit_count": .integer(limit)
        ]

        do {
            let items: [FeedItem] = try await client
                .rpc("fetch_tag_feed", params: params)
                .execute()
                .value
            return items
        } catch {
            print("⚠️ Failed to fetch tag feed: \(error)")
            return []
        }
    }
}
