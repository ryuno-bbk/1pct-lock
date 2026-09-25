//
//  FilteredQuoteFeedView.swift
//  AppBlocker
//
//  カテゴリ別・いいね欄などフィルタされた名言のフィード。
//  2026-07-10 BeReal 風改修で全画面 TikTok スクロール → FeedCardListView (4:5 カードリスト) に。
//  (旧 InfiniteQuoteBuffer による無限再シャッフルは廃止、有限リスト表示)
//

import SwiftUI

struct FilteredQuoteFeedView: View {
    let title: String
    let quotes: [Quote]
    let startIndex: Int

    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var quoteService = QuoteService.shared

    private var items: [FeedItem] {
        quotes.map { quote in
            let isOfficial = quote.authorId.flatMap { id in
                quoteService.authors.first { $0.id == id }?.isOfficial
            } ?? false
            return quote.toFilteredFeedItem(isOfficial: isOfficial)
        }
    }

    var body: some View {
        let items = self.items
        FeedCardListView(
            items: items,
            recordsViews: false,  // 名言のみのフィルタ済みフィード (いいね一覧等)、投稿詳細タップではない
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            onLikeToggled: { item, nowLiked in
                // いいね一覧グリッドとの同期 (旧 FilteredFeedCard の onLikeTap と同じ)
                guard let quote = quotes.first(where: { $0.id == item.itemId }) else { return }
                if nowLiked {
                    likeService.addToLikedQuotes(quote)
                } else {
                    likeService.removeFromLikedQuotes(quoteId: quote.id)
                }
            }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 実機FB#6: MyProfileView から push される仲間 (いいね一覧) にも同じ補正を常駐
        .safeAreaCollapseFix()
    }
}

// MARK: - Quote → FeedItem 変換 (カード表示 / 画像保存 / 共有用、AuthorQuoteFeedView と共用)

extension Quote {
    func toFilteredFeedItem(isOfficial: Bool) -> FeedItem {
        FeedItem(
            kind: .quote,
            itemId: id,
            bodyJp: textJp,
            bodyEn: textEn,
            tags: category.map { [$0] } ?? [],
            likeCount: likeCount,
            commentCount: commentCount,
            createdAt: nil,
            authorId: authorId,
            authorName: author,
            authorAvatarUrl: nil,
            isOfficialAuthor: isOfficial
        )
    }
}
