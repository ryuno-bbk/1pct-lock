//
//  QuoteService.swift
//  AppBlocker
//
//  名言取得サービス（v1.0: ローカル、v2.0: Supabase対応）
//

import Foundation
import Combine
import Supabase

/// v1.0 ローカル名言プロバイダー
final class LocalQuoteProvider: QuoteProviding {

    private var cachedQuotes: [Quote] = []

    init() {
        loadQuotesFromBundle()
    }

    // MARK: - QuoteProviding

    func fetchQuotes() async throws -> [Quote] {
        if cachedQuotes.isEmpty {
            loadQuotesFromBundle()
        }

        guard !cachedQuotes.isEmpty else {
            throw QuoteError.noQuotesAvailable
        }

        return cachedQuotes
    }

    func getRandomQuote() -> Quote? {
        if cachedQuotes.isEmpty {
            loadQuotesFromBundle()
        }
        return cachedQuotes.randomElement()
    }

    func getRandomPool(count: Int) -> [Quote] {
        if cachedQuotes.isEmpty {
            loadQuotesFromBundle()
        }
        return Array(cachedQuotes.shuffled().prefix(count))
    }

    // MARK: - Private

    private func loadQuotesFromBundle() {
        // まずバンドルのJSONを試す
        if let url = Bundle.main.url(forResource: "Quotes", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                cachedQuotes = try decoder.decode([Quote].self, from: data)
                return
            } catch {
                print("Failed to load quotes from bundle: \(error)")
            }
        }

        // フォールバック: サンプルデータを使用
        cachedQuotes = Quote.samples
    }
}

// MARK: - QuoteService (Facade)

/// 名言サービスのファサード
/// プロバイダーを切り替え可能（Local ↔ Supabase）
final class QuoteService: ObservableObject {

    static let shared = QuoteService()

    @Published private(set) var quotes: [Quote] = []
    @Published private(set) var authors: [Author] = []
    @Published private(set) var currentQuote: Quote?
    @Published private(set) var isLoading: Bool = false
    @Published var error: QuoteError?

    private var provider: QuoteProviding

    init(provider: QuoteProviding = LocalQuoteProvider()) {
        self.provider = provider
        self.currentQuote = provider.getRandomQuote()
    }

    /// プロバイダーを切り替え（Supabaseに切り替え時に使用）
    func setProvider(_ newProvider: QuoteProviding) {
        self.provider = newProvider
    }

    /// Supabaseプロバイダーに切り替え
    func enableSupabase() {
        setProvider(SupabaseQuoteProvider())
    }

    /// 名言を読み込み
    @MainActor
    func loadQuotes() async {
        isLoading = true
        error = nil

        do {
            quotes = try await provider.fetchQuotes()
            if currentQuote == nil {
                currentQuote = quotes.randomElement()
            }
        } catch let quoteError as QuoteError {
            error = quoteError
        } catch {
            self.error = .networkError(underlying: error)
        }

        isLoading = false
    }

    /// 全著者を読み込み（Supabaseから）
    @MainActor
    func loadAuthors() async {
        do {
            let fetchedAuthors: [Author] = try await SupabaseManager.shared.client
                .from("authors")
                .select()
                .order("name")
                .execute()
                .value

            authors = fetchedAuthors
            print("📚 Loaded \(authors.count) authors")
        } catch {
            print("⚠️ Failed to load authors: \(error)")
        }
    }

    /// 特定のAuthorの名言を取得
    func fetchQuotesByAuthor(authorId: UUID) async throws -> [Quote] {
        return try await provider.fetchQuotes(byAuthor: authorId)
    }

    /// ランダムな名言に切り替え
    func shuffleQuote() {
        currentQuote = provider.getRandomQuote()
    }

    /// Shield ローテーション用の名言プールを取得。
    /// provider (Supabase は空を返す) → loaded quotes → Local バンドル の順にフォールバックし、
    /// オフライン/フレッシュインストールでも必ず非空のプールを返す
    func randomPool(count: Int) -> [Quote] {
        let fromProvider = provider.getRandomPool(count: count)
        if !fromProvider.isEmpty { return fromProvider }
        if !quotes.isEmpty { return Array(quotes.shuffled().prefix(count)) }
        return LocalQuoteProvider().getRandomPool(count: count)
    }

    /// 特定の名言を選択
    func selectQuote(_ quote: Quote) {
        currentQuote = quote
    }
}
