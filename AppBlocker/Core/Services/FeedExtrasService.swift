//
//  FeedExtrasService.swift
//  AppBlocker
//
//  BeReal 風フィードカードの付加情報 (028 SQL):
//    - いいねした人 ≤3 (画像左下のアバタースタック)
//    - コメントプレビュー ≤3 (カード下部)
//    - 投稿詳細の閲覧計上 (record_post_view)
//  フィード読み込み後に fetch_feed_extras で 1 ラウンドトリップのバッチ取得し、
//  FeedItem.id ("kind-uuid") キーの辞書でキャッシュする。
//

import Foundation
import Combine
import Supabase

/// fetch_feed_extras の 1 行 (likers / comments は jsonb 配列)
struct FeedExtras: Decodable {
    let kind: FeedItem.Kind
    let itemId: UUID
    let likers: [FeedLiker]
    let comments: [FeedCommentPreview]

    enum CodingKeys: String, CodingKey {
        case kind
        case itemId = "item_id"
        case likers
        case comments
    }

    /// FeedItem.id と同じキー形式
    var key: String { "\(kind.rawValue)-\(itemId.uuidString)" }
}

struct FeedLiker: Decodable, Identifiable, Equatable {
    let userId: UUID
    let displayName: String?
    let avatarUrl: String?
    /// fetch_likers (030、一覧) のみ返す。fetch_feed_extras (≤3 スタック) では nil
    var isPro: Bool? = nil

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case isPro       = "is_pro"
    }
}

struct FeedCommentPreview: Decodable, Identifiable, Equatable {
    let id: UUID
    let authorName: String?
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case authorName = "author_name"
        case text
    }
}

@MainActor
final class FeedExtrasService: ObservableObject {

    static let shared = FeedExtrasService()

    /// FeedItem.id ("kind-uuid") → extras
    @Published private(set) var extras: [String: FeedExtras] = [:]

    /// FeedItem.id → 最後にバッチ取得した時刻 (TTL 判定用。extrasTTL 未満なら再取得をスキップする)
    private var fetchedAt: [String: Date] = [:]

    /// キャッシュの有効期間。同一キーはこの秒数以内なら再フェッチしない
    /// (おすすめ⇄フォロー中の連続トグルで FeedCardListView が再マウントされるたびに
    /// .task が同じバッチを撃つのを防ぐ。2026-07 修正)
    private let extrasTTL: TimeInterval = 60

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    func extras(for item: FeedItem) -> FeedExtras? {
        extras[item.id]
    }

    /// 指定キーの TTL キャッシュだけを無効化する (extras の中身自体は消さない。次の
    /// loadExtras で再取得されるまで古い値を出し続けても実害は無いため、消すのは
    /// 「再取得すべき」というマーク=fetchedAt のみ)。
    /// 自分のいいね/コメント操作は TTL (60秒) を待たずに全ての表示箇所へ即時反映すべき
    /// というプロジェクト共通ルールのため、該当キーだけピンポイントで再取得対象にする (F6)
    func invalidate(key: String) {
        fetchedAt.removeValue(forKey: key)
    }

    // MARK: - バッチ取得

    /// フィード読み込み後に呼ぶ。デフォルトでは各アイテムを `extrasTTL` 秒以内に取得済みなら
    /// スキップし、未取得のキーだけ取得する。`force: true` を渡すと TTL を無視して全件再取得する
    /// (いいね/コメントの変動を確実に拾いたい真の再読み込み時に使う。例: pull-to-refresh 後の
    /// items 差し替え)
    func loadExtras(for items: [FeedItem], force: Bool = false) async {
        guard !items.isEmpty else { return }

        let now = Date()
        let targets = force ? items : items.filter { item in
            guard let last = fetchedAt[item.id] else { return true }
            return now.timeIntervalSince(last) >= extrasTTL
        }
        guard !targets.isEmpty else { return }

        let postIds  = targets.filter { $0.kind == .post  }.map { $0.itemId.uuidString }
        let quoteIds = targets.filter { $0.kind == .quote }.map { $0.itemId.uuidString }

        let params: [String: AnyJSON] = [
            "post_ids":  .array(postIds.map  { .string($0) }),
            "quote_ids": .array(quoteIds.map { .string($0) })
        ]

        do {
            let rows: [FeedExtras] = try await client
                .rpc("fetch_feed_extras", params: params)
                .execute()
                .value
            for row in rows {
                extras[row.key] = row
            }
            // リクエストしたキー全件に fetchedAt を記録する (いいね/コメントが 0 件で行が
            // 返らないアイテムも毎回リトライしないようにするため、返却有無に関わらず記録する)
            for item in targets {
                fetchedAt[item.id] = now
            }
            // fetchedAt はアプリ起動中スクロールし続ける限り増え続ける (キーを消す経路が
            // invalidate(key:) 程度しか無いため)。無制限に太らないよう上限を設け、
            // 超えたら古い ~100 件を間引く (最新のキャッシュ判定には影響しない程度の粒度)
            if fetchedAt.count > 500 {
                let sortedByAge = fetchedAt.sorted { $0.value < $1.value }
                for (key, _) in sortedByAge.prefix(100) {
                    fetchedAt.removeValue(forKey: key)
                }
            }
        } catch {
            print("⚠️ Failed to load feed extras: \(error)")
        }
    }

    // MARK: - いいねした人の一覧 (030 fetch_likers、スタックタップ時にオンデマンド取得)

    func fetchLikers(for item: FeedItem, limit: Int = 200) async -> [FeedLiker] {
        let params: [String: AnyJSON] = [
            "target_kind": .string(item.kind.rawValue),
            "target_id":   .string(item.itemId.uuidString),
            "limit_count": .integer(limit)
        ]
        do {
            let likers: [FeedLiker] = try await client
                .rpc("fetch_likers", params: params)
                .execute()
                .value
            return likers
        } catch {
            print("⚠️ Failed to fetch likers: \(error)")
            return []
        }
    }

    // MARK: - 閲覧計上

    /// 投稿詳細 (カードリスト) に投稿が表示されたら呼ぶ。
    /// 二重計上を避けるためセッション内で同じ投稿は 1 回だけ送る
    /// (DB 側でも自己閲覧は無視される)
    private var recordedThisSession: Set<UUID> = []

    func recordPostView(postId: UUID) {
        guard !recordedThisSession.contains(postId) else { return }
        recordedThisSession.insert(postId)

        Task {
            do {
                try await client
                    .rpc("record_post_view", params: ["target_post_id": AnyJSON.string(postId.uuidString)])
                    .execute()
            } catch {
                // ベストエフォート: 失敗しても UI は止めない。id はセットに残したままにする
                // (削除すると LazyVStack の onAppear 再発火のたびに再送し、オフライン時に
                // 失敗 RPC が無限に飛ぶリトライストームになるため、セッション内は1回だけ試す)
                print("⚠️ Failed to record post view: \(error)")
            }
        }
    }
}
