//
//  FollowService.swift
//  AppBlocker
//
//  偉人フォロー管理サービス（Supabase）
//

import Foundation
import Combine
import Supabase

/// 偉人のフォロー/アンフォロー管理
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

    /// フォロー状態を確認
    func isFollowing(authorId: UUID) -> Bool {
        followedAuthorIds.contains(authorId)
    }

    /// フォロー/アンフォロー切り替え
    func toggleFollow(authorId: UUID) async {
        if isFollowing(authorId: authorId) {
            await unfollow(authorId: authorId)
        } else {
            await follow(authorId: authorId)
        }
    }

    /// 偉人をフォロー
    @MainActor
    func follow(authorId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ Follow ignored: not signed in")
            return
        }

        // 楽観的UI更新
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
            // 失敗時はロールバック
            followedAuthorIds.remove(authorId)
            print("⚠️ Follow failed: \(error)")
        }
    }

    /// 偉人をアンフォロー
    @MainActor
    func unfollow(authorId: UUID) async {
        guard let followerId = UserAuthService.shared.userId else {
            print("⚠️ Unfollow ignored: not signed in")
            return
        }

        // 楽観的UI更新
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
            // 失敗時はロールバック
            followedAuthorIds.insert(authorId)
            print("⚠️ Unfollow failed: \(error)")
        }
    }

    /// 起動時にフォロー一覧を読み込み (偉人 + 一般ユーザー両方)
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

    // MARK: - ユーザー間フォロー (UGC 投稿者)

    func isFollowingUser(userId: UUID) -> Bool {
        followedUserIds.contains(userId)
    }

    /// 相手が自分をフォローしているか (相互フォロー表示用、058 RPC is_following_me)。
    /// RLS で user_follows の他人行は読めないため RPC 経由。058 未適用/失敗時は false
    /// (表示が通常の「フォロー中」に落ちるだけの fail-soft)
    func isFollowedBy(userId: UUID) async -> Bool {
        do {
            // params は辞書で渡す (独自 struct だとデフォルト MainActor 分離の Encodable 準拠が
            // Sendable 要件を満たせずコンパイルエラーになる。stdlib の辞書準拠は nonisolated)
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

    /// フォロー中の偉人一覧を取得
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
