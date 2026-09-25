//
//  QuoteProviding.swift
//  AppBlocker
//
//  名言提供プロトコル（v1.1 AWS対応を見越した設計）
//

import Foundation

/// 名言を提供するプロトコル
/// v1.0: LocalQuoteProvider（ローカルJSON）
/// v2.0: SupabaseQuoteProvider（Supabase経由）
protocol QuoteProviding {
    /// すべての名言を取得
    func fetchQuotes() async throws -> [Quote]

    /// ランダムな名言を1つ取得
    func getRandomQuote() -> Quote?

    /// Shield ローテーション用に、シャッフル済みの名言プールを最大 count 件返す (同期)。
    /// 取得できなければ空配列 (呼び出し側で別ソースにフォールバックする)
    func getRandomPool(count: Int) -> [Quote]

    /// カテゴリでフィルタリングした名言を取得
    func fetchQuotes(by category: String) async throws -> [Quote]

    /// 特定のAuthorの名言を取得
    func fetchQuotes(byAuthor authorId: UUID) async throws -> [Quote]
}

// MARK: - Default Implementation
extension QuoteProviding {
    /// デフォルトは空 (同期的に全件を持つプロバイダーのみ override する)。
    /// Supabase プロバイダーはこのデフォルトのまま = QuoteService 側で loaded quotes / Local にフォールバック
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
