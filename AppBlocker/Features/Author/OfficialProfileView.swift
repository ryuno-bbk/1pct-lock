//
//  OfficialProfileView.swift
//  AppBlocker
//
//  「1%」公式アカウントのプロフィールページ (全公式名言一覧 + フォロー)
//  偉人実名アカウント廃止に伴い AuthorProfileView (偉人個別プロフィール) を置き換える
//  "アカウント" 側の遷移先。個々の偉人はカード上のテキスト表記 (— 著者名) に降格し、
//  そのタップ先は AuthorQuoteFeedView (著者トピックフィード) へ移った。
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

    // 2026-07-31 ユーザー指定: 「大衆向けじゃないSNS」+「1%の公式アカウント」の2点を言う
    private var bio: String {
        lang == .japanese
            ? "大衆向けじゃないSNS。1% の公式アカウント。" // 文言はユーザー添削待ち
            : "Not a social app for everyone. The official 1% account."
    }

    /// 全公式名言 (QuoteService の既存キャッシュを流用。偉人アカウント廃止後は全名言が 1% 名義)
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
            // ヒーロー画像を画面上端 (ステータスバー下) までべったり付ける (BeReal 準拠)
            .ignoresSafeArea(edges: .top)
        }
        // 名前はヒーロー内に大きく出るためバータイトルは空。バー背景も透過して画像に重ねる
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
            // 自分のフォロー/解除でフォロワー数を即時反映
            Task { await loadFollowerCount() }
        }
    }

    // MARK: - Profile Header (BeReal 風ヒーロー、2026-07-10。公式はロゴヒーロー)

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

    /// user_follows から author_id = sentinel のフォロワー数を取得。
    /// head + count で件数だけもらう (全行フェッチしてクライアントで数えない)
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
