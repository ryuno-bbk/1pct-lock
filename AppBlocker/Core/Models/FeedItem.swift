//
//  FeedItem.swift
//  AppBlocker
//
//  Unified data type for the mixed feed (official quotes + UGC user_posts)
//  Return value of the fetch_mixed_feed_random / fetch_following_feed / fetch_tag_feed RPCs
//  Posts v2 (S18 onward): title / imagePath are set only for UGC posts. Always nil on the quote side.
//

import Foundation
import Supabase

struct FeedItem: Identifiable, Decodable, Equatable {
    let kind: Kind
    let itemId: UUID
    let bodyJp: String?
    let bodyEn: String?
    let tags: [String]
    let likeCount: Int
    let commentCount: Int
    let createdAt: Date?
    let authorId: UUID?
    let authorName: String?
    let authorAvatarUrl: String?
    let isOfficialAuthor: Bool
    let isProAuthor: Bool
    /// Background image index, set only for UGC posts (nil = assigned automatically by the item.itemId hash)
    let backgroundId: Int?
    /// Posts v2: title (may contain # tags, optional). Always nil on the quote side
    let title: String?
    /// Posts v2: path in the Storage `post-images` bucket. If non-nil, the baked image becomes the full
    /// background of the card
    let imagePath: String?
    /// Multi-image posts: number of images (1-4). Always 1 for quotes / old posts
    let imageCount: Int

    /// Identifiable id that prevents collisions across kinds
    var id: String { "\(kind.rawValue)-\(itemId.uuidString)" }

    enum Kind: String, Decodable, Equatable {
        case quote
        case post
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case itemId           = "item_id"
        case bodyJp           = "body_jp"
        case bodyEn           = "body_en"
        case tags
        case likeCount        = "like_count"
        case commentCount     = "comment_count"
        case createdAt        = "created_at"
        case authorId         = "author_id"
        case authorName       = "author_name"
        case authorAvatarUrl  = "author_avatar_url"
        case isOfficialAuthor = "is_official_author"
        case isProAuthor      = "is_pro_author"
        case backgroundId     = "background_id"
        case title
        case imagePath        = "image_path"
        case imageCount       = "image_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind             = try c.decode(Kind.self, forKey: .kind)
        self.itemId           = try c.decode(UUID.self, forKey: .itemId)
        self.bodyJp           = try c.decodeIfPresent(String.self, forKey: .bodyJp)
        self.bodyEn           = try c.decodeIfPresent(String.self, forKey: .bodyEn)
        self.tags             = (try c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        self.likeCount        = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        self.commentCount     = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        self.createdAt        = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.authorId         = try c.decodeIfPresent(UUID.self, forKey: .authorId)
        self.authorName       = try c.decodeIfPresent(String.self, forKey: .authorName)
        self.authorAvatarUrl  = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        self.isOfficialAuthor = try c.decodeIfPresent(Bool.self, forKey: .isOfficialAuthor) ?? false
        self.isProAuthor      = try c.decodeIfPresent(Bool.self, forKey: .isProAuthor) ?? false
        self.backgroundId     = try c.decodeIfPresent(Int.self, forKey: .backgroundId)
        self.title            = try c.decodeIfPresent(String.self, forKey: .title)
        self.imagePath        = try c.decodeIfPresent(String.self, forKey: .imagePath)
        self.imageCount       = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1
    }

    /// Direct initialization (for conversion from UserPost or Quote)
    init(
        kind: Kind,
        itemId: UUID,
        bodyJp: String?,
        bodyEn: String?,
        tags: [String],
        likeCount: Int,
        commentCount: Int = 0,
        createdAt: Date?,
        authorId: UUID?,
        authorName: String?,
        authorAvatarUrl: String?,
        isOfficialAuthor: Bool,
        isProAuthor: Bool = false,
        backgroundId: Int? = nil,
        title: String? = nil,
        imagePath: String? = nil,
        imageCount: Int = 1
    ) {
        self.kind             = kind
        self.itemId           = itemId
        self.bodyJp           = bodyJp
        self.bodyEn           = bodyEn
        self.tags             = tags
        self.likeCount        = likeCount
        self.commentCount     = commentCount
        self.createdAt        = createdAt
        self.authorId         = authorId
        self.authorName       = authorName
        self.authorAvatarUrl  = authorAvatarUrl
        self.isOfficialAuthor = isOfficialAuthor
        self.isProAuthor      = isProAuthor
        self.backgroundId     = backgroundId
        self.title            = title
        self.imagePath        = imagePath
        self.imageCount       = imageCount
    }
}

// MARK: - Hashable (for navigationDestination(item:). Equatable compares all fields, so
// consistency is kept with the id hash)

extension FeedItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Per-language display helpers (same interface as Quote)

extension FeedItem {
    /// Text in the main language (same logic as Quote.displayPrimary)
    func displayPrimary(lang: AppLanguage, showOriginal: Bool) -> String {
        let jp = bodyJp ?? ""
        let en = bodyEn ?? ""

        if lang == .japanese && showOriginal && !en.isEmpty {
            return en
        }
        switch lang {
        case .japanese: return jp.isEmpty ? en : jp
        case .english:  return en.isEmpty ? jp : en
        }
    }

    /// Sub text for showing the original (only when the main language is Japanese + show original is ON)
    func displaySecondary(lang: AppLanguage, showOriginal: Bool) -> String? {
        guard lang == .japanese, showOriginal,
              let jp = bodyJp, !jp.isEmpty,
              let en = bodyEn, !en.isEmpty else { return nil }
        return jp
    }

    /// Tags for display (empty arrays / nil category "" are excluded)
    var displayTags: [String] {
        tags.filter { !$0.isEmpty }
    }

    /// Title for display. The saved title still contains the #tags (including old data), so this
    /// removes the hashtag parts that correspond to tags and any lone "#" with nothing after it
    /// (for details of the removal rules see Quote.displayTitle. A display-side fix for the double display bug)
    var displayTitle: String? {
        Quote.displayTitle(from: title, tags: tags)
    }

    /// Posts v2: public Storage URL of the baked image (nil means an old-style text post or a quote)
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
