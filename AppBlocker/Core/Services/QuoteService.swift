//
//  QuoteService.swift
//  AppBlocker
//
//  Quote fetching service (v1.0: local, v2.0: Supabase support)
//

import Foundation
import Combine
import Supabase

/// v1.0 local quote provider
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
        // Try the bundled JSON first
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

        // Fallback: use sample data
        cachedQuotes = Quote.samples
    }
}

// MARK: - QuoteService (Facade)

/// Facade for the quote service
/// The provider can be switched (Local ↔ Supabase)
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

    /// Switch the provider (used when switching to Supabase)
    func setProvider(_ newProvider: QuoteProviding) {
        self.provider = newProvider
    }

    /// Switch to the Supabase provider
    func enableSupabase() {
        setProvider(SupabaseQuoteProvider())
    }

    /// Load quotes
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

    /// Load all authors (from Supabase)
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

    /// Get the quotes of a specific Author
    func fetchQuotesByAuthor(authorId: UUID) async throws -> [Quote] {
        return try await provider.fetchQuotes(byAuthor: authorId)
    }

    /// Switch to a random quote
    func shuffleQuote() {
        currentQuote = provider.getRandomQuote()
    }

    /// Get the quote pool for Shield rotation.
    /// Falls back in the order provider (Supabase returns empty) → loaded quotes → Local bundle,
    /// so it always returns a non-empty pool, even offline / on a fresh install
    func randomPool(count: Int) -> [Quote] {
        let fromProvider = provider.getRandomPool(count: count)
        if !fromProvider.isEmpty { return fromProvider }
        if !quotes.isEmpty { return Array(quotes.shuffled().prefix(count)) }
        return LocalQuoteProvider().getRandomPool(count: count)
    }

    /// Select a specific quote
    func selectQuote(_ quote: Quote) {
        currentQuote = quote
    }
}
