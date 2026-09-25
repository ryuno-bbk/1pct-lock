//
//  SearchService.swift
//  AppBlocker
//
//  ユーザー検索 (search_users RPC)。ステートレスなので ObservableObject は不要。
//

import Foundation
import Supabase

struct UserSearchResult: Identifiable, Decodable, Equatable {
    let id: UUID
    let displayName: String?
    let handle: String?
    let avatarUrl: String?
    let isPro: Bool
    /// 083 で追加。旧サーバー (083 未適用) では欠けるので decodeIfPresent で受ける
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

    /// ユーザー検索 (@handle 前方一致優先 + display_name 部分一致)。
    /// 2 文字未満のクエリはサーバーを叩かずに空配列を返す (無駄な RPC 呼び出し防止)。
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

    /// 投稿検索 (タイトル部分一致 + タグ前方一致)。032_search_posts.sql の search_posts RPC。
    /// 戻り値は fetch_mixed_feed_random と同じ17列なので FeedItem をそのままデコードできる。
    /// 1文字未満のクエリはサーバーを叩かずに空配列を返す (日本語の1文字検索は許容する)。
    /// 先頭の '#' 除去はサーバー側 (search_posts 内) で行うのでクライアントは trim のみ。
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
