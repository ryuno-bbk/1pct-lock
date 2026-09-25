//
//  LikeService.swift
//  AppBlocker
//
//  名言いいね管理サービス（Supabase）
//

import Foundation
import Combine
import Supabase

/// 名言のいいね/取り消し管理
final class LikeService: ObservableObject {

    static let shared = LikeService()

    // MARK: - Published Properties

    @Published private(set) var likedQuoteIds: Set<UUID> = []
    @Published private(set) var likedQuotes: [Quote] = []
    @Published private(set) var likedPostIds: Set<UUID> = []
    /// 🔴 2026-08-08 追加: いいねした UGC 投稿の実体。
    /// これが無かったため、プロフィールの「いいね」タブが likedQuotes しか出せず、
    /// **公式アカウントの名言以外 (= 普通のユーザーの投稿) へのいいねが一切表示されなかった**。
    @Published private(set) var likedPosts: [UserPost] = []

    // MARK: - Private Properties

    private let client: SupabaseClient

    /// お気に入りWidget反映のデバウンス用 Task (L2)。いいね連打のたびに
    /// WidgetCenter.reloadAllTimelines() + プール全書き出しが走ると無駄なので、
    /// 新しいトグルが来たら前の待機をキャンセルし、最後のトグルから2秒後に1回だけ反映する
    private var widgetFavoritesRefreshTask: Task<Void, Never>?

    // MARK: - Init

    private init(
        client: SupabaseClient = SupabaseManager.shared.client
    ) {
        self.client = client
    }

    // MARK: - Public Methods

    /// いいね状態を確認 (公式名言)
    func isLiked(quoteId: UUID) -> Bool {
        likedQuoteIds.contains(quoteId)
    }

    /// いいね状態を確認 (UGC 投稿)
    func isLikedPost(postId: UUID) -> Bool {
        likedPostIds.contains(postId)
    }

    /// UGC 投稿いいね/取消 (toggle_post_like RPC)
    @MainActor
    func togglePostLike(postId: UUID) async {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ togglePostLike ignored: not signed in")
            return
        }

        let wasLiked = isLikedPost(postId: postId)

        // 楽観 UI
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
                // 2026-08-08: いいねタブに出している実体からも外す (タブを開き直さなくても消える)
                likedPosts.removeAll { $0.id == postId }
            }
            print(result.isLiked
                  ? "❤️ Liked post: \(postId) (server count=\(result.likeCount))"
                  : "💔 Unliked post: \(postId) (server count=\(result.likeCount))")
        } catch {
            // ロールバック
            if wasLiked {
                likedPostIds.insert(postId)
            } else {
                likedPostIds.remove(postId)
            }
            print("⚠️ togglePostLike failed: \(error)")
        }
    }

    /// いいね/取り消し切り替え
    func toggleLike(quoteId: UUID) async {
        await performToggle(quoteId: quoteId)
    }

    /// いいねを追加（既にいいね済みなら何もしない）
    @MainActor
    func like(quoteId: UUID) async {
        guard !isLiked(quoteId: quoteId) else { return }
        await performToggle(quoteId: quoteId)
    }

    /// いいねを取り消し（未いいねなら何もしない）
    @MainActor
    func unlike(quoteId: UUID) async {
        guard isLiked(quoteId: quoteId) else { return }
        await performToggle(quoteId: quoteId)
    }

    // MARK: - Private Methods

    /// toggle_quote_like RPC で user_likes と quotes.like_count を 1 トランザクション更新。
    /// RPC 戻り値の is_liked を server-authoritative として最終状態に反映する。
    @MainActor
    private func performToggle(quoteId: UUID) async {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ toggleLike ignored: not signed in")
            return
        }

        let wasLiked = isLiked(quoteId: quoteId)

        // 楽観 UI 更新
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

            // RPC 結果で確定値を反映（楽観 UI とサーバ実状態のズレを補正）
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
            // 失敗時は元状態にロールバック
            if wasLiked {
                likedQuoteIds.insert(quoteId)
            } else {
                likedQuoteIds.remove(quoteId)
            }
            print("⚠️ toggleLike failed: \(error)")
        }
    }

    /// お気に入りWidgetキャッシュの反映を2秒デバウンスする (L2)。
    /// 前回分の待機 Task をキャンセルしてから積み直すので、連打中は発火せず、
    /// 最後のトグルから2秒後に必ず1回だけ WidgetCacheService.refreshFavorites() が走る
    @MainActor
    private func scheduleWidgetFavoritesRefresh() {
        widgetFavoritesRefreshTask?.cancel()
        widgetFavoritesRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            WidgetCacheService.shared.refreshFavorites()
        }
    }

    /// 起動時にいいね一覧を読み込み (quote_id + post_id 両方)
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

            // いいね済み名言オブジェクトも読み込み
            await loadLikedQuoteObjects()
            // 2026-08-08: 投稿側も同時に読む。これが無いと「いいね」タブに投稿が出ない
            await loadLikedPostObjects()
        } catch {
            print("⚠️ Failed to load likes: \(error)")
        }
    }

    /// いいねした UGC 投稿の実体を取得 (2026-08-08 追加)。
    /// ⚠️ likedPostIds は user_likes から取れるが、実体を引かないと画面に出せない。
    /// 名言側の loadLikedQuoteObjects と対になる処理。
    /// 削除済み投稿やモデレーションで落ちた投稿は単に返ってこないので、自然に消える。
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

    /// いいねした投稿の著者情報。
    /// ⚠️ user_posts には著者名もアバターも入っていないので別途引く必要がある。
    /// これが無いと詳細を開いた時に **他人の投稿に自分の名前とアイコンが出る**
    /// (MyPostsFeedView は authorDisplayName が nil だと auth.displayName に落ちるため)
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

    /// いいね解除した投稿をグリッドから即座に消す (再取得を待たない)
    @MainActor
    func removeFromLikedPosts(postId: UUID) {
        likedPosts.removeAll { $0.id == postId }
    }

    /// いいね済み名言をJOIN付きで取得
    @MainActor
    func loadLikedQuoteObjects() async {
        guard !likedQuoteIds.isEmpty else {
            likedQuotes = []
            return
        }

        // QuoteServiceのキャッシュから取得（高速）
        let allQuotes = QuoteService.shared.quotes
        if !allQuotes.isEmpty {
            likedQuotes = allQuotes.filter { likedQuoteIds.contains($0.id) }
            return
        }

        // フォールバック: Supabaseから直接取得
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

    /// ローカルのlikedQuotesリストを更新（いいね追加時）
    @MainActor
    func addToLikedQuotes(_ quote: Quote) {
        if !likedQuotes.contains(where: { $0.id == quote.id }) {
            likedQuotes.insert(quote, at: 0)
        }
    }

    /// ローカルのlikedQuotesリストから削除（いいね取り消し時）
    @MainActor
    func removeFromLikedQuotes(quoteId: UUID) {
        likedQuotes.removeAll { $0.id == quoteId }
    }
}
