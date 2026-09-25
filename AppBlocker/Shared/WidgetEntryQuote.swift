//
//  WidgetEntryQuote.swift
//  AppBlocker + AreteWidget
//
//  メインアプリと AreteWidget 拡張で共有する軽量モデル + App Group のキー。
//  Quote / UserPost / FeedItem を JSON で App Group に書き出し、ウィジェット側はここから読み込む。
//  ⚠️ Target Membership: AppBlocker (main) と AreteWidget の両方にチェック必須。
//

import Foundation

/// ウィジェットに表示する 1 アイテム分の最小データ。
/// 両言語のテキスト + 著者名 + 公式フラグだけを持つ (画像 URL は今回未対応)。
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

    /// 言語に応じた本文。空文字なら他方にフォールバック。
    func displayText(jaPreferred: Bool) -> String {
        if jaPreferred {
            return textJp.isEmpty ? textEn : textJp
        } else {
            return textEn.isEmpty ? textJp : textEn
        }
    }
}

/// App Group UserDefaults でウィジェットキャッシュをやり取りするキー。
enum WidgetCacheKey {
    /// ランダムプール (公式 quote + 全 UGC の混在、最大 N 件)
    static let randomPool = "widget_random_pool_v1"
    /// お気に入りプール (いいね済み quote + post)
    static let favoritePool = "widget_favorite_pool_v1"
    /// 現在の表示言語 ("ja" / "en")
    static let language = "widget_language_v1"
}
