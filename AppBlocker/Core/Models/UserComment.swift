//
//  UserComment.swift
//  AppBlocker
//
//  A comment on a user post (post_id) or an official quote (on the quote_id side, post_id is NULL).
//  Replies use parent_comment_id (1 level of nesting)
//  Return type of the fetch_comments_for_post / fetch_comments_for_quote RPCs (same column layout)
//

import Foundation

struct UserComment: Identifiable, Decodable, Equatable {
    let id: UUID
    /// Set only for comments on UGC posts (nil for comments on official quotes)
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
    /// Name of the user replied to (display_name of the parent comment's author, nil if none)
    let replyToName: String?
    /// Whether the post's author liked this comment (050 RPC. false for quote comments and the old RPC)
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
        // The RPC before 050 / fetch_comments_for_quote do not have the column, so always use decodeIfPresent
        self.isLikedByOwner   = try c.decodeIfPresent(Bool.self, forKey: .isLikedByOwner) ?? false
    }

    /// Memberwise init for optimistic UI (to create a new instance with a replaced like state)
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
