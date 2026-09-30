//
//  AuthorQuoteFeedView.swift
//  AppBlocker
//
//  Topic feed with only the quotes of a historical figure (author). Opened by tapping the author name
//  credit / from the author profile.
//  In the 2026-07-10 BeReal-style redesign, full-screen TikTok scrolling → FeedCardListView (4:5
//  card list).
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
            recordsViews: false,  // Author topic feed (quotes only), not a tap into post details
            startItemKey: items.indices.contains(startIndex) ? items[startIndex].id : nil,
            disableTopicTap: true,  // Already viewing this author's list, so no tap navigation
            onLikeToggled: { item, nowLiked in
                // Sync with the likes grid (same as onLikeTap in the old AuthorFeedCard)
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
