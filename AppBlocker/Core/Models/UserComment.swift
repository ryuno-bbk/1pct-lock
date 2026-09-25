//
//  UserComment.swift
//  AppBlocker
//
//  ユーザー投稿 (post_id) または公式名言 (quote_id 側は post_id が NULL) へのコメント。
//  返信は parent_comment_id (ネスト 1 階層)
//  fetch_comments_for_post / fetch_comments_for_quote RPC の戻り値型 (列構成は共通)
//

import Foundation

struct UserComment: Identifiable, Decodable, Equatable {
    let id: UUID
    /// UGC 投稿へのコメントの場合のみセット (公式名言へのコメントでは nil)
    let postId: UUID?
    let parentCommentId: UUID?
    let authorUserId: UUID
    let authorName: String?
    let authorAvatarUrl: String?
    let isProAuthor: Bool
    let text: String
    let likeCount: Int
    let isLikedByMe: Bool
    let createdAt: Date?
    /// 返信先ユーザー名 (parent コメント著者の display_name、なければ nil)
    let replyToName: String?
    /// 投稿の作者がこのコメントをいいねしているか (050 RPC。名言コメントや旧RPCでは false)
    let isLikedByOwner: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case postId           = "post_id"
        case parentCommentId  = "parent_comment_id"
        case authorUserId     = "author_user_id"
        case authorName       = "author_name"
        case authorAvatarUrl  = "author_avatar_url"
        case isProAuthor      = "is_pro_author"
        case likeCount        = "like_count"
        case isLikedByMe      = "is_liked_by_me"
        case createdAt        = "created_at"
        case replyToName      = "reply_to_name"
        case isLikedByOwner   = "is_liked_by_owner"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id               = try c.decode(UUID.self, forKey: .id)
        self.postId           = try c.decodeIfPresent(UUID.self, forKey: .postId)
        self.parentCommentId  = try c.decodeIfPresent(UUID.self, forKey: .parentCommentId)
        self.authorUserId     = try c.decode(UUID.self, forKey: .authorUserId)
        self.authorName       = try c.decodeIfPresent(String.self, forKey: .authorName)
        self.authorAvatarUrl  = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        self.isProAuthor      = try c.decodeIfPresent(Bool.self, forKey: .isProAuthor) ?? false
        self.text             = try c.decode(String.self, forKey: .text)
        self.likeCount        = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        self.isLikedByMe      = try c.decodeIfPresent(Bool.self, forKey: .isLikedByMe) ?? false
        self.createdAt        = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.replyToName      = try c.decodeIfPresent(String.self, forKey: .replyToName)
        // 050 適用前の RPC / fetch_comments_for_quote には列が無いので必ず decodeIfPresent
        self.isLikedByOwner   = try c.decodeIfPresent(Bool.self, forKey: .isLikedByOwner) ?? false
    }

    /// 楽観 UI 用の memberwise 初期化 (like 状態を差し替えた新インスタンスを作るため)
    init(
        id: UUID,
        postId: UUID?,
        parentCommentId: UUID?,
        authorUserId: UUID,
        authorName: String?,
        authorAvatarUrl: String?,
        isProAuthor: Bool,
        text: String,
        likeCount: Int,
        isLikedByMe: Bool,
        createdAt: Date?,
        replyToName: String?,
        isLikedByOwner: Bool = false
    ) {
        self.id               = id
        self.postId           = postId
        self.parentCommentId  = parentCommentId
        self.authorUserId     = authorUserId
        self.authorName       = authorName
        self.authorAvatarUrl  = authorAvatarUrl
        self.isProAuthor      = isProAuthor
        self.text             = text
        self.likeCount        = likeCount
        self.isLikedByMe      = isLikedByMe
        self.createdAt        = createdAt
        self.replyToName      = replyToName
        self.isLikedByOwner   = isLikedByOwner
    }
}
