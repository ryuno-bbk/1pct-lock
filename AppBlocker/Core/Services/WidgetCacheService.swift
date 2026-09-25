//
//  WidgetCacheService.swift
//  AppBlocker
//
//  AreteWidget 用に「お気に入り名言」「ランダムプール」を App Group へ JSON で書き出すサービス。
//  ウィジェット拡張は Supabase に直接アクセスせず、ここで書き出されたキャッシュだけを読む。
//

import Foundation
import WidgetKit

/// ウィジェットキャッシュ書き出しサービス (main app のみ)。
@MainActor
final class WidgetCacheService {

    static let shared = WidgetCacheService()

    /// ランダムプールの最大件数。多すぎると JSON が肥大化、少なすぎると同じ名言が頻出。
    private let maxRandomPoolSize = 50
    /// お気に入りプールの最大件数。
    private let maxFavoritePoolSize = 100

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.identifier)
    }

    private init() {}

    // MARK: - Public

    /// 全プールをまとめて書き出して timeline を reload。起動時 / サインイン時に呼ぶ。
    func refreshAll() {
        writeLanguage()
        writeRandomPool()
        writeFavoritePool()
        reload()
    }

    /// いいね変更時に呼ぶ。お気に入りプールのみ更新 + reload。
    func refreshFavorites() {
        writeFavoritePool()
        reload()
    }

    /// 言語設定変更時に呼ぶ。
    func refreshLanguage() {
        writeLanguage()
        reload()
    }

    // MARK: - Private

    /// 公式 quote + 自分以外の UGC からランダムにサンプリングしてプールに書き出す。
    /// ⚠️ FeedService の recommended キャッシュは別 RPC 経由でブロック済みユーザーを除外しているが、
    /// このプールではシンプルに QuoteService の在庫から作る (ウィジェットは個人化を強くしない設計)。
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

    /// いいね済み quote をプールに書き出す。`likedQuoteIds` ∩ `QuoteService.quotes` で構築。
    /// UGC のいいねは Quote オブジェクトを持っていないので、今回はランダムプール側に任せる。
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

    /// 現在のメイン言語を App Group に書き出す (@AppStorage は standard UserDefaults なのでウィジェットから読めない)。
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
