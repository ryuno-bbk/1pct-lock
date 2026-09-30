//
//  WidgetSharedTypes.swift
//  AreteWidget
//
//  Standalone definitions of types and constants used by the AreteWidget extension.
//  Keep the contents in sync with the definitions of the same names in the main app
//  (AppBlocker/Shared/WidgetEntryQuote.swift, AppGroupIdentifier.swift). Because of Synchronized
//  Folder, the same file cannot be shared, so they are defined twice.
//

import Foundation

/// ⚠️ Must match `AppGroupConstants.identifier` in the main app.
enum AppGroupConstants {
    static let identifier = "group.com.ryunosuke.appblocker.shared"
}

/// ⚠️ JSON compatible with `WidgetEntryQuote` in the main app (field names and types must match).
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
