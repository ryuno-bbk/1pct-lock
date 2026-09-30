//
//  FeedExtrasService.swift
//  AppBlocker
//
//  Extra info for the BeReal-style feed card (028 SQL):
//    - ≤3 people who liked it (avatar stack at the bottom left of the image)
//    - ≤3 comment previews (bottom of the card)
//    - Counting views of post details (record_post_view)
//  After the feed loads, fetch in one round trip as a batch with fetch_feed_extras, and
//  cache in a dictionary keyed by FeedItem.id ("kind-uuid").
//

import Foundation
import Combine
import Supabase

/// One row of fetch_feed_extras (likers / comments are jsonb arrays)
struct FeedExtras: Decodable {
    let kind: FeedItem.Kind
    let itemId: UUID
    let likers: [FeedLiker]
    let comments: [FeedCommentPreview]

    enum CodingKeys: String, CodingKey {
        case kind
        case itemId = "item_id"
        case likers
        case comments
    }

    /// Same key format as FeedItem.id
    var key: String { "\(kind.rawValue)-\(itemId.uuidString)" }
}

struct FeedLiker: Decodable, Identifiable, Equatable {
    let userId: UUID
    let displayName: String?
    let avatarUrl: String?
    /// Returned only by fetch_likers (030, list). nil in fetch_feed_extras (≤3 stack)
    var isPro: Bool? = nil

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case isPro       = "is_pro"
    }
}

struct FeedCommentPreview: Decodable, Identifiable, Equatable {
    let id: UUID
    let authorName: String?
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case authorName = "author_name"
        case text
    }
}

@MainActor
final class FeedExtrasService: ObservableObject {

    static let shared = FeedExtrasService()

    /// FeedItem.id ("kind-uuid") → extras
    @Published private(set) var extras: [String: FeedExtras] = [:]

    /// FeedItem.id → time of the last batch fetch (for the TTL check. Skip refetching if it is under
    /// extrasTTL)
    private var fetchedAt: [String: Date] = [:]

    /// How long the cache is valid. The same key is not refetched within this many seconds
    /// (prevents .task from firing the same batch every time FeedCardListView is remounted by quickly
    /// toggling Recommended ⇄ Following. Fixed 2026-07)
    private let extrasTTL: TimeInterval = 60

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    func extras(for item: FeedItem) -> FeedExtras? {
        extras[item.id]
    }

    /// Invalidate only the TTL cache of the given key (does not delete the extras contents themselves.
    /// Showing the old value until the next loadExtras refetches it does no real harm, so only the
    /// "should refetch" mark = fetchedAt is removed).
    /// Because of the project-wide rule that your own like/comment actions should show up immediately
    /// everywhere without waiting for the TTL (60 seconds), only that key is pinpointed for refetch (F6)
    func invalidate(key: String) {
        fetchedAt.removeValue(forKey: key)
    }

    // MARK: - Batch fetch

    /// Call after the feed loads. By default, items already fetched within `extrasTTL` seconds are
    /// skipped and only unfetched keys are fetched. Passing `force: true` ignores the TTL and refetches
    /// everything (used for a real reload where like/comment changes must be picked up. Example:
    /// replacing items after pull-to-refresh)
    func loadExtras(for items: [FeedItem], force: Bool = false) async {
        guard !items.isEmpty else { return }

        let now = Date()
        let targets = force ? items : items.filter { item in
            guard let last = fetchedAt[item.id] else { return true }
            return now.timeIntervalSince(last) >= extrasTTL
        }
        guard !targets.isEmpty else { return }

        let postIds  = targets.filter { $0.kind == .post  }.map { $0.itemId.uuidString }
        let quoteIds = targets.filter { $0.kind == .quote }.map { $0.itemId.uuidString }

        let params: [String: AnyJSON] = [
            "post_ids":  .array(postIds.map  { .string($0) }),
            "quote_ids": .array(quoteIds.map { .string($0) })
        ]

        do {
            let rows: [FeedExtras] = try await client
                .rpc("fetch_feed_extras", params: params)
                .execute()
                .value
            for row in rows {
                extras[row.key] = row
            }
            // Record fetchedAt for every requested key (recorded regardless of whether a row came back, so that
            // items with 0 likes/comments that return no row are not retried every time)
            for item in targets {
                fetchedAt[item.id] = now
            }
            // fetchedAt keeps growing as long as the user keeps scrolling while the app is running (the only
            // path that removes keys is roughly invalidate(key:)). Put a cap on it so it does not grow without
            // limit, and when it is exceeded, thin out the ~100 oldest (a granularity that does not affect the
            // latest cache checks)
            if fetchedAt.count > 500 {
                let sortedByAge = fetchedAt.sorted { $0.value < $1.value }
                for (key, _) in sortedByAge.prefix(100) {
                    fetchedAt.removeValue(forKey: key)
                }
            }
        } catch {
            print("⚠️ Failed to load feed extras: \(error)")
        }
    }

    // MARK: - List of people who liked it (030 fetch_likers, fetched on demand when the stack is tapped)

    func fetchLikers(for item: FeedItem, limit: Int = 200) async -> [FeedLiker] {
        let params: [String: AnyJSON] = [
            "target_kind": .string(item.kind.rawValue),
            "target_id":   .string(item.itemId.uuidString),
            "limit_count": .integer(limit)
        ]
        do {
            let likers: [FeedLiker] = try await client
                .rpc("fetch_likers", params: params)
                .execute()
                .value
            return likers
        } catch {
            print("⚠️ Failed to fetch likers: \(error)")
            return []
        }
    }

    // MARK: - View counting

    /// Call when a post is shown in post details (card list).
    /// To avoid double counting, the same post is sent only once per session
    /// (the DB side also ignores self-views)
    private var recordedThisSession: Set<UUID> = []

    func recordPostView(postId: UUID) {
        guard !recordedThisSession.contains(postId) else { return }
        recordedThisSession.insert(postId)

        Task {
            do {
                try await client
                    .rpc("record_post_view", params: ["target_post_id": AnyJSON.string(postId.uuidString)])
                    .execute()
            } catch {
                // Best effort: do not block the UI even on failure. Leave the id in the set
                // (removing it would resend on every onAppear re-fire of LazyVStack, and when offline
                // it would become an endless retry storm of failing RPCs, so try only once per session)
                print("⚠️ Failed to record post view: \(error)")
            }
        }
    }
}
