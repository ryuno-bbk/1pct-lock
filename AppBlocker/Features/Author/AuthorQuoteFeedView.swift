//
//  AuthorQuoteFeedView.swift
//  AppBlocker
//
//  偉人 (著者) の名言だけのトピックフィード。「— 著者名」タップ / 著者プロフィールから遷移。
//  2026-07-10 BeReal 風改修で全画面 TikTok スクロール → FeedCardListView (4:5 カードリスト) に。
//

import SwiftUI

struct AuthorQuoteFeedView: View {
    let author: Author
    let quotes: [Quote]
    let startIndex: Int

    @ObservedObject private var likeService = LikeService.shared

    private var items: [FeedItem] {
        quotes.map { $0.toFilteredFeedItem(isOfficial: author.isOfficial) }
    }

    var body: some View {
        let items = self.items
        FeedCardListView(
            items: items,
            recordsViews: false,  // 著者トピックフィード (名言のみ)、投稿詳細タップではない
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            disableTopicTap: true,  // 既にこの著者の一覧を見ているためタップ遷移なし
            onLikeToggled: { item, nowLiked in
                // いいね一覧グリッドとの同期 (旧 AuthorFeedCard の onLikeTap と同じ)
                guard let quote = quotes.first(where: { $0.id == item.itemId }) else { return }
                if nowLiked {
                    likeService.addToLikedQuotes(quote)
                } else {
                    likeService.removeFromLikedQuotes(quoteId: quote.id)
                }
            }
        )
        .navigationTitle(author.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
