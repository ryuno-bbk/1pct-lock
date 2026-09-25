//
//  UserPost.swift
//  AppBlocker
//
//  UGC: ユーザー投稿モデル (text_jp / text_en 二言語構造、Quote と同じ)
//  投稿v2 (S18〜): 背景 + 自由配置テキストを1枚のJPEGに焼き込む方式を追加
//    - title / imagePath / overlays が非nilの投稿が新方式。旧投稿はtext_jp/text_enのまま共存。
//

import Foundation
import Supabase

struct UserPost: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let userId: UUID
    let textJp: String?
    let textEn: String?
    let tags: [String]
    let likeCount: Int
    let commentCount: Int
    let createdAt: Date?
    /// BackgroundImageProvider.imageFiles の index (nil = post.id hash で自動割当)
    let backgroundId: Int?
    /// 投稿v2: タイトル (# タグを含みうる、任意、60文字以内)
    let title: String?
    /// 投稿v2: Storage `post-images` バケット内のパス ({uid}/{post_id}.jpg)。旧投稿は nil
    let imagePath: String?
    /// 投稿v2: 焼き込み前の生テキスト+配置情報 (検索/モデレ/将来の再編集用、表示には使わない)
    let overlays: [PostOverlayDTO]?
    /// 複数枚投稿: 画像枚数 (1〜4)。旧投稿/未設定は 1
    let imageCount: Int
    /// AI モデレーション判定 (027 SQL): "pending"|"approved"|"flagged"|"rejected"。
    /// 旧レスポンス (列が無い場合) は nil のままデコードする。本人の投稿一覧のみ参照
    /// (公開フィードはサーバー側 RPC が既にフィルタ済みなのでアプリ側判定は不要)
    let moderationStatus: String?
    /// 投稿詳細が開かれた合計タップ数 (028 SQL、record_post_view で加算)。
    /// プロフィールグリッドのセル右下に表示、全員に見える
    let viewCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tags
        case userId          = "user_id"
        case textJp          = "text_jp"
        case textEn          = "text_en"
        case likeCount       = "like_count"
        case commentCount    = "comment_count"
        case createdAt       = "created_at"
        case backgroundId    = "background_id"
        case title
        case imagePath       = "image_path"
        case overlays
        case imageCount      = "image_count"
        case moderationStatus = "moderation_status"
        case viewCount       = "view_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self, forKey: .id)
        self.userId       = try c.decode(UUID.self, forKey: .userId)
        self.textJp       = try c.decodeIfPresent(String.self, forKey: .textJp)
        self.textEn       = try c.decodeIfPresent(String.self, forKey: .textEn)
        self.tags         = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.likeCount    = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        self.commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        self.createdAt    = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.backgroundId = try c.decodeIfPresent(Int.self, forKey: .backgroundId)
        self.title        = try c.decodeIfPresent(String.self, forKey: .title)
        self.imagePath    = try c.decodeIfPresent(String.self, forKey: .imagePath)
        self.overlays     = try c.decodeIfPresent([PostOverlayDTO].self, forKey: .overlays)
        self.imageCount   = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1
        self.moderationStatus = try c.decodeIfPresent(String.self, forKey: .moderationStatus)
        self.viewCount    = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
    }

    init(
        id: UUID = UUID(),
        userId: UUID,
        textJp: String? = nil,
        textEn: String? = nil,
        tags: [String] = [],
        likeCount: Int = 0,
        commentCount: Int = 0,
        createdAt: Date? = nil,
        backgroundId: Int? = nil,
        title: String? = nil,
        imagePath: String? = nil,
        overlays: [PostOverlayDTO]? = nil,
        imageCount: Int = 1,
        moderationStatus: String? = nil,
        viewCount: Int = 0
    ) {
        self.id = id
        self.userId = userId
        self.textJp = textJp
        self.textEn = textEn
        self.tags = tags
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.backgroundId = backgroundId
        self.title = title
        self.imagePath = imagePath
        self.overlays = overlays
        self.imageCount = imageCount
        self.moderationStatus = moderationStatus
        self.viewCount = viewCount
    }
}

// MARK: - 言語別表示ヘルパー (Quote と同じインターフェース)

extension UserPost {
    func displayPrimary(lang: AppLanguage, showOriginal: Bool) -> String {
        let jp = textJp ?? ""
        let en = textEn ?? ""

        if lang == .japanese && showOriginal && !en.isEmpty {
            return en
        }
        switch lang {
        case .japanese: return jp.isEmpty ? en : jp
        case .english:  return en.isEmpty ? jp : en
        }
    }

    func displaySecondary(lang: AppLanguage, showOriginal: Bool) -> String? {
        guard lang == .japanese, showOriginal,
              let jp = textJp, !jp.isEmpty,
              let en = textEn, !en.isEmpty else { return nil }
        return jp
    }

    /// 表示用タイトル (FeedItem.displayTitle と同じ、除去ルールの詳細は Quote.displayTitle 参照)
    var displayTitle: String? {
        Quote.displayTitle(from: title, tags: tags)
    }

    /// 投稿v2: 焼き込み済み画像の Storage 公開URL (nil なら旧方式のテキスト投稿)
    /// 複数枚投稿の場合は 1 枚目 (カバー) の URL
    var imageUrl: URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return try? SupabaseManager.shared.client.storage.from("post-images").getPublicURL(path: imagePath)
    }

    /// 複数枚投稿: image_count 分の Storage 公開URL配列 (順序保持)。
    /// パス規約: 1枚目 = imagePath そのもの、2枚目以降 = "{base}_2.jpg" 〜 "{base}_4.jpg"
    var imageUrls: [URL] {
        guard let imagePath, !imagePath.isEmpty, imagePath.hasSuffix(".jpg") else {
            return imageUrl.map { [$0] } ?? []
        }
        let base = String(imagePath.dropLast(4)) // ".jpg" を除去
        let count = max(imageCount, 1)
        let paths = (1...count).map { n in n == 1 ? imagePath : "\(base)_\(n).jpg" }
        return paths.compactMap { try? SupabaseManager.shared.client.storage.from("post-images").getPublicURL(path: $0) }
    }
}

// MARK: - FeedItem 変換 (自分の投稿フィード表示用)

extension UserPost {
    func toFeedItem(authorName: String?, avatarUrl: String?, isProAuthor: Bool = false) -> FeedItem {
        FeedItem(
            kind: .post,
            itemId: id,
            bodyJp: textJp,
            bodyEn: textEn,
            tags: tags,
            likeCount: likeCount,
            commentCount: commentCount,
            createdAt: createdAt,
            authorId: userId,
            authorName: authorName,
            authorAvatarUrl: avatarUrl,
            isOfficialAuthor: false,
            isProAuthor: isProAuthor,
            backgroundId: backgroundId,
            title: title,
            imagePath: imagePath,
            imageCount: imageCount
        )
    }
}

// MARK: - 投稿v2: オーバーレイテキスト (生テキスト+配置情報)

/// 投稿v2の1テキストオーバーレイ。画像に焼き込み済みなので表示には使わないが、
/// 検索/モデレ/将来の再編集のために overlays jsonb 列へそのまま保存する。
/// 複数枚投稿 (S20): imageIndex で「何枚目の画像のオーバーレイか」(0始まり) を保持する。
/// 既存行 (021 適用前に保存された overlays) には imageIndex キーが無いため、
/// init(from:) で decodeIfPresent ?? 0 にして後方互換を保つ。
struct PostOverlayDTO: Codable, Equatable, Hashable {
    let text: String
    let font: String        // "serif" | "sans" | ...
    let color: String       // 文字色トークン ("offwhite" | "ink" | "#RRGGBB" ...)
    let plate: Bool
    let x: Double            // 中心位置/キャンバス幅 0-1
    let y: Double
    let fontSize: Double     // pt/キャンバス幅 正規化
    let rotationDegrees: Double
    let alignment: String    // "left" | "center" | "right"
    let imageIndex: Int      // 何枚目の画像か (0始まり)。旧データは 0 扱い
    /// プレート背景色トークン。nil = 文字色から自動コントラスト (旧データも nil 扱い)
    let plateColor: String?

    enum CodingKeys: String, CodingKey {
        case text, font, color, plate, x, y, fontSize, rotationDegrees, alignment, imageIndex, plateColor
    }

    init(
        text: String,
        font: String,
        color: String,
        plate: Bool,
        x: Double,
        y: Double,
        fontSize: Double,
        rotationDegrees: Double,
        alignment: String,
        imageIndex: Int = 0,
        plateColor: String? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.plate = plate
        self.x = x
        self.y = y
        self.fontSize = fontSize
        self.rotationDegrees = rotationDegrees
        self.alignment = alignment
        self.imageIndex = imageIndex
        self.plateColor = plateColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text            = try c.decode(String.self, forKey: .text)
        self.font            = try c.decode(String.self, forKey: .font)
        self.color           = try c.decode(String.self, forKey: .color)
        self.plate           = try c.decode(Bool.self, forKey: .plate)
        self.x               = try c.decode(Double.self, forKey: .x)
        self.y               = try c.decode(Double.self, forKey: .y)
        self.fontSize        = try c.decode(Double.self, forKey: .fontSize)
        self.rotationDegrees = try c.decode(Double.self, forKey: .rotationDegrees)
        self.alignment       = try c.decode(String.self, forKey: .alignment)
        self.imageIndex      = try c.decodeIfPresent(Int.self, forKey: .imageIndex) ?? 0
        self.plateColor      = try c.decodeIfPresent(String.self, forKey: .plateColor)
    }

    /// imageIndex だけを差し替えたコピーを返す (PostDraft.flattenedOverlayDTOs で使用)
    func withImageIndex(_ index: Int) -> PostOverlayDTO {
        PostOverlayDTO(
            text: text,
            font: font,
            color: color,
            plate: plate,
            x: x,
            y: y,
            fontSize: fontSize,
            rotationDegrees: rotationDegrees,
            alignment: alignment,
            imageIndex: index,
            plateColor: plateColor
        )
    }
}
