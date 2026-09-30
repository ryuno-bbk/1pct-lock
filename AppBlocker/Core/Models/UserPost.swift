//
//  UserPost.swift
//  AppBlocker
//
//  UGC: user post model (text_jp / text_en bilingual structure, same as Quote)
//  Posts v2 (S18 onward): added a method that bakes the background + freely placed text into one JPEG
//    - Posts with non-nil title / imagePath / overlays use the new method. Old posts keep
//      text_jp/text_en and coexist.
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
    /// Index into BackgroundImageProvider.imageFiles (nil = assigned automatically by the post.id hash)
    let backgroundId: Int?
    /// Posts v2: title (may contain # tags, optional, up to 60 characters)
    let title: String?
    /// Posts v2: path in the Storage `post-images` bucket ({uid}/{post_id}.jpg). nil for old posts
    let imagePath: String?
    /// Posts v2: raw text + placement info before baking (for search/moderation/future re-editing, not
    /// used for display)
    let overlays: [PostOverlayDTO]?
    /// Multi-image posts: number of images (1-4). 1 for old/unset posts
    let imageCount: Int
    /// AI moderation verdict (027 SQL): "pending"|"approved"|"flagged"|"rejected".
    /// Old responses (without the column) decode as nil. Only referenced in your own post list
    /// (the public feed is already filtered by the server-side RPC, so no check is needed on the app side)
    let moderationStatus: String?
    /// Total number of taps that opened the post detail (028 SQL, incremented by record_post_view).
    /// Shown at the bottom right of the cell in the profile grid, visible to everyone
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

// MARK: - Per-language display helpers (same interface as Quote)

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

    /// Title for display (same as FeedItem.displayTitle; for details of the removal rules see
    /// Quote.displayTitle)
    var displayTitle: String? {
        Quote.displayTitle(from: title, tags: tags)
    }

    /// Posts v2: public Storage URL of the baked image (nil means an old-style text post)
    /// For multi-image posts, the URL of the 1st image (cover)
    var imageUrl: URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return try? SupabaseManager.shared.client.storage.from("post-images").getPublicURL(path: imagePath)
    }

    /// Multi-image posts: array of public Storage URLs for image_count (order kept).
    /// Path convention: 1st = imagePath itself, 2nd and later = "{base}_2.jpg" to "{base}_4.jpg"
    var imageUrls: [URL] {
        guard let imagePath, !imagePath.isEmpty, imagePath.hasSuffix(".jpg") else {
            return imageUrl.map { [$0] } ?? []
        }
        let base = String(imagePath.dropLast(4)) // Remove ".jpg"
        let count = max(imageCount, 1)
        let paths = (1...count).map { n in n == 1 ? imagePath : "\(base)_\(n).jpg" }
        return paths.compactMap { try? SupabaseManager.shared.client.storage.from("post-images").getPublicURL(path: $0) }
    }
}

// MARK: - FeedItem conversion (for showing your own post feed)

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

// MARK: - Posts v2: overlay text (raw text + placement info)

/// One text overlay of posts v2. It is already baked into the image, so it is not used for display,
/// but it is saved as is into the overlays jsonb column for search/moderation/future re-editing.
/// Multi-image posts (S20): imageIndex holds "which image this overlay belongs to" (0-based).
/// Existing rows (overlays saved before 021 was applied) have no imageIndex key, so
/// init(from:) uses decodeIfPresent ?? 0 to stay backward compatible.
struct PostOverlayDTO: Codable, Equatable, Hashable {
    let text: String
    let font: String        // "serif" | "sans" | ...
    let color: String       // Text color token ("offwhite" | "ink" | "#RRGGBB" ...)
    let plate: Bool
    let x: Double            // Center position / canvas width, 0-1
    let y: Double
    let fontSize: Double     // pt / canvas width, normalized
    let rotationDegrees: Double
    let alignment: String    // "left" | "center" | "right"
    let imageIndex: Int      // Which image (0-based). Old data is treated as 0
    /// Plate background color token. nil = automatic contrast from the text color (old data is also treated
    /// as nil)
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

    /// Returns a copy with only imageIndex replaced (used by PostDraft.flattenedOverlayDTOs)
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
