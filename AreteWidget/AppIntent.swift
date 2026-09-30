//
//  AppIntent.swift
//  AreteWidget
//
//  Widget configuration. Long press the widget on the home screen → "ウィジェットを編集"
//  ("Edit Widget") to switch between "ランダム / お気に入りのみ" ("Random / Favorites only").
//

import WidgetKit
import AppIntents

/// Display mode. The labels are translated to ja / en in AreteWidget/Localizable.xcstrings.
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
