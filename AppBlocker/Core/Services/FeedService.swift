//
//  FeedService.swift
//  AppBlocker
//
//  混在フィード (公式 quotes + UGC user_posts) の取得
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
    /// 直近の取得失敗 (2026-07-31): 以前は catch で print するだけだったため、
    /// 引き下げ更新がサーバーエラーで空振りしても画面上は「何も起きない」ようにしか見えず、
    /// 原因の切り分けに何往復もかかった。失敗は必ず画面に出す
    @Published private(set) var lastFeedError: String?

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - クリア (M20: アカウント切替/サインアウト時の残留防止)

    /// サインアウト/アカウント切替時に両フィードキャッシュを破棄する。
    /// これを呼ばないと、別アカウントで再サインインした直後に前ユーザー視点の
    /// おすすめ/フォロー中フィードが一瞬 (再ロード完了まで) 残留表示されてしまう。
    func clear() {
        recommendedFeed = []
        followingFeed = []
    }

    // MARK: - おすすめフィード (公式 + UGC ランダム混在)

    /// おすすめフィードを取得する。
    /// 2026-07-31: 並びの種 (seed) を毎回新しく作って渡す (063 SQL)。
    /// 以前はサーバーの random() 任せで、引き下げ更新しても並びが変わらないことがあった
    /// (STABLE 宣言の関数内で random() を使っていたためプランが再利用され得た)。
    /// 呼ぶたびに seed が変わる = 並びが必ず変わることをアプリ側で保証する
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

    /// 画面に出す用の短い文言。生の NSError ダンプは長すぎて画面を覆うので出さない。
    /// キャンセル (-999) は「取得が中断されただけ」でユーザーの操作起因ではないため表示しない
    /// (2026-07-31: refreshable のタスクキャンセルが原因の中断は非構造化 Task 化で解消済み)
    private static func userFacingMessage(for error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
                return "接続できませんでした。通信環境を確認してください" // 文言はユーザー添削待ち
            default:
                break
            }
        }
        return "フィードを更新できませんでした" // 文言はユーザー添削待ち
    }

    // MARK: - フォロー中フィード (フォロー対象の公式 + UGC、新着順)

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

    // MARK: - コメント数の楽観更新

    /// 指定 post に対する recommended / following 両キャッシュの comment_count を増減
    /// CommentService からコメント作成/削除時に呼ばれる
    func adjustCommentCount(forPostId postId: UUID, by delta: Int) {
        adjustCommentCount(kind: .post, itemId: postId, by: delta)
    }

    /// 指定 quote (公式名言) に対する recommended / following 両キャッシュの comment_count を増減
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

    // MARK: - タグフィード (ハッシュタグタップ用、公式 + UGC 混在ランダム)

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
