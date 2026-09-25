//
//  MyPostsFeedView.swift
//  AppBlocker
//
//  プロフィールのグリッドタップから開く投稿の詳細フィード (自分/他人ユーザー共用)。
//  2026-07-10 BeReal 風改修で全画面 TikTok スクロール → FeedCardListView (4:5 カードリスト) に。
//  投稿が表示されるたびに record_post_view で閲覧計上される (FeedCardListView 側)。
//

import SwiftUI

struct MyPostsFeedView: View {
    let posts: [UserPost]
    let startIndex: Int
    /// 投稿者名 (nil なら auth.displayName をフォールバック)
    var authorDisplayName: String? = nil
    /// 投稿者アバター URL
    var authorAvatarUrl: String? = nil
    /// 投稿者 is_pro (Pro バッジ表示)
    var authorIsPro: Bool = false
    /// 削除メニューを出すか (= 自分の投稿フィードのみ true)
    var canDelete: Bool = true

    @ObservedObject private var auth = UserAuthService.shared

    /// 🔴 自分のフィードでないときに auth.displayName へ落ちてはいけない。
    ///    「投稿者が分からない」を「自分が投稿者」にすり替えてしまい、他人の投稿に
    ///    自分の名前が出る (2026-08-28 に通知経由で実際に発生)。
    ///    渡されなければ nil のままにする (カード側が "—" を出す)
    private var resolvedAuthorName: String? {
        canDelete ? (auth.displayName ?? authorDisplayName) : authorDisplayName
    }

    private var resolvedAvatarUrl: String? {
        canDelete ? (auth.avatarUrl?.absoluteString ?? authorAvatarUrl) : authorAvatarUrl
    }

    private var resolvedIsPro: Bool {
        canDelete ? auth.isPro : authorIsPro
    }

    private var items: [FeedItem] {
        posts.map {
            $0.toFeedItem(
                authorName: resolvedAuthorName,
                avatarUrl: resolvedAvatarUrl,
                isProAuthor: resolvedIsPro
            )
        }
    }

    /// AI モデレーション rejected (層1安全性NG) の投稿 id。本人の投稿一覧にのみバッジ+異議申し立て導線を表示。
    /// 旧仕様では flagged (層2エトスNG) は「何も表示しない (シャドウの意味を保つ)」だったが、
    /// 039_moderation_notifications_appeals.sql で本人へ通知する方針に変わったため、
    /// flagged も本人には可視化する (flaggedIds 参照。投稿自体は表示されたまま上端バナーで伝える)
    private var rejectedIds: Set<UUID> {
        guard canDelete else { return [] }
        return Set(posts.filter { $0.moderationStatus == "rejected" }.map { $0.id })
    }

    /// AI モデレーション flagged (層2エトスNG) の投稿 id。039 以降は本人に通知+上端バナー+
    /// 異議申し立て導線を出す方針 (旧: シャドウ目的で何も表示しなかった)
    private var flaggedIds: Set<UUID> {
        guard canDelete else { return [] }
        return Set(posts.filter { $0.moderationStatus == "flagged" }.map { $0.id })
    }

    var body: some View {
        let items = self.items
        FeedCardListView(
            items: items,
            recordsViews: true,  // プロフィールのグリッドタップで開く投稿詳細 = 実際のタップ数
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            canDeletePosts: canDelete,
            rejectedPostIds: rejectedIds,
            flaggedPostIds: flaggedIds
        )
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 ヘッダーの黒い背景を消して、戻るボタンだけが内容の上に浮く形にする
        //    (マイページと同じ見た目。2026-08-29 ユーザー指示)。
        //    ⚠️ この NavigationStack に push する画面はこの3行が必須
        //    (project_en_screenshots_and_nav_bugs_2026_08_04)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // 実機FB#6: インセット崩壊の実測補正 (SafeAreaCollapseFix.swift 参照)
        .safeAreaCollapseFix()
    }
}
