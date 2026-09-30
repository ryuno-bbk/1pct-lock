//
//  BlockService.swift
//  AppBlocker
//
//  User block management service (Supabase user_blocks)
//

import Foundation
import Combine
import Supabase

@MainActor
final class BlockService: ObservableObject {

    static let shared = BlockService()

    @Published private(set) var blockedUserIds: Set<UUID> = []

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    func isBlocked(userId: UUID) -> Bool {
        blockedUserIds.contains(userId)
    }

    func block(userId: UUID) async {
        guard let me = UserAuthService.shared.userId else {
            print("⚠️ block ignored: not signed in")
            return
        }
        guard me != userId else {
            print("⚠️ Cannot block self")
            return
        }

        blockedUserIds.insert(userId)

        do {
            let row: [String: String] = [
                "blocker_id":      me.uuidString,
                "blocked_user_id": userId.uuidString
            ]
            try await client
                .from("user_blocks")
                .insert(row)
                .execute()

            // The trigger unfollow_on_block removed the follows in both directions, so
            // reload the follow state
            await FollowService.shared.loadFollowedAuthors()

            print("🚫 Blocked user: \(userId)")
        } catch {
            blockedUserIds.remove(userId)
            print("⚠️ block failed: \(error)")
        }
    }

    func unblock(userId: UUID) async {
        guard let me = UserAuthService.shared.userId else {
            print("⚠️ unblock ignored: not signed in")
            return
        }

        blockedUserIds.remove(userId)

        do {
            try await client
                .from("user_blocks")
                .delete()
                .eq("blocker_id",      value: me.uuidString)
                .eq("blocked_user_id", value: userId.uuidString)
                .execute()
            print("✅ Unblocked user: \(userId)")
        } catch {
            blockedUserIds.insert(userId)
            print("⚠️ unblock failed: \(error)")
        }
    }

    func loadMyBlocks() async {
        guard let me = UserAuthService.shared.userId else {
            blockedUserIds = []
            return
        }

        do {
            struct BlockRow: Decodable {
                let blockedUserId: UUID
                enum CodingKeys: String, CodingKey { case blockedUserId = "blocked_user_id" }
            }

            let rows: [BlockRow] = try await client
                .from("user_blocks")
                .select("blocked_user_id")
                .eq("blocker_id", value: me.uuidString)
                .execute()
                .value

            blockedUserIds = Set(rows.map { $0.blockedUserId })
            print("🚫 Loaded \(blockedUserIds.count) blocked users")
        } catch {
            print("⚠️ Failed to load blocks: \(error)")
        }
    }

    /// Fetch display_name / avatar_url of blocked users (for BlockedAccountsView)
    func fetchBlockedUsers() async -> [BlockedUser] {
        guard !blockedUserIds.isEmpty else { return [] }

        do {
            struct UserRow: Decodable {
                let id: UUID
                let displayName: String?
                let avatarUrl: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                    case avatarUrl   = "avatar_url"
                }
            }

            let rows: [UserRow] = try await client
                .from("users")
                .select("id, display_name, avatar_url")
                .in("id", values: blockedUserIds.map { $0.uuidString })
                .execute()
                .value

            return rows.map { BlockedUser(id: $0.id, displayName: $0.displayName, avatarUrl: $0.avatarUrl) }
        } catch {
            print("⚠️ Failed to fetch blocked users: \(error)")
            return []
        }
    }
}

struct BlockedUser: Identifiable, Hashable {
    let id: UUID
    let displayName: String?
    let avatarUrl: String?
}
