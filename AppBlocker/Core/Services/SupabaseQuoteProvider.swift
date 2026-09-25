//
//  SupabaseQuoteProvider.swift
//  AppBlocker
//
//  Supabase経由の名言プロバイダー（v2.0）
//

import Foundation
import Supabase

/// Supabaseから名言を取得するプロバイダー
final class SupabaseQuoteProvider: QuoteProviding {

    private let client: SupabaseClient
    private let fallback: LocalQuoteProvider
    private var cachedQuotes: [Quote] = []

    /// Supabaseから取得した生データ（author JOIN済み）
    private struct SupabaseQuoteRow: Decodable {
        let id: UUID
        let authorId: UUID
        let textEn: String
        let textJp: String
        let category: String?
        let likeCount: Int
        let commentCount: Int?
        let createdAt: String?
        let authors: AuthorRow?

        enum CodingKeys: String, CodingKey {
            case id
            case authorId = "author_id"
            case textEn = "text_en"
            case textJp = "text_jp"
            case category
            case likeCount = "like_count"
            case commentCount = "comment_count"
            case createdAt = "created_at"
            case authors
        }

        struct AuthorRow: Decodable {
            let id: UUID
            let name: String
            let bioEn: String
            let bioJp: String
            let nationality: String?
            let imageUrl: String?

            enum CodingKeys: String, CodingKey {
                case id, name
                case bioEn = "bio_en"
                case bioJp = "bio_jp"
                case nationality
                case imageUrl = "image_url"
            }
        }
    }

    init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
        self.fallback = LocalQuoteProvider()
    }

    // MARK: - QuoteProviding

    func fetchQuotes() async throws -> [Quote] {
        do {
            let rows: [SupabaseQuoteRow] = try await client
                .from("quotes")
                .select("*, authors(*)")
                .execute()
                .value

            cachedQuotes = rows.map { row in
                Quote(
                    id: row.id,
                    authorId: row.authorId,
                    textEn: row.textEn,
                    textJp: row.textJp,
                    author: row.authors?.name ?? "",
                    authorBioEn: row.authors?.bioEn ?? "",
                    authorBioJp: row.authors?.bioJp ?? "",
                    category: row.category,
                    likeCount: row.likeCount,
                    commentCount: row.commentCount ?? 0
                )
            }

            return cachedQuotes
        } catch {
            print("⚠️ Supabase fetch failed, falling back to local: \(error)")
            return try await fallback.fetchQuotes()
        }
    }

    func getRandomQuote() -> Quote? {
        if cachedQuotes.isEmpty {
            return fallback.getRandomQuote()
        }
        return cachedQuotes.randomElement()
    }

    func fetchQuotes(by category: String) async throws -> [Quote] {
        do {
            let rows: [SupabaseQuoteRow] = try await client
                .from("quotes")
                .select("*, authors(*)")
                .eq("category", value: category)
                .execute()
                .value

            return rows.map { row in
                Quote(
                    id: row.id,
                    authorId: row.authorId,
                    textEn: row.textEn,
                    textJp: row.textJp,
                    author: row.authors?.name ?? "",
                    authorBioEn: row.authors?.bioEn ?? "",
                    authorBioJp: row.authors?.bioJp ?? "",
                    category: row.category,
                    likeCount: row.likeCount,
                    commentCount: row.commentCount ?? 0
                )
            }
        } catch {
            print("⚠️ Supabase category fetch failed, falling back to local: \(error)")
            return try await fallback.fetchQuotes(by: category)
        }
    }

    func fetchQuotes(byAuthor authorId: UUID) async throws -> [Quote] {
        do {
            let rows: [SupabaseQuoteRow] = try await client
                .from("quotes")
                .select("*, authors(*)")
                .eq("author_id", value: authorId.uuidString)
                .execute()
                .value

            return rows.map { row in
                Quote(
                    id: row.id,
                    authorId: row.authorId,
                    textEn: row.textEn,
                    textJp: row.textJp,
                    author: row.authors?.name ?? "",
                    authorBioEn: row.authors?.bioEn ?? "",
                    authorBioJp: row.authors?.bioJp ?? "",
                    category: row.category,
                    likeCount: row.likeCount,
                    commentCount: row.commentCount ?? 0
                )
            }
        } catch {
            print("⚠️ Supabase author fetch failed: \(error)")
            return try await fallback.fetchQuotes(byAuthor: authorId)
        }
    }
}
