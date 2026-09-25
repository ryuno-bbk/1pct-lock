//
//  UserPostService.swift
//  AppBlocker
//
//  UGC: ユーザー投稿の fetch / insert / delete
//

import Foundation
import Combine
import Supabase

@MainActor
final class UserPostService: ObservableObject {

    static let shared = UserPostService()

    // 自分の投稿 (MyProfileView 用)
    @Published private(set) var myPosts: [UserPost] = []

    // 他人の投稿 (UserProfileView 用)。userId ごとに保持するキー付きストア。
    // UserProfileView は自分自身の上にスタックで再度 push されうる (FeedCardListView の著者タップ /
    // LikersSheet / CommentPageView から別ユーザーのプロフィールを開く導線があるため) ので、
    // 単一スロットだと内側の profile が外側の profile のデータを上書き/クリアしてしまう。
    // ユーザーごとの配列を保持することでどのプロフィール画面が手前にあっても正しいデータを保つ
    // (数ユーザーぶんの投稿配列をメモリに保持するコストは許容)。
    @Published private(set) var viewingPostsByUser: [UUID: [UserPost]] = [:]

    /// 指定ユーザーの投稿一覧 (未ロードなら空配列)
    func viewingPosts(for userId: UUID) -> [UserPost] {
        viewingPostsByUser[userId] ?? []
    }

    @Published private(set) var isCreating: Bool = false

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// 073: 投稿時の user_posts.lang に書き込む値。AppBlockerApp.init() / WidgetCacheService と
    /// 同じ「mainLanguage キー未設定なら端末既定言語」の読み方に合わせる
    private func currentMainLanguageRaw() -> String {
        UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
    }

    // MARK: - 自分の投稿

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
            // L11: 読込開始後にサインアウト/別アカウントへの切替が起きていたら、
            // 前ユーザーの投稿一覧を新しい状態 (myPosts) へ書き込んでしまう。
            // 完了時点の userId が開始時と一致する場合のみ結果を反映する
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

    // MARK: - 他人の投稿

    /// userId の投稿を取得し viewingPostsByUser[userId] へ書き込む (呼ぶたびに最新化)。
    /// UserProfileView が自分自身の上に複数スタックされても、それぞれ別 key に書くので
    /// 互いのデータを上書きしない
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

    /// サインアウト/アカウント切替時に全ユーザーぶんのキャッシュを破棄する。
    /// 通常のプロフィール画面 pop では呼ばない (キャッシュはスタック中も保持する設計)
    func clearAllViewingUsers() {
        viewingPostsByUser = [:]
    }

    /// L11 (2026-07-22 監査): サインアウト時に myPosts (マイページの自分の投稿一覧) が
    /// 残留していたため追加。viewingPostsByUser (他人の投稿キャッシュ) は既存の
    /// clearAllViewingUsers() に委譲する。
    func clearAllForSignOut() {
        myPosts = []
        clearAllViewingUsers()
    }

    // MARK: - 単体取得 (通知タップ等から)

    /// post_id 1 件の取得 (見つからない場合 nil)
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

    // MARK: - 投稿作成

    /// 投稿作成 (成功時 myPosts 先頭に挿入)
    /// textJp / textEn は片方のみでも OK (最低 1 つ必須、両方 nil 不可)
    /// 文字制限: jp <= 200, en <= 400
    /// backgroundId: BackgroundImageProvider の index (nil なら hash 自動割当)
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

        // background_id の正当性チェック (範囲外なら nil 扱い)
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
            // 073: 投稿者の端末言語を記録 (フィードの同一言語優先スコアリングの判定材料)
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

    // MARK: - 投稿作成 v2 (背景 + 自由配置テキストの焼き込み画像、複数枚対応)

    /// 投稿v2: テキストは呼び出し側で画像ごとに1枚のJPEGに焼き込み済み。DB は
    /// title/tags/image_path (1枚目)/image_count/overlays のみ保持する。
    /// - Parameters:
    ///   - id: クライアント側で採番した UUID (Storage パスと user_posts.id を一致させるため明示指定)
    ///   - title: 任意のタイトル (# タグを含みうる、60文字以内。超過分は切り詰め)
    ///   - tags: 0-3 個 (既存タグプールから選択、createPost と同じ制約)
    ///   - images: 焼き込み済み JPEG データの配列 (1〜4枚、先頭がカバー画像)
    ///   - overlays: 再編集/検索/モデレ用の生テキスト+配置情報 (imageIndex で画像を紐付け)
    /// - Returns: 成功時は挿入された UserPost (myPosts 先頭に楽観反映)、失敗時は nil
    /// 直近の投稿失敗の種別 (046 レート制限 5件/24h の文言出し分け用。
    /// createPostV2 が nil を返した直後に呼び出し側が読む)
    enum CreateFailure {
        case rateLimited
        case other
    }
    private(set) var lastCreateFailure: CreateFailure?

    /// 1日の投稿上限。サーバー側 enforce_post_rate_limit (052=10 → 057=5) と数字を同期させること
    static let dailyPostLimit = 5

    /// 過去24時間の自分の投稿数から残り枠を返す (PostConfirmView の残数表示用)。
    /// 失敗時は nil (呼び出し側は表示を省略するだけで投稿自体は妨げない)
    ///
    /// 068: user_posts の現存行を数える方式から get_post_quota_used RPC (rate_events 台帳) へ変更。
    /// 旧方式は「投稿を削除すると表示上の残り枠が増えるのに、サーバー (066 で台帳ベースに変更済み) は
    /// 削除を枠の回復と見なさないので投稿が弾かれる」という食い違いを起こしていた
    /// (2026-08-01 実機テストで発覚)。台帳はクライアントから直接読めない (066 で RLS + REVOKE 済み) ため
    /// SECURITY DEFINER の RPC を経由する。
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

        // Storage パス規約: 1枚目 "{uid}/{post_id}.jpg" (既存投稿と互換)、2枚目以降 "..._2.jpg"〜"_4.jpg"
        // (uid/uuid とも lowercased で RLS の文字列比較に揃える)
        let basePath = "\(userId.uuidString.lowercased())/\(id.uuidString.lowercased())"
        let paths = images.indices.map { idx in
            idx == 0 ? "\(basePath).jpg" : "\(basePath)_\(idx + 1).jpg"
        }

        // 1. Storage へ全画像を順にアップロード (途中で失敗したら成功済み分を best-effort で削除して中断)
        var uploadedPaths: [String] = []
        for (idx, data) in images.enumerated() {
            do {
                // M18b: 投稿画像は H13 (037 SQL) でサーバー側もイミュータブル化済みの不変コンテンツ
                // (image_path 変更は編集トリガーで拒否される) なので 1年キャッシュが正当
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

        // 2. user_posts へ insert (id を明示指定して Storage パスと一致させる)
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
            // 073: 投稿者の端末言語を記録 (フィードの同一言語優先スコアリングの判定材料)
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
            // 046 レート制限 (5件/24h)。RAISE EXCEPTION の文言判定 (AppealService と同じパターン)
            if let pgError = error as? PostgrestError, pgError.message.contains("daily post limit") {
                lastCreateFailure = .rateLimited
            } else {
                lastCreateFailure = .other
            }
            // insert 失敗時は Storage の孤児ファイルを best-effort で削除 (失敗しても無視)
            do {
                _ = try await client.storage.from("post-images").remove(paths: paths)
            } catch {
                print("⚠️ Failed to clean up orphaned post images (ignored): \(error)")
            }
            return nil
        }
    }

    // MARK: - コメント数の楽観更新

    /// CommentService から呼ばれる。myPosts / viewingPostsByUser の全ユーザーぶんキャッシュの
    /// comment_count を増減する (どのプロフィール画面がスタックされていても反映されるよう全 key を patch)
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
            // L11 (ついで修正): UserPost のメンバーワイズ init は moderationStatus/viewCount の
            // デフォルトが nil/0 のため、これらを渡し忘れると comment_count 調整のたびに
            // rejected バッジ (moderationStatus) と閲覧数 (viewCount) が消えていた
            moderationStatus: post.moderationStatus,
            viewCount: post.viewCount
        )
    }

    // MARK: - 投稿削除

    /// 投稿削除 (自分の投稿のみ、RLS で他人投稿は弾かれる)
    /// 投稿v2 (image_path あり) の場合は Storage の焼き込み画像を image_count 分すべて best-effort で削除する
    /// - Returns: 成功時 true (失敗時は内部でロールバック済みなので呼び出し側の楽観 UI も戻すこと)
    @discardableResult
    func deletePost(_ postId: UUID) async -> Bool {
        // 楽観 UI 更新
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
            // ロールバック
            myPosts = backup
            print("⚠️ Failed to delete post: \(error)")
            return false
        }
    }
}
