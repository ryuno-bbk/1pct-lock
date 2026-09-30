//
//  UserPostService.swift
//  AppBlocker
//
//  UGC: fetch / insert / delete for user posts
//

import Foundation
import Combine
import Supabase

@MainActor
final class UserPostService: ObservableObject {

    static let shared = UserPostService()

    // My posts (for MyProfileView)
    @Published private(set) var myPosts: [UserPost] = []

    // Other users' posts (for UserProfileView). A keyed store held per userId.
    // UserProfileView can be pushed again on top of itself in the stack (there are paths that open another
    // user's profile from the author tap in FeedCardListView / LikersSheet / CommentPageView), so
    // with a single slot the inner profile would overwrite/clear the outer profile's data.
    // Holding an array per user keeps the correct data no matter which profile screen is in front
    // (the cost of holding post arrays for a few users in memory is acceptable).
    @Published private(set) var viewingPostsByUser: [UUID: [UserPost]] = [:]

    /// Post list of the given user (empty array if not loaded)
    func viewingPosts(for userId: UUID) -> [UserPost] {
        viewingPostsByUser[userId] ?? []
    }

    @Published private(set) var isCreating: Bool = false

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// 073: The value written to user_posts.lang when posting. Uses the same reading as
    /// AppBlockerApp.init() / WidgetCacheService: "device default language if the mainLanguage key is unset"
    private func currentMainLanguageRaw() -> String {
        UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
    }

    // MARK: - My posts

    func loadMyPosts() async {
        guard let userId = UserAuthService.shared.userId else {
            myPosts = []
            return
        }

        do {
            let posts: [UserPost] = try await client
                .from("user_posts")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
            // L11: If a sign-out/switch to another account happened after loading started,
            // the previous user's post list would be written into the new state (myPosts).
            // Apply the result only if the userId at completion matches the one at the start
            guard UserAuthService.shared.userId == userId else {
                print("⚠️ loadMyPosts discarded: user changed during load")
                return
            }
            myPosts = posts
            print("📚 Loaded \(myPosts.count) own posts")
        } catch {
            print("⚠️ Failed to load my posts: \(error)")
        }
    }

    // MARK: - Other users' posts

    /// Fetch userId's posts and write them to viewingPostsByUser[userId] (refreshed on every call).
    /// Even if UserProfileView is stacked on top of itself several times, each writes to a different key, so
    /// they do not overwrite each other's data
    func loadPosts(byUser userId: UUID) async {
        do {
            let posts: [UserPost] = try await client
                .from("user_posts")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            viewingPostsByUser[userId] = posts
            print("📚 Loaded \(posts.count) posts for user \(userId)")
        } catch {
            print("⚠️ Failed to load posts by user: \(error)")
        }
    }

    /// Discard the cache for all users on sign-out/account switch.
    /// Not called on a normal pop of the profile screen (by design the cache is kept while stacked)
    func clearAllViewingUsers() {
        viewingPostsByUser = [:]
    }

    /// L11 (2026-07-22 audit): Added because myPosts (my own post list on My Page) remained
    /// after sign-out. viewingPostsByUser (other users' post cache) is delegated to the existing
    /// clearAllViewingUsers().
    func clearAllForSignOut() {
        myPosts = []
        clearAllViewingUsers()
    }

    // MARK: - Single fetch (from a notification tap etc.)

    /// Fetch 1 post by post_id (nil if not found)
    func fetchPost(id postId: UUID) async -> UserPost? {
        do {
            let post: UserPost = try await client
                .from("user_posts")
                .select()
                .eq("id", value: postId.uuidString)
                .single()
                .execute()
                .value
            return post
        } catch {
            print("⚠️ fetchPost failed for \(postId): \(error)")
            return nil
        }
    }

    // MARK: - Create post

    /// Create a post (on success, insert at the head of myPosts)
    /// Only one of textJp / textEn is OK (at least 1 is required, both nil is not allowed)
    /// Character limits: jp <= 200, en <= 400
    /// backgroundId: index into BackgroundImageProvider (if nil, assigned automatically by hash)
    func createPost(
        textJp: String?,
        textEn: String?,
        tags: [String],
        backgroundId: Int? = nil
    ) async -> UserPost? {
        guard let userId = UserAuthService.shared.userId else {
            print("⚠️ createPost ignored: not signed in")
            return nil
        }

        let trimmedJp = textJp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedEn = textEn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedJp: String? = trimmedJp.isEmpty ? nil : trimmedJp
        let cleanedEn: String? = trimmedEn.isEmpty ? nil : trimmedEn
        guard cleanedJp != nil || cleanedEn != nil else { return nil }
        if let jp = cleanedJp, jp.count > 200 { return nil }
        if let en = cleanedEn, en.count > 400 { return nil }
        let cleanedTags = Array(tags.filter { !$0.isEmpty }.prefix(3))

        // Validity check of background_id (treated as nil if out of range)
        let cleanedBackgroundId: Int? = {
            guard let id = backgroundId, id >= 0, id < BackgroundImageProvider.count else { return nil }
            return id
        }()

        isCreating = true
        defer { isCreating = false }

        struct InsertRow: Encodable {
            let user_id: String
            let text_jp: String?
            let text_en: String?
            let tags: [String]
            let background_id: Int?
            let lang: String
        }

        let row = InsertRow(
            user_id: userId.uuidString,
            text_jp: cleanedJp,
            text_en: cleanedEn,
            tags: cleanedTags,
            background_id: cleanedBackgroundId,
            // 073: Record the author's device language (input for the same-language priority scoring of the feed)
            lang: currentMainLanguageRaw()
        )

        do {
            let inserted: UserPost = try await client
                .from("user_posts")
                .insert(row)
                .select()
                .single()
                .execute()
                .value
            myPosts.insert(inserted, at: 0)
            print("✅ Created post: \(inserted.id)")
            return inserted
        } catch {
            print("⚠️ Failed to create post: \(error)")
            return nil
        }
    }

    // MARK: - Create post v2 (background + baked-in image of freely placed text, supports multiple images)

    /// Post v2: the caller has already baked the text into one JPEG per image. The DB holds only
    /// title/tags/image_path (first image)/image_count/overlays.
    /// - Parameters:
    ///   - id: UUID assigned on the client (set explicitly so the Storage path and user_posts.id match)
    ///   - title: optional title (may contain # tags, up to 60 characters. Anything over is truncated)
    ///   - tags: 0-3 (chosen from the existing tag pool, same constraints as createPost)
    ///   - images: array of baked-in JPEG data (1 to 4 images, the first is the cover image)
    ///   - overlays: raw text + placement info for re-editing/search/moderation (linked to an image by
    ///     imageIndex)
    /// - Returns: on success the inserted UserPost (optimistically applied to the head of myPosts), nil on
    ///   failure
    /// The kind of the most recent post failure (for choosing the message for the 046 rate limit of 5
    /// posts/24h. The caller reads it right after createPostV2 returns nil)
    enum CreateFailure {
        case rateLimited
        case other
    }
    private(set) var lastCreateFailure: CreateFailure?

    /// Daily post limit. Keep the number in sync with the server-side enforce_post_rate_limit (052=10 → 057=5)
    static let dailyPostLimit = 5

    /// Return the remaining slots from my post count in the last 24 hours (for the remaining count shown in
    /// PostConfirmView). nil on failure (the caller just hides the display; posting itself is not blocked)
    ///
    /// 068: Changed from counting existing rows in user_posts to the get_post_quota_used RPC (rate_events
    /// ledger). The old way caused a mismatch: "deleting a post increases the remaining slots on screen,
    /// but the server (already ledger-based since 066) does not count a deletion as restoring a slot, so
    /// the post gets rejected" (found in a real device test on 2026-08-01). The ledger cannot be read
    /// directly by the client (RLS + REVOKE in 066), so we go through a SECURITY DEFINER RPC.
    func remainingDailyPostSlots() async -> Int? {
        guard UserAuthService.shared.userId != nil else { return nil }
        do {
            let used: Int = try await client
                .rpc("get_post_quota_used")
                .execute()
                .value
            return max(0, Self.dailyPostLimit - used)
        } catch {
            print("⚠️ remainingDailyPostSlots failed: \(error)")
            return nil
        }
    }

    func createPostV2(
        id: UUID,
        title: String?,
        tags: [String],
        images: [Data],
        overlays: [PostOverlayDTO]
    ) async -> UserPost? {
        guard let userId = UserAuthService.shared.userId else {
            print("⚠️ createPostV2 ignored: not signed in")
            return nil
        }
        guard !images.isEmpty, images.count <= 4 else {
            print("⚠️ createPostV2 ignored: invalid image count \(images.count)")
            return nil
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle: String? = {
            guard let t = trimmedTitle, !t.isEmpty else { return nil }
            return String(t.prefix(60))
        }()
        let cleanedTags = Array(tags.filter { !$0.isEmpty }.prefix(3))

        isCreating = true
        lastCreateFailure = nil
        defer { isCreating = false }

        // Storage path convention: first image "{uid}/{post_id}.jpg" (compatible with existing posts), images
        // 2 and later "..._2.jpg" to "_4.jpg" (both uid and uuid are lowercased to match the string comparison
        // in RLS)
        let basePath = "\(userId.uuidString.lowercased())/\(id.uuidString.lowercased())"
        let paths = images.indices.map { idx in
            idx == 0 ? "\(basePath).jpg" : "\(basePath)_\(idx + 1).jpg"
        }

        // 1. Upload all images to Storage in order (if one fails midway, delete the uploaded ones best-effort
        //    and abort)
        var uploadedPaths: [String] = []
        for (idx, data) in images.enumerated() {
            do {
                // M18b: Post images are immutable content, also made immutable on the server side by H13 (037 SQL)
                // (changing image_path is rejected by the edit trigger), so a 1-year cache is justified
                _ = try await client.storage
                    .from("post-images")
                    .upload(
                        paths[idx],
                        data: data,
                        options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)
                    )
                uploadedPaths.append(paths[idx])
            } catch {
                print("⚠️ Failed to upload post image \(idx): \(error)")
                lastCreateFailure = .other
                if !uploadedPaths.isEmpty {
                    do {
                        _ = try await client.storage.from("post-images").remove(paths: uploadedPaths)
                    } catch {
                        print("⚠️ Failed to clean up partial upload (ignored): \(error)")
                    }
                }
                return nil
            }
        }

        // 2. Insert into user_posts (set id explicitly to match the Storage path)
        struct InsertRow: Encodable {
            let id: String
            let user_id: String
            let title: String?
            let tags: [String]
            let image_path: String
            let image_count: Int
            let overlays: [PostOverlayDTO]
            let lang: String
        }

        let row = InsertRow(
            id: id.uuidString,
            user_id: userId.uuidString,
            title: cleanedTitle,
            tags: cleanedTags,
            image_path: paths[0],
            image_count: images.count,
            overlays: overlays,
            // 073: Record the author's device language (input for the same-language priority scoring of the feed)
            lang: currentMainLanguageRaw()
        )

        do {
            let inserted: UserPost = try await client
                .from("user_posts")
                .insert(row)
                .select()
                .single()
                .execute()
                .value
            myPosts.insert(inserted, at: 0)
            print("✅ Created post v2: \(inserted.id) (\(images.count) images)")
            return inserted
        } catch {
            print("⚠️ Failed to insert post v2 row: \(error)")
            // 046 rate limit (5 posts/24h). Detected by matching the RAISE EXCEPTION message (same pattern as
            // AppealService)
            if let pgError = error as? PostgrestError, pgError.message.contains("daily post limit") {
                lastCreateFailure = .rateLimited
            } else {
                lastCreateFailure = .other
            }
            // If the insert fails, delete orphan files in Storage best-effort (failures are ignored)
            do {
                _ = try await client.storage.from("post-images").remove(paths: paths)
            } catch {
                print("⚠️ Failed to clean up orphaned post images (ignored): \(error)")
            }
            return nil
        }
    }

    // MARK: - Optimistic update of comment count

    /// Called from CommentService. Increments/decrements comment_count in the caches for myPosts / all users in
    /// viewingPostsByUser (patch every key so it shows no matter which profile screen is stacked)
    func adjustCommentCount(forPostId postId: UUID, by delta: Int) {
        if let idx = myPosts.firstIndex(where: { $0.id == postId }) {
            myPosts[idx] = patchedPost(myPosts[idx], commentCountDelta: delta)
        }
        for (userId, posts) in viewingPostsByUser {
            if let idx = posts.firstIndex(where: { $0.id == postId }) {
                var updated = posts
                updated[idx] = patchedPost(posts[idx], commentCountDelta: delta)
                viewingPostsByUser[userId] = updated
            }
        }
    }

    private func patchedPost(_ post: UserPost, commentCountDelta delta: Int) -> UserPost {
        UserPost(
            id: post.id,
            userId: post.userId,
            textJp: post.textJp,
            textEn: post.textEn,
            tags: post.tags,
            likeCount: post.likeCount,
            commentCount: max(0, post.commentCount + delta),
            createdAt: post.createdAt,
            backgroundId: post.backgroundId,
            title: post.title,
            imagePath: post.imagePath,
            overlays: post.overlays,
            imageCount: post.imageCount,
            // L11 (fixed along the way): the memberwise init of UserPost defaults moderationStatus/viewCount to
            // nil/0, so forgetting to pass them made the rejected badge (moderationStatus) and view count (viewCount)
            // disappear on every comment_count adjustment
            moderationStatus: post.moderationStatus,
            viewCount: post.viewCount
        )
    }

    // MARK: - Delete post

    /// Delete a post (own posts only; other users' posts are rejected by RLS)
    /// For post v2 (has image_path), delete all baked-in images in Storage (image_count of them) best-effort
    /// - Returns: true on success (on failure it is already rolled back internally, so the caller must also
    ///   revert its optimistic UI)
    @discardableResult
    func deletePost(_ postId: UUID) async -> Bool {
        // Optimistic UI update
        let backup = myPosts
        let removedPost = backup.first(where: { $0.id == postId })
        myPosts.removeAll { $0.id == postId }

        do {
            try await client
                .from("user_posts")
                .delete()
                .eq("id", value: postId.uuidString)
                .execute()
            print("✅ Deleted post: \(postId)")

            if let imagePath = removedPost?.imagePath, imagePath.hasSuffix(".jpg") {
                let base = String(imagePath.dropLast(4))
                let count = max(removedPost?.imageCount ?? 1, 1)
                let paths = (1...count).map { n in n == 1 ? imagePath : "\(base)_\(n).jpg" }
                do {
                    _ = try await client.storage.from("post-images").remove(paths: paths)
                } catch {
                    print("⚠️ Failed to remove post images from storage (ignored): \(error)")
                }
            }
            return true
        } catch {
            // Rollback
            myPosts = backup
            print("⚠️ Failed to delete post: \(error)")
            return false
        }
    }
}
