//
//  UserNotification.swift
//  AppBlocker
//
//  In-app notifications (like / follow / comment / reply / comment_like)
//  Return type of the fetch_notifications RPC
//

import Foundation

struct UserNotification: Identifiable, Decodable, Equatable {

    /// Even if the rawValue is unknown, fall back to `.unknown` so the whole array decode
    /// does not fail (backward compatibility for when kinds are added on the server in the future).
    enum Kind: Equatable {
        case like
        case follow
        case comment
        case reply
        case commentLike
        case newPost
        /// Added in 039_moderation_notifications_appeals.sql. The ones below are system-generated
        /// notifications (self-reference style with recipient_user_id = actor_user_id, see isSystemKind)
        case contentRejected
        case contentFlagged
        case appealApproved
        case appealRejected
        /// Added in 054. Notification to the operator for an unsure appeal (the recipient is only the
        /// moderation_config.operator_user_id account. actor = the person appealing)
        case appealUnsure
        /// Added in 081. System notification that says the weekly report is ready
        /// (self-reference with recipient = actor. preview_text holds the lock seconds for that week)
        case weeklyReport
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "like":              self = .like
            case "follow":            self = .follow
            case "comment":           self = .comment
            case "reply":             self = .reply
            case "comment_like":      self = .commentLike
            case "new_post":          self = .newPost
            case "content_rejected":  self = .contentRejected
            case "content_flagged":   self = .contentFlagged
            case "appeal_approved":   self = .appealApproved
            case "appeal_rejected":   self = .appealRejected
            case "appeal_unsure":     self = .appealUnsure
            case "weekly_report":     self = .weeklyReport
            default:                  self = .unknown(rawValue)
            }
        }

        /// Whether it is a system-generated notification (moderation result / appeal result).
        /// These 4 kinds are created with the recipient=actor self-reference style, so the display side
        /// (NotificationListView) does not show the avatar/sender name as is and swaps in a system icon +
        /// the app name
        var isSystemKind: Bool {
            switch self {
            case .contentRejected, .contentFlagged, .appealApproved, .appealRejected,
                 .appealUnsure, .weeklyReport:
                return true
            case .like, .follow, .comment, .reply, .commentLike, .newPost, .unknown:
                return false
            }
        }
    }

    let id: UUID
    let kind: Kind
    let actorUserId: UUID
    let actorName: String?
    let actorAvatarUrl: String?
    let isProActor: Bool
    let targetPostId: UUID?
    /// Set for reply notifications on official quotes (post/quote are XOR, added in 017/018)
    let targetQuoteId: UUID?
    let targetCommentId: UUID?
    let previewText: String?
    let readAt: Date?
    let createdAt: Date?

    var isUnread: Bool { readAt == nil }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case actorUserId     = "actor_user_id"
        case actorName       = "actor_name"
        case actorAvatarUrl  = "actor_avatar_url"
        case isProActor      = "is_pro_actor"
        case targetPostId    = "target_post_id"
        case targetQuoteId   = "target_quote_id"
        case targetCommentId = "target_comment_id"
        case previewText     = "preview_text"
        case readAt          = "read_at"
        case createdAt       = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.kind            = Kind(rawValue: try c.decode(String.self, forKey: .kind))
        self.actorUserId     = try c.decode(UUID.self, forKey: .actorUserId)
        self.actorName       = try c.decodeIfPresent(String.self, forKey: .actorName)
        self.actorAvatarUrl  = try c.decodeIfPresent(String.self, forKey: .actorAvatarUrl)
        self.isProActor      = try c.decodeIfPresent(Bool.self, forKey: .isProActor) ?? false
        self.targetPostId    = try c.decodeIfPresent(UUID.self, forKey: .targetPostId)
        self.targetQuoteId   = try c.decodeIfPresent(UUID.self, forKey: .targetQuoteId)
        self.targetCommentId = try c.decodeIfPresent(UUID.self, forKey: .targetCommentId)
        self.previewText     = try c.decodeIfPresent(String.self, forKey: .previewText)
        self.readAt          = try c.decodeIfPresent(Date.self, forKey: .readAt)
        self.createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}
