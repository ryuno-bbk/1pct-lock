//
//  RankingService.swift
//  AppBlocker
//
//  累計ロック時間のランキング (082_block_ranking.sql の get_block_ranking)
//
//  🔴 週次ランキングは作らない (2026-09-05 ユーザー決定)。
//     ランキングが2つあると「どっちが自分の順位か」が分からなくなる。累計1本だけ。
//
//  ⚠️ チート対策は入っていない (ユーザー判断)。block_sessions は端末申告なので
//     順位は改ざんに強くない。順位をさらに強く見せる機能を足すときは再検討すること。
//

import Foundation
import Combine
import Supabase

/// ランキング1行
struct BlockRankingRow: Decodable, Equatable, Identifiable {
    let rank: Int
    let userId: UUID
    let handle: String?
    let displayName: String?
    let avatarUrl: String?
    let isPro: Bool
    let isOfficial: Bool
    let totalSeconds: Int
    /// 自分の行かどうか (サーバー側で auth.uid() と比較済み)
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

/// get_block_ranking の戻り値
struct BlockRanking: Decodable, Equatable {
    /// 母数 = 全実ユーザー (0秒の人も含む / 種アカは除く)
    let totalUsers: Int
    /// 実際に掲載している人数 (上位10%。最低10人)
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
    /// 取得に失敗したか。画面は「まだ出せません」と「通信失敗」を出し分ける
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
            // 082 未適用の DB でもクラッシュさせない
            print("⚠️ Failed to load ranking: \(error)")
            loadFailed = true
        }
    }

    /// サインアウト時に持ち越さない
    func clear() {
        ranking = nil
        loadFailed = false
    }
}
