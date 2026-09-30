//
//  FollowListView.swift
//  AppBlocker
//
//  Tabbed list of Followers / Following (2026-07-30 plan D rev. 3, confirmed by the user:
//  "good idea: tapping followers lets you also see Following by switching the tabs at the top").
//  Opened by tapping the follower count on My Page. The Following tab embeds the existing
//  FollowedAccountsView as is (the title shown on the tab side is used).
//  The follower list uses the 059 RPC get_my_followers (stays empty if not applied = fail-soft).
//

import SwiftUI
import Supabase

struct FollowListView: View {

    enum Tab: String, CaseIterable, Identifiable {
        case followers
        case following
        var id: String { rawValue }

        func label(_ lang: AppLanguage) -> String {
            switch self {
            case .followers: return lang == .japanese ? "フォロワー" : "Followers"
            case .following: return lang == .japanese ? "フォロー中" : "Following"
            }
        }
    }

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var tab: Tab = .followers
    @State private var followers: [FollowedUser] = []
    @State private var isLoading = true

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label(lang)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch tab {
            case .followers:
                followersList
            case .following:
                FollowedAccountsView()
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle(tab.label(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFollowers() }
    }

    // MARK: - Followers tab

    private var followersList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(followers) { user in
                    NavigationLink {
                        UserProfileView(
                            userId: user.id,
                            initialDisplayName: user.displayName,
                            initialAvatarUrl: user.avatarUrl
                        )
                    } label: {
                        FollowerRowCard(user: user)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if !isLoading && followers.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 50, weight: .thin))
                            .foregroundColor(AppColors.textTertiary)
                        Text(lang == .japanese ? "まだフォロワーがいません" : "No followers yet")  // Text waiting for user review
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .padding(40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private func loadFollowers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows: [FollowedUser] = try await SupabaseManager.shared.client
                .rpc("get_my_followers")
                .execute()
                .value
            followers = rows
        } catch {
            // 059 not applied / network failure → the list stays empty (does not break)
            print("⚠️ get_my_followers failed: \(error)")
        }
    }
}

// MARK: - Follower row (simple row without an unfollow button)

private struct FollowerRowCard: View {
    let user: FollowedUser

    var body: some View {
        HStack(spacing: 12) {
            AvatarImage(urlString: user.avatarUrl, size: 44)

            // The ELITE badge was removed entirely on 2026-07-20, so isPro is not used for display
            Text(user.displayName?.isEmpty == false ? user.displayName! : "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))
    }
}
