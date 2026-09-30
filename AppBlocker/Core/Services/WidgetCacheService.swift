//
//  WidgetCacheService.swift
//  AppBlocker
//
//  Service that writes "favorite quotes" and a "random pool" as JSON to the App Group for
//  AreteWidget. The widget extension does not access Supabase directly; it only reads the cache
//  written here.
//

import Foundation
import WidgetKit

/// Widget cache writing service (main app only).
@MainActor
final class WidgetCacheService {

    static let shared = WidgetCacheService()

    /// Maximum size of the random pool. Too many bloats the JSON, too few makes the same quotes show up
    /// often.
    private let maxRandomPoolSize = 50
    /// Maximum size of the favorites pool.
    private let maxFavoritePoolSize = 100

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.identifier)
    }

    private init() {}

    // MARK: - Public

    /// Write all pools together and reload the timeline. Called at launch / sign-in.
    func refreshAll() {
        writeLanguage()
        writeRandomPool()
        writeFavoritePool()
        reload()
    }

    /// Called when likes change. Updates only the favorites pool + reload.
    func refreshFavorites() {
        writeFavoritePool()
        reload()
    }

    /// Called when the language setting changes.
    func refreshLanguage() {
        writeLanguage()
        reload()
    }

    // MARK: - Private

    /// Randomly sample from official quotes + UGC by others and write them to the pool.
    /// ⚠️ FeedService's recommended cache excludes blocked users through a separate RPC, but
    /// this pool is simply built from QuoteService's stock (the widget is designed not to personalize
    /// strongly).
    private func writeRandomPool() {
        let quotes = QuoteService.shared.quotes
        let entries = quotes.shuffled().prefix(maxRandomPoolSize).map { quote in
            WidgetEntryQuote(
                id: quote.id.uuidString,
                textJp: quote.textJp,
                textEn: quote.textEn,
                authorName: quote.displayAuthor ?? "",
                isOfficial: true
            )
        }
        write(Array(entries), key: WidgetCacheKey.randomPool)
    }

    /// Write liked quotes to the pool. Built from `likedQuoteIds` ∩ `QuoteService.quotes`.
    /// Liked UGC has no Quote object, so for now it is left to the random pool.
    private func writeFavoritePool() {
        let likedIds = LikeService.shared.likedQuoteIds
        let allQuotes = QuoteService.shared.quotes
        let entries = allQuotes
            .filter { likedIds.contains($0.id) }
            .prefix(maxFavoritePoolSize)
            .map { quote in
                WidgetEntryQuote(
                    id: quote.id.uuidString,
                    textJp: quote.textJp,
                    textEn: quote.textEn,
                    authorName: quote.displayAuthor ?? "",
                    isOfficial: true
                )
            }
        write(Array(entries), key: WidgetCacheKey.favoritePool)
    }

    /// Write the current main language to the App Group (@AppStorage is standard UserDefaults, so the
    /// widget cannot read it).
    private func writeLanguage() {
        let raw = UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
        defaults?.set(raw, forKey: WidgetCacheKey.language)
    }

    private func write(_ entries: [WidgetEntryQuote], key: String) {
        guard let defaults else {
            print("⚠️ WidgetCache: App Group defaults nil")
            return
        }
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: key)
            print("📦 WidgetCache: wrote \(entries.count) entries to \(key)")
        } catch {
            print("⚠️ WidgetCache encode failed: \(error)")
        }
    }

    private func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
