//
//  AreteWidget.swift
//  AreteWidget
//
//  Widget that shows quotes. Reads the JSON cache in the App Group (written by the main app).
//  Heavy dependencies such as Supabase / FamilyControls are not brought into the extension (memory
//  limits).
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct QuoteEntry: TimelineEntry {
    let date: Date
    let quote: WidgetEntryQuote
    let language: String
    let mode: WidgetQuoteMode
}

// MARK: - Provider

struct Provider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(
            date: Date(),
            quote: Self.fallbackQuote,
            language: Self.deviceLanguage(),
            mode: .random
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> QuoteEntry {
        let pool = loadPool(for: configuration.mode)
        return QuoteEntry(
            date: Date(),
            quote: pool.randomElement() ?? Self.fallbackQuote,
            language: loadLanguage(),
            mode: configuration.mode
        )
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<QuoteEntry> {
        let pool = loadPool(for: configuration.mode)
        let language = loadLanguage()
        let now = Date()

        // Lay out 5 entries, one per hour. `.atEnd` requests again when the end is reached.
        let entries: [QuoteEntry] = (0..<5).map { hourOffset in
            let date = Calendar.current.date(byAdding: .hour, value: hourOffset, to: now) ?? now
            let quote = pool.randomElement() ?? Self.fallbackQuote
            return QuoteEntry(date: date, quote: quote, language: language, mode: configuration.mode)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    // MARK: - Cache reading

    private func loadPool(for mode: WidgetQuoteMode) -> [WidgetEntryQuote] {
        let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
        let key = mode == .favorite ? WidgetCacheKey.favoritePool : WidgetCacheKey.randomPool
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WidgetEntryQuote].self, from: data)) ?? []
    }

    private func loadLanguage() -> String {
        let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
        return defaults?.string(forKey: WidgetCacheKey.language) ?? Self.deviceLanguage()
    }

    private static func deviceLanguage() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code == "ja" ? "ja" : "en"
    }

    // 2026-07-30 quote audit: all real names removed. Author name empty = no line shown
    static let fallbackQuote = WidgetEntryQuote(
        id: "fallback",
        textJp: "止まりさえしなければ、どんなにゆっくりでも構わない。",
        textEn: "It does not matter how slowly you go as long as you do not stop.",
        authorName: "",
        isOfficial: true
    )
}

// MARK: - Entry View

struct AreteWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    private var jaPreferred: Bool { entry.language == "ja" }
    /// Text in the primary language used by Small / Medium (follows the device language).
    private var primaryText: String { entry.quote.displayText(jaPreferred: jaPreferred) }
    /// Top part of Large (bold, large): textEn is preferred even for Japanese users (same "original text as
    /// the lead" as ShareableQuoteCard).
    private var largePrimary: String {
        if jaPreferred, !entry.quote.textEn.isEmpty {
            return entry.quote.textEn
        }
        return entry.quote.displayText(jaPreferred: jaPreferred)
    }
    /// Bottom part of Large (Japanese translation): shown only for Japanese users when both languages exist.
    private var largeSecondary: String? {
        guard jaPreferred, !entry.quote.textJp.isEmpty, !entry.quote.textEn.isEmpty else { return nil }
        return entry.quote.textJp
    }
    /// Author name that may be shown. Empty/Anonymous (2026-07-30 all real names removed) is nil = the whole
    /// line is hidden
    private var author: String? {
        let name = entry.quote.authorName
        return (name.isEmpty || name == "Anonymous") ? nil : name
    }

    var body: some View {
        switch family {
        case .systemSmall:        smallView
        case .systemMedium:       mediumView
        case .systemLarge:        largeView
        case .accessoryCircular:  circularView
        case .accessoryRectangular: rectangularView
        case .accessoryInline:    inlineView
        default:                  smallView
        }
    }

    // MARK: Home Screen

    private var smallView: some View {
        ZStack {
            // Center: quote
            Text("“\(primaryText)”")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .minimumScaleFactor(0.7)
                .lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.bottom, 18) // so it does not overlap the author name

            // Bottom left: author name
            VStack {
                Spacer()
                HStack {
                    if let author {
                        Text("— \(author)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .containerBackground(for: .widget) { darkBackground }
    }

    private var mediumView: some View {
        ZStack {
            // Center: quote
            Text("“\(primaryText)”")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .minimumScaleFactor(0.75)
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.bottom, 22)

            // Bottom left: author name
            VStack {
                Spacer()
                HStack {
                    if let author {
                        Text("— \(author)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            // Bottom right: watermark
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    watermark
                }
            }
        }
        .containerBackground(for: .widget) { darkBackground }
    }

    private var largeView: some View {
        ZStack {
            // Center: English (bold, large) + Japanese translation (small)
            VStack(spacing: 14) {
                Text("“\(largePrimary)”")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .minimumScaleFactor(0.75)
                    .lineLimit(7)

                if let secondary = largeSecondary {
                    Text(secondary)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .minimumScaleFactor(0.7)
                        .lineLimit(5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 4)
            .padding(.bottom, 28)

            // Bottom left: author name
            VStack {
                Spacer()
                HStack {
                    if let author {
                        Text("— \(author)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            // Bottom right: watermark
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    watermark
                }
            }
        }
        .containerBackground(for: .widget) { darkBackground }
    }

    // MARK: Lock Screen

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            b1MarkMini
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    /// B1 mark (mini version for the round lock screen widget).
    /// A vertical bar + 2 diagonal dots. In viewBox 100 units (bar x44 y20 w12 h60 rx6 / dots r9.5 centered
    /// at (26,31),(74,69)).
    private var b1MarkMini: some View {
        let size: CGFloat = 22
        let scale = size / 100
        return ZStack {
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(Color.primary)
                .frame(width: 12 * scale, height: 60 * scale)
                .position(x: 50 * scale, y: 50 * scale)

            Circle()
                .fill(Color.primary)
                .frame(width: 19 * scale, height: 19 * scale)
                .position(x: 26 * scale, y: 31 * scale)

            Circle()
                .fill(Color.primary)
                .frame(width: 19 * scale, height: 19 * scale)
                .position(x: 74 * scale, y: 69 * scale)
        }
        .frame(width: size, height: size)
    }

    private var rectangularView: some View {
        VStack(spacing: 2) {
            Text("“\(primaryText)”")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let author {
                Text("— \(author)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var inlineView: some View {
        Text("“\(primaryText)”" + (author.map { " — \($0)" } ?? ""))
            .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: Helpers

    private var darkBackground: some View {
        LinearGradient(
            colors: [Color(white: 0.10), Color(white: 0.02)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var watermark: some View {
        Text("1%")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
    }
}

// MARK: - Widget

struct AreteWidget: Widget {
    let kind: String = "AreteWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: Provider()
        ) { entry in
            AreteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("1%")
        .description("Show a quote on your Home Screen or Lock Screen.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    AreteWidget()
} timeline: {
    QuoteEntry(
        date: Date(),
        quote: Provider.fallbackQuote,
        language: "en",
        mode: WidgetQuoteMode.random
    )
}
