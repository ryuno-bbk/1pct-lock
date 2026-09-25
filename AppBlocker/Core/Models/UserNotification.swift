//
//  UserNotification.swift
//  AppBlocker
//
//  アプリ内通知 (like / follow / comment / reply / comment_like)
//  fetch_notifications RPC の戻り値型
//

import Foundation

struct UserNotification: Identifiable, Decodable, Equatable {

    /// rawValue が未知の場合でも `.unknown` にフォールバックし、配列デコード全体が
    /// 失敗しないようにする (将来サーバー側で kind が追加された場合の後方互換)。
    enum Kind: Equatable {
        case like
        case follow
        case comment
        case reply
        case commentLike
        case newPost
        /// 039_moderation_notifications_appeals.sql で追加。以下はシステム生成通知
        /// (recipient_user_id = actor_user_id の自己参照方式、isSystemKind 参照)
        case contentRejected
        case contentFlagged
        case appealApproved
        case appealRejected
        /// 054 で追加。unsure 申し立ての運営向け通知 (受信者は moderation_config.operator_user_id
        /// のアカウントのみ。actor = 申し立て者)
        case appealUnsure
        /// 081 で追加。週次レポートができたことを知らせるシステム通知
        /// (recipient = actor の自己参照。preview_text にその週のロック秒数が入る)
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

        /// システム生成通知 (モデレーション結果 / 異議申し立て結果) かどうか。
        /// この4種は recipient=actor の自己参照方式で作られるため、表示側 (NotificationListView)
        /// はアバター/送信者名をそのまま出さずシステムアイコン + アプリ名に差し替える
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
    /// 公式名言への返信通知の場合にセットされる (post/quote は XOR、017/018 で追加)
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
