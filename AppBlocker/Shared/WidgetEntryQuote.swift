//
//  WidgetEntryQuote.swift
//  AppBlocker + AreteWidget
//
//  Lightweight model + App Group keys shared by the main app and the AreteWidget extension.
//  Quote / UserPost / FeedItem are written to the App Group as JSON, and the widget side reads
//  them from here.
//  ⚠️ Target Membership: must be checked for both AppBlocker (main) and AreteWidget.
//

import Foundation

/// Minimal data for 1 item shown in the widget.
/// Holds only the text in both languages + author name + official flag (image URLs not supported
/// this time).
struct WidgetEntryQuote: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let textJp: String
    let textEn: String
    let authorName: String
    let isOfficial: Bool

    init(id: String, textJp: String, textEn: String, authorName: String, isOfficial: Bool) {
        self.id = id
        self.textJp = textJp
        self.textEn = textEn
        self.authorName = authorName
        self.isOfficial = isOfficial
    }

    /// Body text for the language. If empty, fall back to the other one.
    func displayText(jaPreferred: Bool) -> String {
        if jaPreferred {
            return textJp.isEmpty ? textEn : textJp
        } else {
            return textEn.isEmpty ? textJp : textEn
        }
    }
}

/// Keys for exchanging the widget cache through App Group UserDefaults.
enum WidgetCacheKey {
    /// Random pool (mix of official quotes + all UGC, up to N items)
    static let randomPool = "widget_random_pool_v1"
    /// Favorites pool (liked quotes + posts)
    static let favoritePool = "widget_favorite_pool_v1"
    /// Current display language ("ja" / "en")
    static let language = "widget_language_v1"
}
