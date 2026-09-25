//
//  SharedQuote.swift
//  AppBlocker
//
//  App Group経由で共有する名言モデル
//

import Foundation

/// Shield Extensionと共有するための軽量な名言モデル（英語・日本語対応 + 著者プロフィール）
struct SharedQuote: Codable, Equatable {
    let textEn: String
    let textJp: String
    let author: String
    let authorBioJp: String

    enum CodingKeys: String, CodingKey {
        case textEn = "text_en"
        case textJp = "text_jp"
        case author
        case authorBioJp = "author_bio_jp"
    }

    init(textEn: String, textJp: String, author: String, authorBioJp: String = "") {
        self.textEn = textEn
        self.textJp = textJp
        self.author = author
        self.authorBioJp = authorBioJp
    }

    init(from quote: Quote) {
        self.textEn = quote.textEn
        self.textJp = quote.textJp
        self.author = quote.author
        self.authorBioJp = quote.authorBioJp
    }
}

/// Shield UIの背景スタイル
enum BackgroundStyle: String, Codable, CaseIterable {
    case solidBlack = "solidBlack"
    case solidDark = "solidDark"
    case gradient = "gradient"
    case customImage = "customImage"

    var displayName: String {
        switch self {
        case .solidBlack: return "ブラック"
        case .solidDark: return "ダークグレー"
        case .gradient: return "グラデーション"
        case .customImage: return "カスタム画像"
        }
    }
}

/// 共有設定
struct SharedSettings: Codable {
    var backgroundStyle: BackgroundStyle
    var customImageName: String?
    var quoteTextSize: QuoteTextSize

    init(
        backgroundStyle: BackgroundStyle = .solidBlack,
        customImageName: String? = nil,
        quoteTextSize: QuoteTextSize = .large
    ) {
        self.backgroundStyle = backgroundStyle
        self.customImageName = customImageName
        self.quoteTextSize = quoteTextSize
    }
}

/// 名言テキストサイズ
enum QuoteTextSize: String, Codable, CaseIterable {
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"

    var displayName: String {
        switch self {
        case .medium: return "標準"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }
}
