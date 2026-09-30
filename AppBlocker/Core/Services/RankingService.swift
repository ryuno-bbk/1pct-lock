//
//  RankingService.swift
//  AppBlocker
//
//  Ranking by total lock time (get_block_ranking in 082_block_ranking.sql)
//
//  🔴 No weekly ranking (user decision 2026-09-05).
//     With 2 rankings it becomes unclear "which one is my rank". Only the all-time one.
//
//  ⚠️ There is no anti-cheat (user decision). block_sessions is reported by the device, so
//     the ranking is not robust against tampering. Reconsider when adding features that make the
//     rank more prominent.
//

import Foundation
import Combine
import Supabase

/// One ranking row
struct BlockRankingRow: Decodable, Equatable, Identifiable {
    let rank: Int
    let userId: UUID
    let handle: String?
    let displayName: String?
    let avatarUrl: String?
    let isPro: Bool
    let isOfficial: Bool
    let totalSeconds: Int
    /// Whether this is your own row (compared with auth.uid() on the server)
    let isMe: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case rank
        case userId       = "user_id"
        case handle
        case displayName  = "display_name"
        case avatarUrl    = "avatar_url"
        case isPro        = "is_pro"
        case isOfficial   = "is_official"
        case totalSeconds = "total_seconds"
        case isMe         = "is_me"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank         = try c.decode(Int.self, forKey: .rank)
        userId       = try c.decode(UUID.self, forKey: .userId)
        handle       = try c.decodeIfPresent(String.self, forKey: .handle)
        displayName  = try c.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl    = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        isPro        = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        isOfficial   = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        totalSeconds = try c.decodeIfPresent(Int.self, forKey: .totalSeconds) ?? 0
        isMe         = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
    }
}

/// Return value of get_block_ranking
struct BlockRanking: Decodable, Equatable {
    /// Pool = all real users (including people with 0 seconds / excluding seed accounts)
    let totalUsers: Int
    /// Number of people actually listed (top 10%. At least 10)
    let shown: Int
    let rows: [BlockRankingRow]

    enum CodingKeys: String, CodingKey {
        case totalUsers = "total_users"
        case shown, rows
    }
}

@MainActor
final class RankingService: ObservableObject {

    static let shared = RankingService()

    @Published private(set) var ranking: BlockRanking?
    @Published private(set) var isLoading = false
    /// Whether the fetch failed. The screen shows "not available yet" and "network failure" differently
    @Published private(set) var loadFailed = false

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    func load() async {
        guard UserAuthService.shared.userId != nil else {
            ranking = nil
            return
        }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        do {
            ranking = try await client
                .rpc("get_block_ranking", params: ["p_limit": AnyJSON.integer(50)])
                .execute()
                .value
        } catch {
            // Do not crash even on a DB without 082 applied
            print("⚠️ Failed to load ranking: \(error)")
            loadFailed = true
        }
    }

    /// Do not carry it over after sign-out
    func clear() {
        ranking = nil
        loadFailed = false
    }
}
