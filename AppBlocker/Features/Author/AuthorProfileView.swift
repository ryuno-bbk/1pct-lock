//
//  AuthorProfileView.swift
//  AppBlocker
//
//  偉人プロフィールページ（名言一覧 + フォロー）
//

import SwiftUI
import Supabase

struct AuthorProfileView: View {
    let author: Author

    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var quoteService = QuoteService.shared

    @State private var authorQuotes: [Quote] = []
    @State private var isLoadingQuotes = true
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var selectedQuoteIndex: Int?
    @State private var showQuoteFeed = false
    @State private var isBioExpanded = false
    @State private var followerCount: Int = 0

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var isFollowing: Bool {
        followService.isFollowing(authorId: author.id)
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // プロフィールヘッダー
                    profileHeader

                    // 名言一覧
                    quotesSection
                }
            }
        }
        .navigationTitle(author.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showQuoteFeed) {
            if let index = selectedQuoteIndex {
                AuthorQuoteFeedView(
                    author: author,
                    quotes: authorQuotes,
                    startIndex: index
                )
            }
        }
        .task {
            await loadQuotes()
            await loadFollowerCount()
        }
        .onChange(of: followService.followedAuthorIds) { _, _ in
            // 自分のフォロー/解除でフォロワー数を即時反映
            Task { await loadFollowerCount() }
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 16) {
            // アイコン
            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(AppColors.accent)
                .padding(.top, 24)

            // 名前 + 公式バッジ + 国旗
            HStack(spacing: 6) {
                Text(author.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                if author.isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.blue)
                        .accessibilityLabel("公式")
                }

                if !author.nationality.isEmpty {
                    Text(author.nationality)
                        .font(.system(size: 20))
                }
            }

            // バイオ（もっと見る / 閉じる）
            VStack(spacing: 4) {
                Text(author.displayBio(lang: lang))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(isBioExpanded ? nil : 3)
                    .animation(.easeInOut(duration: 0.3), value: isBioExpanded)

                if author.displayBio(lang: lang).count > 60 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isBioExpanded.toggle()
                        }
                    } label: {
                        Text(isBioExpanded ? L.authorShowLess(lang) : L.authorShowMore(lang))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.accent)
                    }
                }
            }
            .padding(.horizontal, 32)

            // 統計
            HStack(spacing: 40) {
                statItem(value: "\(authorQuotes.count)", label: L.authorQuotes(lang))
                statItem(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang))
                statItem(
                    value: "\(authorQuotes.reduce(0) { $0 + $1.likeCount })",
                    label: L.profileLikes(lang)
                )
            }
            .padding(.top, 8)

            // フォローボタン
            Button {
                Task { await followService.toggleFollow(authorId: author.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isFollowing ? "checkmark" : "plus")
                        .font(.system(size: 14, weight: .bold))

                    Text(L.authorFollowButton(isFollowing, lang))
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(isFollowing ? AppColors.textSecondary : AppColors.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isFollowing ? AppColors.cardBackground : AppColors.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFollowing ? AppColors.textTertiary.opacity(0.3) : Color.clear, lineWidth: 1)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Divider()
                .background(AppColors.textTertiary.opacity(0.3))
                .padding(.top, 16)
        }
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
            } else if authorQuotes.isEmpty {
                Text(L.authorNoQuotes(lang))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 2),
                        GridItem(.flexible(), spacing: 2),
                        GridItem(.flexible(), spacing: 2)
                    ],
                    spacing: 2
                ) {
                    ForEach(Array(authorQuotes.enumerated()), id: \.element.id) { index, quote in
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
                .padding(.horizontal, 2)
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


    private func loadQuotes() async {
        isLoadingQuotes = true
        do {
            authorQuotes = try await quoteService.fetchQuotesByAuthor(authorId: author.id)
        } catch {
            print("⚠️ Failed to load author quotes: \(error)")
        }
        isLoadingQuotes = false
    }

    /// user_follows から author_id を持つ行を count して実フォロワー数を取得
    private func loadFollowerCount() async {
        struct FollowerRow: Decodable { let follower_id: UUID }
        do {
            let rows: [FollowerRow] = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("follower_id")
                .eq("author_id", value: author.id.uuidString)
                .execute()
                .value
            self.followerCount = rows.count
        } catch {
            print("⚠️ Failed to load author follower count: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        AuthorProfileView(
            author: Author(
                name: "Anonymous",
                bioEn: "Quotes whose original author is unknown or attributed to multiple sources.",
                bioJp: "原著者不明、または複数ソースに帰される名言を集約。",
                nationality: ""
            )
        )
    }
}
