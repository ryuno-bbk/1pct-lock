//
//  FilteredQuoteFeedView.swift
//  AppBlocker
//
//  Feed of filtered quotes, e.g. by category or the likes section.
//  In the 2026-07-10 BeReal-style rework, the full-screen TikTok scroll → FeedCardListView (4:5 card
//  list). (The endless reshuffle with the old InfiniteQuoteBuffer was removed. It shows a finite list)
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
            recordsViews: false,  // Filtered quote-only feed (likes list etc.), not a tap into post detail
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            onLikeToggled: { item, nowLiked in
                // Sync with the likes list grid (same as onLikeTap of the old FilteredFeedCard)
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
        // Real device feedback #6: keep the same fix on the sibling screens pushed from MyProfileView (likes
        // list)
        .safeAreaCollapseFix()
    }
}

// MARK: - Quote → FeedItem conversion (for card display / image save / share, shared with
// AuthorQuoteFeedView)

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
