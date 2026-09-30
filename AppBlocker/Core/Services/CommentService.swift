//
//  CommentService.swift
//  AppBlocker
//
//  Fetching / posting / liking / deleting comments on user_posts / quotes (official quotes)
//  post and quote share the same user_comments table (XOR of post_id / quote_id), so
//  CommentTarget switches the target and the same logic is reused
//

import Foundation
import Combine
import Supabase

/// Target of the comment feature (UGC post or official quote)
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

    /// target → comment array (result of fetch_comments_for_post / fetch_comments_for_quote. Parents +
    /// replies already flattened)
    @Published private(set) var commentsByTarget: [CommentTarget: [UserComment]] = [:]
    @Published private(set) var loadingTargets: Set<CommentTarget> = []

    /// For quotes, comment_count is held in a Quote array that is a local constant (on screens where it is
    /// not @Published), so this is a delta overlay to show +1/-1 on the spot in
    /// FilteredQuoteFeedView / AuthorQuoteFeedView
    @Published private(set) var quoteCommentCountDeltas: [UUID: Int] = [:]

    /// Delta overlay for posts (same role as quoteCommentCountDeltas).
    /// Currently posts are only shown through FeedService.recommendedFeed/followingFeed and
    /// UserPostService.myPosts/viewingPostsByUser, both of which are @Published arrays patched directly by
    /// bumpLocalCommentCount, so this should stay at 0 in practice. It is provided symmetrically in case
    /// post lists fed by static snapshots, like quotes, are added in the future (FeedListCard is designed
    /// with a baseline delta so it never double counts on either path)
    @Published private(set) var postCommentCountDeltas: [UUID: Int] = [:]

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Fetch

    /// Fetch the comment list (parents + replies flattened, grouped by parent_comment_id)
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

    /// Local delta for a quote's comment_count (used by FilteredQuoteFeedView etc.)
    func commentCountDelta(forQuote quoteId: UUID) -> Int {
        quoteCommentCountDeltas[quoteId] ?? 0
    }

    /// Local delta for a post's comment_count (post version of quoteCommentCountDeltas)
    func commentCountDelta(forPost postId: UUID) -> Int {
        postCommentCountDeltas[postId] ?? 0
    }

    // MARK: - Create

    /// Create a comment / reply (create_comment / create_quote_comment RPC)
    /// A reply if parentCommentId is given. The RPC creates notifications for the post author + the parent
    /// author
    /// Return value: false on failure
    /// Whether the most recent createComment failure was the 046 rate limit (50 per 24h) (to choose the
    /// message)
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

            // Fetch again (get the latest state, so the UI update is reliable)
            await loadComments(target: target)
            // Also increment the comment_count of the post/quote locally
            bumpLocalCommentCount(target: target, by: 1)
            return true
        } catch {
            print("⚠️ Failed to create comment: \(error)")
            // 046 rate limit. Checks the RAISE EXCEPTION message (same pattern as AppealService)
            if let pgError = error as? PostgrestError, pgError.message.contains("daily comment limit") {
                lastCreateWasRateLimited = true
            }
            return false
        }
    }

    // MARK: - Like

    /// Like/unlike a comment (toggle_comment_like RPC)
    /// Optimistic UI update + finalized by the RPC result
    /// viewerIsPostOwner: true if the viewer on the calling screen is the author of the post.
    /// In that case the "liked by author" badge (isLikedByOwner) also follows your own like immediately
    func toggleLike(commentId: UUID, target: CommentTarget, viewerIsPostOwner: Bool = false) async {
        guard UserAuthService.shared.userId != nil else { return }

        // Optimistic UI
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
            // Apply the final value from the RPC result
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
            // Rollback: fetch again
            print("⚠️ toggleCommentLike failed: \(error)")
            await loadComments(target: target)
        }
    }

    // MARK: - Delete (single)

    /// Delete a single comment (allowed for your own comment or for the post author, enforced by RLS)
    /// When a parent is deleted, its replies are also removed by ON DELETE CASCADE in the DB, so the feed
    /// card count is updated with the actual difference after loadComments
    func deleteComment(_ commentId: UUID, target: CommentTarget) async {
        let backup = commentsByTarget[target]
        let beforeCount = (commentsByTarget[target] ?? []).count

        // Optimistic UI
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
            // Fetch again to finalize
            await loadComments(target: target)
            let afterCount = (commentsByTarget[target] ?? []).count
            let delta = afterCount - beforeCount  // negative number (deletion)
            if delta != 0 {
                bumpLocalCommentCount(target: target, by: delta)
            }
        } catch {
            print("⚠️ deleteComment failed: \(error)")
            if let backup { commentsByTarget[target] = backup }
        }
    }

    /// Post author only: delete all comments on your own post (posts only. Official quotes have no "post
    /// author", so they are excluded)
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

    /// Clear the cache when a post is deleted
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
