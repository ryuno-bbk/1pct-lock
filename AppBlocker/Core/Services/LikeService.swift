//
//  LikeService.swift
//  AppBlocker
//
//  Quote like management service (Supabase)
//

import Foundation
import Combine
import Supabase

/// Manages liking/unliking quotes
final class LikeService: ObservableObject {

    static let shared = LikeService()

    // MARK: - Published Properties

    @Published private(set) var likedQuoteIds: Set<UUID> = []
    @Published private(set) var likedQuotes: [Quote] = []
    @Published private(set) var likedPostIds: Set<UUID> = []
    /// 🔴 Added 2026-08-08: the actual objects of liked UGC posts.
    /// Without this, the profile's "いいね" ("Likes") tab could only show likedQuotes, and
    /// **likes on anything other than the official account's quotes (= posts by regular users) were not
    /// shown at all**.
    @Published private(set) var likedPosts: [UserPost] = []

    // MARK: - Private Properties

    private let client: SupabaseClient

    /// Debounce Task for reflecting favorites in the Widget (L2). Running
    /// WidgetCenter.reloadAllTimelines() + writing out the whole pool on every rapid like tap is
    /// wasteful, so when a new toggle comes, the previous wait is cancelled and it is applied only once,
    /// 2 seconds after the last toggle
    private var widgetFavoritesRefreshTask: Task<Void, Never>?

    // MARK: - Init

    private init(
        client: SupabaseClient = SupabaseManager.shared.client
    ) {
        self.client = client
    }

    // MARK: - Public Methods

    /// Check the like state (official quote)
    func isLiked(quoteId: UUID) -> Bool {
        likedQuoteIds.contains(quoteId)
    }

    /// Check the like state (UGC post)
    func isLikedPost(postId: UUID) -> Bool {
        likedPostIds.contains(postId)
    }

    /// Like/unlike a UGC post (toggle_post_like RPC)
    @MainActor
    func togglePostLike(postId: UUID) async {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ togglePostLike ignored: not signed in")
            return
        }

        let wasLiked = isLikedPost(postId: postId)

        // Optimistic UI
        if wasLiked {
            likedPostIds.remove(postId)
        } else {
            likedPostIds.insert(postId)
        }

        struct ToggleResult: Decodable {
            let isLiked: Bool
            let likeCount: Int

            enum CodingKeys: String, CodingKey {
                case isLiked   = "is_liked"
                case likeCount = "like_count"
            }
        }

        do {
            let result: ToggleResult = try await client
                .rpc("toggle_post_like", params: ["target_post_id": postId.uuidString])
                .execute()
                .value

            if result.isLiked {
                likedPostIds.insert(postId)
            } else {
                likedPostIds.remove(postId)
                // 2026-08-08: also remove it from the objects shown in the likes tab (it disappears without
                // reopening the tab)
                likedPosts.removeAll { $0.id == postId }
            }
            print(result.isLiked
                  ? "❤️ Liked post: \(postId) (server count=\(result.likeCount))"
                  : "💔 Unliked post: \(postId) (server count=\(result.likeCount))")
        } catch {
            // Rollback
            if wasLiked {
                likedPostIds.insert(postId)
            } else {
                likedPostIds.remove(postId)
            }
            print("⚠️ togglePostLike failed: \(error)")
        }
    }

    /// Toggle like/unlike
    func toggleLike(quoteId: UUID) async {
        await performToggle(quoteId: quoteId)
    }

    /// Add a like (does nothing if already liked)
    @MainActor
    func like(quoteId: UUID) async {
        guard !isLiked(quoteId: quoteId) else { return }
        await performToggle(quoteId: quoteId)
    }

    /// Remove a like (does nothing if not liked)
    @MainActor
    func unlike(quoteId: UUID) async {
        guard isLiked(quoteId: quoteId) else { return }
        await performToggle(quoteId: quoteId)
    }

    // MARK: - Private Methods

    /// The toggle_quote_like RPC updates user_likes and quotes.like_count in 1 transaction.
    /// The is_liked in the RPC return value is treated as server-authoritative and applied as the final
    /// state.
    @MainActor
    private func performToggle(quoteId: UUID) async {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ toggleLike ignored: not signed in")
            return
        }

        let wasLiked = isLiked(quoteId: quoteId)

        // Optimistic UI update
        if wasLiked {
            likedQuoteIds.remove(quoteId)
        } else {
            likedQuoteIds.insert(quoteId)
        }

        struct ToggleResult: Decodable {
            let isLiked: Bool
            let likeCount: Int

            enum CodingKeys: String, CodingKey {
                case isLiked   = "is_liked"
                case likeCount = "like_count"
            }
        }

        do {
            let result: ToggleResult = try await client
                .rpc("toggle_quote_like", params: ["target_quote_id": quoteId.uuidString])
                .execute()
                .value

            // Apply the confirmed value from the RPC result (corrects drift between the optimistic UI and the
            // real server state)
            if result.isLiked {
                likedQuoteIds.insert(quoteId)
            } else {
                likedQuoteIds.remove(quoteId)
            }
            print(result.isLiked
                  ? "❤️ Liked quote: \(quoteId) (server count=\(result.likeCount))"
                  : "💔 Unliked quote: \(quoteId) (server count=\(result.likeCount))")
            scheduleWidgetFavoritesRefresh()
        } catch {
            // On failure, roll back to the original state
            if wasLiked {
                likedQuoteIds.insert(quoteId)
            } else {
                likedQuoteIds.remove(quoteId)
            }
            print("⚠️ toggleLike failed: \(error)")
        }
    }

    /// Debounce the favorites Widget cache refresh by 2 seconds (L2).
    /// The previous waiting Task is cancelled before a new one is queued, so it does not fire during
    /// rapid taps, and WidgetCacheService.refreshFavorites() always runs exactly once, 2 seconds after
    /// the last toggle
    @MainActor
    private func scheduleWidgetFavoritesRefresh() {
        widgetFavoritesRefreshTask?.cancel()
        widgetFavoritesRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            WidgetCacheService.shared.refreshFavorites()
        }
    }

    /// Load the like list at launch (both quote_id + post_id)
    @MainActor
    func loadLikedQuotes() async {
        guard let userId = UserAuthService.shared.userId else {
            likedQuoteIds = []
            likedQuotes = []
            likedPostIds = []
            likedPosts = []
            return
        }

        do {
            struct LikeRow: Decodable {
                let quoteId: UUID?
                let postId: UUID?

                enum CodingKeys: String, CodingKey {
                    case quoteId = "quote_id"
                    case postId  = "post_id"
                }
            }

            let rows: [LikeRow] = try await client
                .from("user_likes")
                .select("quote_id, post_id")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            likedQuoteIds = Set(rows.compactMap { $0.quoteId })
            likedPostIds  = Set(rows.compactMap { $0.postId })
            print("📚 Loaded \(likedQuoteIds.count) liked quotes, \(likedPostIds.count) liked posts")

            // Also load the liked quote objects
            await loadLikedQuoteObjects()
            // 2026-08-08: also load the post side at the same time. Without this, posts do not appear in the
            // "いいね" ("Likes") tab
            await loadLikedPostObjects()
        } catch {
            print("⚠️ Failed to load likes: \(error)")
        }
    }

    /// Fetch the actual objects of liked UGC posts (added 2026-08-08).
    /// ⚠️ likedPostIds can be taken from user_likes, but they cannot be shown on screen without fetching
    /// the objects. The counterpart of loadLikedQuoteObjects on the quote side.
    /// Deleted posts and posts removed by moderation are simply not returned, so they disappear
    /// naturally.
    @MainActor
    func loadLikedPostObjects() async {
        guard !likedPostIds.isEmpty else {
            likedPosts = []
            return
        }
        do {
            let posts: [UserPost] = try await client
                .from("user_posts")
                .select()
                .in("id", values: likedPostIds.map { $0.uuidString })
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
            likedPosts = posts
            print("📚 Loaded \(posts.count) liked post objects")
            await loadLikedPostAuthors(for: posts)
        } catch {
            print("⚠️ Failed to load liked posts: \(error)")
        }
    }

    /// Author info of liked posts.
    /// ⚠️ user_posts has neither the author name nor the avatar, so they must be fetched separately.
    /// Without this, opening the detail shows **your own name and icon on someone else's post**
    /// (MyPostsFeedView falls back to auth.displayName when authorDisplayName is nil)
    struct LikedPostAuthor {
        let displayName: String?
        let avatarUrl: String?
        let isPro: Bool
    }

    @Published private(set) var likedPostAuthors: [UUID: LikedPostAuthor] = [:]

    @MainActor
    private func loadLikedPostAuthors(for posts: [UserPost]) async {
        let ids = Set(posts.map { $0.userId })
        guard !ids.isEmpty else {
            likedPostAuthors = [:]
            return
        }
        struct UserRow: Decodable {
            let id: UUID
            let displayName: String?
            let avatarUrl: String?
            let isPro: Bool?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case avatarUrl   = "avatar_url"
                case isPro       = "is_pro"
            }
        }
        do {
            let rows: [UserRow] = try await client
                .from("users")
                .select("id, display_name, avatar_url, is_pro")
                .in("id", values: ids.map { $0.uuidString })
                .execute()
                .value
            likedPostAuthors = Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0.id, LikedPostAuthor(displayName: $0.displayName,
                                            avatarUrl: $0.avatarUrl,
                                            isPro: $0.isPro ?? false))
                }
            )
        } catch {
            print("⚠️ Failed to load liked post authors: \(error)")
        }
    }

    /// Remove an unliked post from the grid immediately (without waiting for a refetch)
    @MainActor
    func removeFromLikedPosts(postId: UUID) {
        likedPosts.removeAll { $0.id == postId }
    }

    /// Fetch liked quotes with a JOIN
    @MainActor
    func loadLikedQuoteObjects() async {
        guard !likedQuoteIds.isEmpty else {
            likedQuotes = []
            return
        }

        // Get from the QuoteService cache (fast)
        let allQuotes = QuoteService.shared.quotes
        if !allQuotes.isEmpty {
            likedQuotes = allQuotes.filter { likedQuoteIds.contains($0.id) }
            return
        }

        // Fallback: fetch directly from Supabase
        do {
            struct QuoteRow: Decodable {
                let id: UUID
                let authorId: UUID
                let textEn: String
                let textJp: String
                let category: String?
                let likeCount: Int
                let authors: AuthorRow?

                enum CodingKeys: String, CodingKey {
                    case id
                    case authorId = "author_id"
                    case textEn = "text_en"
                    case textJp = "text_jp"
                    case category
                    case likeCount = "like_count"
                    case authors
                }

                struct AuthorRow: Decodable {
                    let name: String
                    let bioEn: String
                    let bioJp: String

                    enum CodingKeys: String, CodingKey {
                        case name
                        case bioEn = "bio_en"
                        case bioJp = "bio_jp"
                    }
                }
            }

            let rows: [QuoteRow] = try await client
                .from("quotes")
                .select("*, authors(name, bio_en, bio_jp)")
                .in("id", values: likedQuoteIds.map { $0.uuidString })
                .execute()
                .value

            likedQuotes = rows.map { row in
                Quote(
                    id: row.id,
                    authorId: row.authorId,
                    textEn: row.textEn,
                    textJp: row.textJp,
                    author: row.authors?.name ?? "",
                    authorBioEn: row.authors?.bioEn ?? "",
                    authorBioJp: row.authors?.bioJp ?? "",
                    category: row.category,
                    likeCount: row.likeCount
                )
            }
        } catch {
            print("⚠️ Failed to load liked quote objects: \(error)")
        }
    }

    /// Update the local likedQuotes list (when a like is added)
    @MainActor
    func addToLikedQuotes(_ quote: Quote) {
        if !likedQuotes.contains(where: { $0.id == quote.id }) {
            likedQuotes.insert(quote, at: 0)
        }
    }

    /// Remove from the local likedQuotes list (when a like is removed)
    @MainActor
    func removeFromLikedQuotes(quoteId: UUID) {
        likedQuotes.removeAll { $0.id == quoteId }
    }
}
