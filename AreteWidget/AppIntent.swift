//
//  AppIntent.swift
//  AreteWidget
//
//  ウィジェットのコンフィグレーション。ホーム画面でウィジェットを長押し → 「ウィジェットを編集」で
//  「ランダム / お気に入りのみ」を切り替えられる。
//

import WidgetKit
import AppIntents

/// 表示モード。ラベルは AreteWidget/Localizable.xcstrings で ja / en に翻訳される。
enum WidgetQuoteMode: String, AppEnum {
    case random
    case favorite

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Source")
    }

    static var caseDisplayRepresentations: [WidgetQuoteMode: DisplayRepresentation] = [
        .random:   DisplayRepresentation(title: "Random"),
        .favorite: DisplayRepresentation(title: "Liked only")
    ]
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "1%" }
    static var description: IntentDescription {
        IntentDescription("Show a quote on your Home Screen or Lock Screen.")
    }

    @Parameter(title: "Source", default: .favorite)
    var mode: WidgetQuoteMode
}
