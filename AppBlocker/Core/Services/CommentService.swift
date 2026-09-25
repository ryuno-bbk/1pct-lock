//
//  CommentService.swift
//  AppBlocker
//
//  user_posts / quotes (公式名言) へのコメント取得 / 投稿 / いいね / 削除
//  post と quote は同じ user_comments テーブル (post_id / quote_id の XOR) を共有するため
//  CommentTarget で対象を切り替えて同じロジックを再利用する
//

import Foundation
import Combine
import Supabase

/// コメント機能の対象 (UGC 投稿 or 公式名言)
enum CommentTarget: Hashable {
    case post(UUID)
    case quote(UUID)

    var id: UUID {
        switch self {
        case .post(let id), .quote(let id): return id
        }
    }
}

@MainActor
final class CommentService: ObservableObject {

    static let shared = CommentService()

    /// target → コメント配列 (fetch_comments_for_post / fetch_comments_for_quote の結果。親 + 返信を平坦化済み)
    @Published private(set) var commentsByTarget: [CommentTarget: [UserComment]] = [:]
    @Published private(set) var loadingTargets: Set<CommentTarget> = []

    /// quote の comment_count は Quote 配列がローカル定数 (@Published でない画面) で保持されているため、
    /// FilteredQuoteFeedView / AuthorQuoteFeedView 側でその場 +1/-1 表示するための差分オーバーレイ
    @Published private(set) var quoteCommentCountDeltas: [UUID: Int] = [:]

    /// post 版の差分オーバーレイ (quoteCommentCountDeltas と同じ役割)。
    /// 現状 post は FeedService.recommendedFeed/followingFeed と UserPostService.myPosts/viewingPostsByUser
    /// 経由でしか表示されておらず、両方とも bumpLocalCommentCount が直接 patch する @Published 配列なので
    /// 実質 0 のまま推移するはずだが、将来 quote 同様の静的スナップショット経由の post 一覧が増えた時に
    /// 備えて対称に用意しておく (FeedListCard 側は baseline 差分でどちらの経路でも二重加算しない設計)
    @Published private(set) var postCommentCountDeltas: [UUID: Int] = [:]

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Fetch

    /// コメント一覧取得 (親 + 返信を平坦化、parent_comment_id でグループ化済み)
    func loadComments(target: CommentTarget, limit: Int = 200) async {
        loadingTargets.insert(target)
        defer { loadingTargets.remove(target) }

        do {
            let rows: [UserComment]
            switch target {
            case .post(let postId):
                rows = try await client
                    .rpc("fetch_comments_for_post", params: [
                        "target_post_id": AnyJSON.string(postId.uuidString),
                        "limit_count":    AnyJSON.integer(limit)
                    ])
                    .execute()
                    .value
            case .quote(let quoteId):
                rows = try await client
                    .rpc("fetch_comments_for_quote", params: [
                        "target_quote_id": AnyJSON.string(quoteId.uuidString),
                        "limit_count":     AnyJSON.integer(limit)
                    ])
                    .execute()
                    .value
            }
            commentsByTarget[target] = rows
        } catch {
            print("⚠️ Failed to load comments for \(target): \(error)")
        }
    }

    func comments(for target: CommentTarget) -> [UserComment] {
        commentsByTarget[target] ?? []
    }

    func isLoading(target: CommentTarget) -> Bool {
        loadingTargets.contains(target)
    }

    /// quote の comment_count に対するローカル差分 (FilteredQuoteFeedView 等が参照)
    func commentCountDelta(forQuote quoteId: UUID) -> Int {
        quoteCommentCountDeltas[quoteId] ?? 0
    }

    /// post の comment_count に対するローカル差分 (quoteCommentCountDeltas の post 版)
    func commentCountDelta(forPost postId: UUID) -> Int {
        postCommentCountDeltas[postId] ?? 0
    }

    // MARK: - Create

    /// コメント / 返信を作成 (create_comment / create_quote_comment RPC)
    /// parentCommentId 指定で返信。RPC 側で投稿者 + 親著者へ通知作成
    /// 戻り値: 失敗時 false
    /// 直近の createComment 失敗が 046 レート制限 (50件/24h) だったか (文言出し分け用)
    private(set) var lastCreateWasRateLimited = false

    func createComment(target: CommentTarget, text: String, parentCommentId: UUID? = nil) async -> Bool {
        guard UserAuthService.shared.userId != nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        lastCreateWasRateLimited = false

        do {
            switch target {
            case .post(let postId):
                var params: [String: AnyJSON] = [
                    "target_post_id": .string(postId.uuidString),
                    "comment_text":   .string(trimmed)
                ]
                if let parent = parentCommentId {
                    params["parent_comment_id_param"] = .string(parent.uuidString)
                }
                try await client.rpc("create_comment", params: params).execute()

            case .quote(let quoteId):
                var params: [String: AnyJSON] = [
                    "target_quote_id": .string(quoteId.uuidString),
                    "comment_text":    .string(trimmed)
                ]
                if let parent = parentCommentId {
                    params["parent_comment_id_param"] = .string(parent.uuidString)
                }
                try await client.rpc("create_quote_comment", params: params).execute()
            }

            // 再 fetch (最新の状態を取得、UI 反映が確実)
            await loadComments(target: target)
            // 該当 post/quote の comment_count をローカルでもインクリメント
            bumpLocalCommentCount(target: target, by: 1)
            return true
        } catch {
            print("⚠️ Failed to create comment: \(error)")
            // 046 レート制限。RAISE EXCEPTION の文言判定 (AppealService と同じパターン)
            if let pgError = error as? PostgrestError, pgError.message.contains("daily comment limit") {
                lastCreateWasRateLimited = true
            }
            return false
        }
    }

    // MARK: - Like

    /// コメントいいね/解除 (toggle_comment_like RPC)
    /// 楽観 UI 更新 + RPC 結果で確定
    /// viewerIsPostOwner: 呼び出し画面の閲覧者が投稿の作者なら true。
    /// その場合「投稿者がいいね」バッジ (isLikedByOwner) も自分のいいねに追従して即時反映する
    func toggleLike(commentId: UUID, target: CommentTarget, viewerIsPostOwner: Bool = false) async {
        guard UserAuthService.shared.userId != nil else { return }

        // 楽観 UI
        if var comments = commentsByTarget[target],
           let idx = comments.firstIndex(where: { $0.id == commentId }) {
            let current = comments[idx]
            let nextLiked = !current.isLikedByMe
            comments[idx] = patchedComment(
                from: current,
                isLikedByMe: nextLiked,
                likeCount: max(0, current.likeCount + (nextLiked ? 1 : -1)),
                isLikedByOwner: viewerIsPostOwner ? nextLiked : nil
            )
            commentsByTarget[target] = comments
        }

        struct ToggleResult: Decodable {
            let isLiked: Bool
            let likeCount: Int
            enum CodingKeys: String, CodingKey {
                case isLiked   = "is_liked"
                case likeCount = "like_count"
            }
        }

        do {
            let result: ToggleResult = try await client
                .rpc("toggle_comment_like", params: ["target_comment_id": commentId.uuidString])
                .execute()
                .value
            // RPC 結果で確定値を反映
            if var comments = commentsByTarget[target],
               let idx = comments.firstIndex(where: { $0.id == commentId }) {
                let current = comments[idx]
                comments[idx] = patchedComment(
                    from: current,
                    isLikedByMe: result.isLiked,
                    likeCount: result.likeCount,
                    isLikedByOwner: viewerIsPostOwner ? result.isLiked : nil
                )
                commentsByTarget[target] = comments
            }
        } catch {
            // ロールバック: 再 fetch
            print("⚠️ toggleCommentLike failed: \(error)")
            await loadComments(target: target)
        }
    }

    // MARK: - Delete (個別)

    /// 個別コメント削除 (自分のコメント or 投稿者なら可能、RLS で弾く)
    /// 親削除時は子返信も DB の ON DELETE CASCADE で消えるので、loadComments 後の
    /// 実際の差分でフィードカードのカウントを更新する
    func deleteComment(_ commentId: UUID, target: CommentTarget) async {
        let backup = commentsByTarget[target]
        let beforeCount = (commentsByTarget[target] ?? []).count

        // 楽観 UI
        if var comments = commentsByTarget[target] {
            comments.removeAll { $0.id == commentId || $0.parentCommentId == commentId }
            commentsByTarget[target] = comments
        }

        do {
            try await client
                .from("user_comments")
                .delete()
                .eq("id", value: commentId.uuidString)
                .execute()
            // 再 fetch して確定
            await loadComments(target: target)
            let afterCount = (commentsByTarget[target] ?? []).count
            let delta = afterCount - beforeCount  // 負の数 (削除)
            if delta != 0 {
                bumpLocalCommentCount(target: target, by: delta)
            }
        } catch {
            print("⚠️ deleteComment failed: \(error)")
            if let backup { commentsByTarget[target] = backup }
        }
    }

    /// 投稿者専用: 自分の投稿のコメント全消去 (post のみ。公式名言には「投稿者」がいないため対象外)
    @discardableResult
    func deleteAllComments(postId: UUID) async -> Int {
        let params: [String: AnyJSON] = [
            "target_post_id": .string(postId.uuidString)
        ]

        do {
            let count: Int = try await client
                .rpc("delete_all_comments_on_post", params: params)
                .execute()
                .value
            commentsByTarget[.post(postId)] = []
            if count > 0 {
                bumpLocalCommentCount(target: .post(postId), by: -count)
            }
            return count
        } catch {
            print("⚠️ deleteAllComments failed: \(error)")
            return 0
        }
    }

    // MARK: - Local Cache Helpers

    func clearComments(target: CommentTarget) {
        commentsByTarget[target] = nil
    }

    /// 投稿削除に伴うキャッシュクリア
    func purgePost(_ postId: UUID) {
        commentsByTarget.removeValue(forKey: .post(postId))
    }

    // MARK: - Helpers

    private func patchedComment(
        from original: UserComment,
        isLikedByMe: Bool,
        likeCount: Int,
        isLikedByOwner: Bool? = nil
    ) -> UserComment {
        UserComment(
            id: original.id,
            postId: original.postId,
            parentCommentId: original.parentCommentId,
            authorUserId: original.authorUserId,
            authorName: original.authorName,
            authorAvatarUrl: original.authorAvatarUrl,
            isProAuthor: original.isProAuthor,
            text: original.text,
            likeCount: likeCount,
            isLikedByMe: isLikedByMe,
            createdAt: original.createdAt,
            replyToName: original.replyToName,
            isLikedByOwner: isLikedByOwner ?? original.isLikedByOwner
        )
    }

    private func bumpLocalCommentCount(target: CommentTarget, by delta: Int) {
        switch target {
        case .post(let postId):
            FeedService.shared.adjustCommentCount(forPostId: postId, by: delta)
            UserPostService.shared.adjustCommentCount(forPostId: postId, by: delta)
            postCommentCountDeltas[postId] = (postCommentCountDeltas[postId] ?? 0) + delta
        case .quote(let quoteId):
            FeedService.shared.adjustCommentCount(forQuoteId: quoteId, by: delta)
            quoteCommentCountDeltas[quoteId] = (quoteCommentCountDeltas[quoteId] ?? 0) + delta
        }
    }
}
