//
//  WidgetSharedTypes.swift
//  AreteWidget
//
//  AreteWidget 拡張から参照する型・定数の独立定義。
//  メインアプリ側の同名定義 (AppBlocker/Shared/WidgetEntryQuote.swift, AppGroupIdentifier.swift) と
//  内容を同期させること。Synchronized Folder の都合で同じファイルを共有できないため二重定義になっている。
//

import Foundation

/// ⚠️ メインアプリ側の `AppGroupConstants.identifier` と一致させること。
enum AppGroupConstants {
    static let identifier = "group.com.ryunosuke.appblocker.shared"
}

/// ⚠️ メインアプリ側 `WidgetEntryQuote` と JSON 互換 (フィールド名・型一致必須)。
struct WidgetEntryQuote: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let textJp: String
    let textEn: String
    let authorName: String
    let isOfficial: Bool

    func displayText(jaPreferred: Bool) -> String {
        if jaPreferred {
            return textJp.isEmpty ? textEn : textJp
        } else {
            return textEn.isEmpty ? textJp : textEn
        }
    }
}

enum WidgetCacheKey {
    static let randomPool = "widget_random_pool_v1"
    static let favoritePool = "widget_favorite_pool_v1"
    static let language = "widget_language_v1"
}
