//
//  FeedItem.swift
//  AppBlocker
//
//  混在フィード用統一データ型 (公式 quotes + UGC user_posts)
//  fetch_mixed_feed_random / fetch_following_feed / fetch_tag_feed RPC の戻り値
//  投稿v2 (S18〜): title / imagePath は UGC 投稿のみセットされる。quote 側は常に nil。
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
    /// UGC 投稿の場合のみセットされる背景画像 index (nil = item.itemId hash で自動割当)
    let backgroundId: Int?
    /// 投稿v2: タイトル (# タグを含みうる、任意)。quote 側は常に nil
    let title: String?
    /// 投稿v2: Storage `post-images` バケット内のパス。非nilなら焼き込み画像がカード全面背景になる
    let imagePath: String?
    /// 複数枚投稿: 画像枚数 (1〜4)。quote 側 / 旧投稿は常に 1
    let imageCount: Int

    /// kind 越境衝突を防ぐ Identifiable id
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

    /// 直接初期化 (UserPost や Quote からの変換用)
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

// MARK: - Hashable (navigationDestination(item:) 用。Equatable は全フィールド比較なので
// id ハッシュで一貫性が保たれる)

extension FeedItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 言語別表示ヘルパー (Quote と同じインターフェース)

extension FeedItem {
    /// メイン言語のテキスト (Quote.displayPrimary と同じロジック)
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

    /// 原文併記用サブテキスト (日本語メイン + 原文併記 ON のときのみ)
    func displaySecondary(lang: AppLanguage, showOriginal: Bool) -> String? {
        guard lang == .japanese, showOriginal,
              let jp = bodyJp, !jp.isEmpty,
              let en = bodyEn, !en.isEmpty else { return nil }
        return jp
    }

    /// 表示用タグ (空配列 / nil カテゴリ "" は除外)
    var displayTags: [String] {
        tags.filter { !$0.isEmpty }
    }

    /// 表示用タイトル。保存時に #タグを含んだままの title が入っている (過去データ含む) ため、
    /// tags に対応するハッシュタグ表示分と中身が空の単独 "#" を取り除いて返す
    /// (除去ルールの詳細は Quote.displayTitle 参照。二重表示バグの表示側フィックス)
    var displayTitle: String? {
        Quote.displayTitle(from: title, tags: tags)
    }

    /// 投稿v2: 焼き込み済み画像の Storage 公開URL (nil なら旧方式のテキスト投稿 or quote)
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
