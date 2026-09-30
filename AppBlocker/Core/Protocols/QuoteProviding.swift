//
//  QuoteProviding.swift
//  AppBlocker
//
//  Quote provider protocol (designed with v1.1 AWS support in mind)
//

import Foundation

/// Protocol that provides quotes
/// v1.0: LocalQuoteProvider (local JSON)
/// v2.0: SupabaseQuoteProvider (via Supabase)
protocol QuoteProviding {
    /// Get all quotes
    func fetchQuotes() async throws -> [Quote]

    /// Get one random quote
    func getRandomQuote() -> Quote?

    /// For Shield rotation, return a shuffled pool of up to count quotes (synchronous).
    /// Empty array if nothing can be fetched (the caller falls back to another source)
    func getRandomPool(count: Int) -> [Quote]

    /// Get quotes filtered by category
    func fetchQuotes(by category: String) async throws -> [Quote]

    /// Get quotes of a specific Author
    func fetchQuotes(byAuthor authorId: UUID) async throws -> [Quote]
}

// MARK: - Default Implementation
extension QuoteProviding {
    /// Empty by default (only providers that hold everything synchronously override it).
    /// The Supabase provider keeps this default = QuoteService falls back to loaded quotes / Local
    func getRandomPool(count: Int) -> [Quote] { [] }

    func fetchQuotes(by category: String) async throws -> [Quote] {
        let allQuotes = try await fetchQuotes()
        return allQuotes.filter { $0.category == category }
    }

    func fetchQuotes(byAuthor authorId: UUID) async throws -> [Quote] {
        let allQuotes = try await fetchQuotes()
        return allQuotes.filter { $0.authorId == authorId }
    }
}

// MARK: - Error Types
enum QuoteError: LocalizedError {
    case fileNotFound
    case decodingFailed
    case networkError(underlying: Error)
    case noQuotesAvailable

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "名言データファイルが見つかりません"
        case .decodingFailed:
            return "名言データの読み込みに失敗しました"
        case .networkError(let error):
            return "ネットワークエラー: \(error.localizedDescription)"
        case .noQuotesAvailable:
            return "表示できる名言がありません"
        }
    }
}
