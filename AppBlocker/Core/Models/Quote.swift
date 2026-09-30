//
//  Quote.swift
//  AppBlocker
//
//  Quote data model
//

import Foundation

/// Model for a quote (English/Japanese + author profile)
struct Quote: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let authorId: UUID?
    let textEn: String
    let textJp: String
    let author: String
    let authorBioEn: String
    let authorBioJp: String
    let category: String?
    let likeCount: Int
    /// Comment count (quotes.comment_count denormalized column. Treated as optional for compatibility with
    /// existing data, default 0)
    let commentCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case textEn = "text_en"
        case textJp = "text_jp"
        case author
        case authorBioEn = "author_bio_en"
        case authorBioJp = "author_bio_jp"
        case category
        case likeCount = "like_count"
        case commentCount = "comment_count"
    }

    init(
        id: UUID = UUID(),
        authorId: UUID? = nil,
        textEn: String,
        textJp: String,
        author: String,
        authorBioEn: String = "",
        authorBioJp: String = "",
        category: String? = nil,
        likeCount: Int = 0,
        commentCount: Int = 0
    ) {
        self.id = id
        self.authorId = authorId
        self.textEn = textEn
        self.textJp = textJp
        self.author = author
        self.authorBioEn = authorBioEn
        self.authorBioJp = authorBioJp
        self.category = category
        self.likeCount = likeCount
        self.commentCount = commentCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        authorId = try container.decodeIfPresent(UUID.self, forKey: .authorId)
        textEn = try container.decode(String.self, forKey: .textEn)
        textJp = try container.decode(String.self, forKey: .textJp)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorBioEn = try container.decodeIfPresent(String.self, forKey: .authorBioEn) ?? ""
        authorBioJp = try container.decodeIfPresent(String.self, forKey: .authorBioJp) ?? ""
        category = (try? container.decodeIfPresent(String.self, forKey: .category)) ?? nil
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
    }
}

// MARK: - Per-language display helpers
extension Quote {
    /// Text shown large on top visually
    /// - When the main language is Japanese + show original is ON, show the "English" large on top (the
    ///   original is the focus)
    /// - Otherwise (English main, or Japanese only), the text in the main language
    func displayPrimary(lang: AppLanguage, showOriginal: Bool) -> String {
        if lang == .japanese && showOriginal && !textEn.isEmpty {
            return textEn
        }
        switch lang {
        case .japanese: return textJp.isEmpty ? textEn : textJp
        case .english:  return textEn
        }
    }

    /// Subtext shown small below. Returns the "Japanese translation" only when the main language is
    /// Japanese + show original is ON
    func displaySecondary(lang: AppLanguage, showOriginal: Bool) -> String? {
        guard lang == .japanese, showOriginal, !textJp.isEmpty else { return nil }
        return textJp
    }
}

// MARK: - Helpers for category display
extension Quote {
    /// Dictionary of category raw key → Japanese display name
    /// Add here when a category is added on the Supabase side. An unregistered category falls back to
    /// showing the raw string.
    static let categoryDisplayJa: [String: String] = [
        "mindset":      "マインドセット",
        "action":       "行動",
        "discipline":   "規律",
        "work-ethic":   "努力",
        "growth":       "成長",
        "hardship":     "困難",
        "self-belief":  "自信",
        "consistency":  "継続",
        "failure":      "失敗",
        "focus":        "集中",
        "fear":         "恐怖",
        "sports":       "スポーツ",
        "philosophy":   "哲学",
        "success":      "成功",
        "motivation":   "モチベーション",
        "life":         "人生"
    ]

    /// Dictionary of category raw key → English display name
    static let categoryDisplayEn: [String: String] = [
        "mindset":      "Mindset",
        "action":       "Action",
        "discipline":   "Discipline",
        "work-ethic":   "Work Ethic",
        "growth":       "Growth",
        "hardship":     "Hardship",
        "self-belief":  "Self-Belief",
        "consistency":  "Consistency",
        "failure":      "Failure",
        "focus":        "Focus",
        "fear":         "Fear",
        "sports":       "Sports",
        "philosophy":   "Philosophy",
        "success":      "Success",
        "motivation":   "Motivation",
        "life":         "Life"
    ]

    /// Returns the display name of a category. If not in the dictionary, returns the raw key as is (safe
    /// fallback that does not break launch)
    static func categoryDisplay(_ category: String, lang: AppLanguage) -> String {
        let dict = lang == .japanese ? categoryDisplayJa : categoryDisplayEn
        return dict[category] ?? category
    }
}

// MARK: - Cleaning post titles for display (2026-08-02: fix for the hashtag double display bug)
// The save logic in PostConfirmView "extracted tags, and also saved the title still containing the #tags"
// together, so on the feed the same tag was shown twice, in the title and in the tag row
// (sometimes a lone # was left at the end, a leftover from holding the # chip button).
// Handled on the display side so dirty titles already in the DB are also fixed.
// This is the reverse of PostConfirmView.extractTagKeys (extracting tag keys from title):
// from the tag keys, find the matching hashtag display tokens in the title and remove them
extension Quote {
    /// From title, remove the #tokens matching tags (array of keys) and any lone "#" with nothing after it.
    /// A #something not in tags may be part of the text the user wrote, so keep it (do not delete silently).
    /// If title is nil return nil; if it is an empty string return the empty string
    static func displayTitle(from title: String?, tags: [String]) -> String? {
        guard let title else { return nil }
        guard !title.isEmpty else { return title }

        // Match the display name of the tags (keys) in either Japanese or English. The title holds the display
        // name (e.g. the key "discipline" is saved as "#規律" ("#Discipline") in Japanese, and "#Discipline" in
        // English)
        // ⚠️ Some display names contain spaces ("work-ethic" → "Work Ethic" in English).
        // Splitting tokens by whitespace only catches "#Work" and misses it, so
        // search for "# + display name" as one literal. Unless the longer ones are removed first,
        // a shorter one eats a partial match first, so sort in descending order
        let needles = Set(tags.flatMap { tag in
            [Self.categoryDisplay(tag, lang: .japanese), Self.categoryDisplay(tag, lang: .english)]
        })
        .filter { !$0.isEmpty }
        .map { "#" + $0 }
        .sorted { $0.count > $1.count }

        var cleaned = title
        for needle in needles {
            // Only remove those followed by a space / another # / end of line. Without checking the boundary,
            // the head of a user-written "#Growthマインド" ("#Growth mind") would be cut, leaving "マインド" ("mind")
            let pattern = NSRegularExpression.escapedPattern(for: needle) + "(?=[\\s#]|$)"
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Remove a lone "#" with nothing after it (leftover from typing only # without picking a candidate).
        // Only when surrounded by spaces/line edges = a # inside a word like "C#" is kept
        cleaned = cleaned.replacingOccurrences(
            of: "(^|\\s)#(?=\\s|$)", with: "$1", options: [.regularExpression])

        // Nothing removed = the title needs no cleaning, so return the user's string without any change
        // (avoids the space collapsing below silently turning full-width spaces etc. into half-width)
        guard cleaned != title else { return title }

        // Collapse consecutive spaces created by the removal into one (line breaks are paragraph structure and
        // are not touched)
        let collapsed = cleaned.replacingOccurrences(of: "[ \u{3000}]+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Display rule for anonymous authors (2026-07-30 audit of all quotes)
// Real names were removed entirely, and all quotes were reassigned to the anonymous author Anonymous.
// Do not show the "Anonymous" attribution line (with its leading dash) at all (quotes are text +
// hashtags only). If quotes with authors come back later, the display returns naturally
extension Quote {
    static func isAnonymousAuthor(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return true }
        return name == "Anonymous"
    }

    /// Author name that may be shown on screen. If anonymous (Anonymous/empty), nil = the whole line is hidden
    var displayAuthor: String? {
        Self.isAnonymousAuthor(author) ? nil : author
    }
}

// MARK: - Sample Data
// 2026-07-30 audit of all quotes: real names removed entirely (anonymized, same as Quotes.json/DB).
// The fallback also consists only of quotes the user decided to "keep"
extension Quote {
    private static let anonymousBioEn = "Quotes whose original author is unknown or attributed to multiple sources."
    private static let anonymousBioJp = "原著者不明、または複数ソースに帰される名言を集約。"

    static let samples: [Quote] = [
        Quote(
            textEn: "The job's not finished.",
            textJp: "仕事はまだ終わっていない。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "sports"
        ),
        Quote(
            textEn: "Hard work beats talent when talent doesn't work hard.",
            textJp: "才能が努力を怠れば、努力が才能を超える。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "motivation"
        ),
        Quote(
            textEn: "Don't stop when you're tired. Stop when you're done.",
            textJp: "疲れた時に止まるんじゃない。終わった時に止まれ。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "discipline"
        ),
        Quote(
            textEn: "It does not matter how slowly you go as long as you do not stop.",
            textJp: "止まりさえしなければ、どんなにゆっくりでも構わない。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "philosophy"
        ),
        Quote(
            textEn: "Yesterday you said tomorrow.",
            textJp: "昨日、お前は明日やると言った。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "motivation"
        )
    ]
}
