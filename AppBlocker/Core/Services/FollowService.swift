//
//  FollowService.swift
//  AppBlocker
//
//  Service for managing follows of great figures (Supabase)
//

import Foundation
import Combine
import Supabase

/// Manages follow/unfollow of great figures
final class FollowService: ObservableObject {

    static let shared = FollowService()

    // MARK: - Published Properties

    @Published private(set) var followedAuthorIds: Set<UUID> = []
    @Published private(set) var followedUserIds: Set<UUID> = []

    // MARK: - Private Properties

    private let client: SupabaseClient

    // MARK: - Init

    private init(
        client: SupabaseClient = SupabaseManager.shared.client
    ) {
        self.client = client
    }

    // MARK: - Public Methods

    /// Check the follow state
    func isFollowing(authorId: UUID) -> Bool {
        followedAuthorIds.contains(authorId)
    }

    /// Toggle follow/unfollow
    func toggleFollow(authorId: UUID) async {
        if isFollowing(authorId: authorId) {
            await unfollow(authorId: authorId)
        } else {
            await follow(authorId: authorId)
        }
    }

    /// Follow a great figure
    @MainActor
    func follow(authorId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ Follow ignored: not signed in")
            return
        }

        // Optimistic UI update
        followedAuthorIds.insert(authorId)

        do {
            let row: [String: String] = [
                "follower_id": followerId.uuidString,
                "author_id": authorId.uuidString
            ]
            try await client
                .from("user_follows")
                .insert(row)
                .execute()

            print("✅ Followed author: \(authorId)")
        } catch {
            // On failure, roll back
            followedAuthorIds.remove(authorId)
            print("⚠️ Follow failed: \(error)")
        }
    }

    /// Unfollow a great figure
    @MainActor
    func unfollow(authorId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ Unfollow ignored: not signed in")
            return
        }

        // Optimistic UI update
        followedAuthorIds.remove(authorId)

        do {
            try await client
                .from("user_follows")
                .delete()
                .eq("follower_id", value: followerId.uuidString)
                .eq("author_id", value: authorId.uuidString)
                .execute()

            print("✅ Unfollowed author: \(authorId)")
        } catch {
            // On failure, roll back
            followedAuthorIds.insert(authorId)
            print("⚠️ Unfollow failed: \(error)")
        }
    }

    /// Load the follow list at launch (both great figures + regular users)
    @MainActor
    func loadFollowedAuthors() async {
        guard let followerId = UserAuthService.shared.userId else {
            followedAuthorIds = []
            followedUserIds = []
            return
        }

        do {
            struct FollowRow: Decodable {
                let authorId: UUID?
                let followedUserId: UUID?

                enum CodingKeys: String, CodingKey {
                    case authorId       = "author_id"
                    case followedUserId = "followed_user_id"
                }
            }

            let rows: [FollowRow] = try await client
                .from("user_follows")
                .select("author_id, followed_user_id")
                .eq("follower_id", value: followerId.uuidString)
                .execute()
                .value

            followedAuthorIds = Set(rows.compactMap { $0.authorId })
            followedUserIds = Set(rows.compactMap { $0.followedUserId })
            print("📚 Loaded \(followedAuthorIds.count) followed authors, \(followedUserIds.count) followed users")
        } catch {
            print("⚠️ Failed to load follows: \(error)")
        }
    }

    // MARK: - Follows between users (UGC posters)

    func isFollowingUser(userId: UUID) -> Bool {
        followedUserIds.contains(userId)
    }

    /// Whether the other user follows you (for the mutual follow display, 058 RPC is_following_me).
    /// RLS does not allow reading other people's rows in user_follows, so it goes through an RPC. false
    /// if 058 is not applied / on failure (fail-soft: the display just falls back to the normal
    /// "フォロー中" ("Following"))
    func isFollowedBy(userId: UUID) async -> Bool {
        do {
            // params are passed as a dictionary (with a custom struct, its Encodable conformance under the
            // default MainActor isolation cannot meet the Sendable requirement and fails to compile. The stdlib
            // dictionary conformance is nonisolated)
            let result: Bool = try await client
                .rpc("is_following_me", params: ["p_user_id": userId.uuidString])
                .execute()
                .value
            return result
        } catch {
            print("⚠️ is_following_me failed: \(error)")
            return false
        }
    }

    func toggleUserFollow(userId: UUID) async {
        if isFollowingUser(userId: userId) {
            await unfollowUser(userId: userId)
        } else {
            await followUser(userId: userId)
        }
    }

    @MainActor
    func followUser(userId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ FollowUser ignored: not signed in")
            return
        }
        guard followerId != userId else {
            print("⚠️ Cannot follow self")
            return
        }

        followedUserIds.insert(userId)

        do {
            let row: [String: String] = [
                "follower_id":      followerId.uuidString,
                "followed_user_id": userId.uuidString
            ]
            try await client
                .from("user_follows")
                .insert(row)
                .execute()
            print("✅ Followed user: \(userId)")
        } catch {
            followedUserIds.remove(userId)
            print("⚠️ FollowUser failed: \(error)")
        }
    }

    @MainActor
    func unfollowUser(userId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ UnfollowUser ignored: not signed in")
            return
        }

        followedUserIds.remove(userId)

        do {
            try await client
                .from("user_follows")
                .delete()
                .eq("follower_id",      value: followerId.uuidString)
                .eq("followed_user_id", value: userId.uuidString)
                .execute()
            print("✅ Unfollowed user: \(userId)")
        } catch {
            followedUserIds.insert(userId)
            print("⚠️ UnfollowUser failed: \(error)")
        }
    }

    /// Get the list of followed great figures
    func getFollowedAuthors() async -> [Author] {
        guard !followedAuthorIds.isEmpty else { return [] }

        do {
            let authors: [Author] = try await client
                .from("authors")
                .select()
                .in("id", values: followedAuthorIds.map { $0.uuidString })
                .execute()
                .value

            return authors
        } catch {
            print("⚠️ Failed to fetch followed authors: \(error)")
            return []
        }
    }
}
