//
//  OfficialProfileView.swift
//  AppBlocker
//
//  Profile page of the "1%" official account (list of all official quotes + follow)
//  With the removal of real-name great figure accounts, this replaces AuthorProfileView (individual
//  great figure profile) as the navigation target on the "account" side. Individual great figures
//  were demoted to a text label on the card (em dash + author name), and tapping it now goes to
//  AuthorQuoteFeedView (author topic feed).
//

import SwiftUI
import Supabase

struct OfficialProfileView: View {
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var quoteService = QuoteService.shared

    @State private var isLoadingQuotes = true
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var selectedQuoteIndex: Int?
    @State private var showQuoteFeed = false
    @State private var followerCount: Int = 0

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var isFollowing: Bool {
        followService.isFollowing(authorId: OnePercentAccount.authorId)
    }

    // 2026-07-31 user instruction: say 2 things, "an SNS that is not for the masses" + "the official
    // 1% account"
    private var bio: String {
        lang == .japanese
            ? "大衆向けじゃないSNS。1% の公式アカウント。" // Wording awaiting user review
            : "Not a social app for everyone. The official 1% account."
    }

    /// All official quotes (reuses QuoteService's existing cache. After the great figure accounts were
    /// removed, all quotes are under the 1% name)
    private var officialQuotes: [Quote] {
        quoteService.quotes
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    profileHeader
                    quotesSection
                }
            }
            .coordinateSpace(name: ProfileHeroHeader.scrollSpace)
            // Attach the hero image flush to the top edge of the screen (under the status bar) (following BeReal)
            .ignoresSafeArea(edges: .top)
        }
        // The name appears large inside the hero, so the bar title is empty. The bar background is also
        // transparent and laid over the image
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $showQuoteFeed) {
            if let index = selectedQuoteIndex {
                FilteredQuoteFeedView(
                    title: OnePercentAccount.name,
                    quotes: officialQuotes,
                    startIndex: index
                )
            }
        }
        .task {
            if quoteService.quotes.isEmpty {
                await quoteService.loadQuotes()
            }
            isLoadingQuotes = false
            await loadFollowerCount()
        }
        .onChange(of: followService.followedAuthorIds) { _, _ in
            // Reflect the follower count immediately when you follow/unfollow
            Task { await loadFollowerCount() }
        }
    }

    // MARK: - Profile Header (BeReal-style hero, 2026-07-10. The official one uses a logo hero)

    private var profileHeader: some View {
        ProfileHeroHeader(
            hero: .onePercent,
            displayName: OnePercentAccount.name,
            isOfficial: true,
            bio: bio,
            stats: [
                ProfileHeroStat(value: "\(officialQuotes.count)", label: L.authorQuotes(lang)),
                ProfileHeroStat(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang)),
                ProfileHeroStat(
                    value: "\(officialQuotes.reduce(0) { $0 + $1.likeCount })",
                    label: L.profileLikes(lang)
                )
            ],
            actionTitle: L.authorFollowButton(isFollowing, lang),
            actionIsProminent: !isFollowing,
            actionIcon: isFollowing ? "checkmark" : "plus",
            onAction: {
                Task { await followService.toggleFollow(authorId: OnePercentAccount.authorId) }
            }
        )
    }

    // MARK: - Quotes Section

    private var quotesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.authorQuotes(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            if isLoadingQuotes {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(AppColors.textSecondary)
                    Spacer()
                }
                .padding(.top, 40)
            } else if officialQuotes.isEmpty {
                Text(L.authorNoQuotes(lang))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(Array(officialQuotes.enumerated()), id: \.element.id) { index, quote in
                        LikedQuoteGridCell(
                            quote: quote,
                            onTap: {
                                selectedQuoteIndex = index
                                showQuoteFeed = true
                            }
                        )
                        .contextMenu {
                            Button {
                                Task { await likeService.toggleLike(quoteId: quote.id) }
                                if likeService.isLiked(quoteId: quote.id) {
                                    likeService.removeFromLikedQuotes(quoteId: quote.id)
                                } else {
                                    likeService.addToLikedQuotes(quote)
                                }
                            } label: {
                                Label(
                                    likeService.isLiked(quoteId: quote.id) ? L.profileUnlike(lang) : L.profileLikes(lang),
                                    systemImage: likeService.isLiked(quoteId: quote.id) ? "heart.slash" : "heart"
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Helpers

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    /// Get the follower count with author_id = sentinel from user_follows.
    /// Get only the count with head + count (do not fetch all rows and count on the client)
    private func loadFollowerCount() async {
        do {
            let response = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("follower_id", head: true, count: .exact)
                .eq("author_id", value: OnePercentAccount.authorId.uuidString)
                .execute()
            self.followerCount = response.count ?? 0
        } catch {
            print("⚠️ Failed to load official account follower count: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        OfficialProfileView()
    }
}
