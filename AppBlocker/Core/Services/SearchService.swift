//
//  SearchService.swift
//  AppBlocker
//
//  User search (search_users RPC). Stateless, so no ObservableObject is needed.
//

import Foundation
import Supabase

struct UserSearchResult: Identifiable, Decodable, Equatable {
    let id: UUID
    let displayName: String?
    let handle: String?
    let avatarUrl: String?
    let isPro: Bool
    /// Added in 083. Missing on older servers (083 not applied), so it is read with decodeIfPresent
    let isOfficial: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case handle
        case avatarUrl   = "avatar_url"
        case isPro       = "is_pro"
        case isOfficial  = "is_official"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        handle      = try c.decodeIfPresent(String.self, forKey: .handle)
        avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        isPro       = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        isOfficial  = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
    }
}

final class SearchService {

    static let shared = SearchService()

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// User search (@handle prefix match first + display_name partial match).
    /// Queries shorter than 2 characters return an empty array without hitting the server (prevents useless
    /// RPC calls).
    func searchUsers(query: String, limit: Int = 30) async -> [UserSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let params: [String: AnyJSON] = [
            "query":       .string(trimmed),
            "limit_count": .integer(limit)
        ]

        do {
            let results: [UserSearchResult] = try await client
                .rpc("search_users", params: params)
                .execute()
                .value
            return results
        } catch {
            print("⚠️ Failed to search users: \(error)")
            return []
        }
    }

    /// Post search (title partial match + tag prefix match). The search_posts RPC in 032_search_posts.sql.
    /// The return value has the same 17 columns as fetch_mixed_feed_random, so it decodes as FeedItem as is.
    /// Queries shorter than 1 character return an empty array without hitting the server (1-character
    /// Japanese searches are allowed).
    /// Stripping a leading '#' is done on the server side (inside search_posts), so the client only trims.
    func searchPosts(query: String, limit: Int = 30) async -> [FeedItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }

        let params: [String: AnyJSON] = [
            "query":       .string(trimmed),
            "limit_count": .integer(limit)
        ]

        do {
            let results: [FeedItem] = try await client
                .rpc("search_posts", params: params)
                .execute()
                .value
            return results
        } catch {
            print("⚠️ Failed to search posts: \(error)")
            return []
        }
    }
}
