//
//  FollowedAccountsView.swift
//  AppBlocker
//
//  List of followed accounts (official great figures + regular users)
//  Opened by tapping "フォロー中: N" ("Following: N") in the My Page header
//

import SwiftUI
import Supabase

struct FollowedAccountsView: View {
    @ObservedObject private var followService = FollowService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var followedUsers: [FollowedUser] = []
    @State private var isLoading: Bool = true

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// With the removal of real-name great figure accounts, author follows are consolidated into the
    /// single 1% official account. Author follow rows other than the sentinel (old data) are ignored in
    /// the UI.
    private var isFollowingOfficial: Bool {
        followService.isFollowing(authorId: OnePercentAccount.authorId)
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 12) {
                    // 1% official account (shown as 1 row only if followed)
                    if isFollowingOfficial {
                        NavigationLink {
                            OfficialProfileView()
                        } label: {
                            OnePercentRowCard(onUnfollow: {
                                Task { @MainActor in
                                    await followService.unfollow(authorId: OnePercentAccount.authorId)
                                }
                            })
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    // Regular users
                    ForEach(followedUsers) { user in
                        NavigationLink {
                            UserProfileView(
                                userId: user.id,
                                initialDisplayName: user.displayName,
                                initialAvatarUrl: user.avatarUrl
                            )
                        } label: {
                            FollowedUserRowCard(user: user, onUnfollow: {
                                let uid = user.id
                                Task { @MainActor in
                                    await followService.unfollowUser(userId: uid)
                                }
                            })
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if !isLoading && !isFollowingOfficial && followedUsers.isEmpty {
                        emptyView
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .navigationTitle(L.profileFollowing(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
        .onChange(of: followService.followedAuthorIds) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: followService.followedUserIds) { _, _ in
            Task { await refresh() }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(L.profileNoFollows(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text(L.profileNoFollowsSubtitle(lang))
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let fetchedUsers = await fetchFollowedUsers()

        await MainActor.run {
            self.followedUsers = fetchedUsers.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
        }
    }

    private func fetchFollowedUsers() async -> [FollowedUser] {
        let ids = followService.followedUserIds
        guard !ids.isEmpty else { return [] }

        do {
            let rows: [FollowedUser] = try await SupabaseManager.shared.client
                .from("users")
                .select("id, display_name, avatar_url, is_pro")
                .in("id", values: ids.map { $0.uuidString })
                .execute()
                .value
            return rows
        } catch {
            print("⚠️ Failed to fetch followed users: \(error)")
            return []
        }
    }
}

// MARK: - FollowedUser model (this file only)

struct FollowedUser: Identifiable, Decodable, Equatable {
    let id: UUID
    let displayName: String?
    let avatarUrl: String?
    let isPro: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case isPro       = "is_pro"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.avatarUrl   = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.isPro       = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
    }
}

// MARK: - 1% Official Account Row Card

private struct OnePercentRowCard: View {
    let onUnfollow: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var bio: String {
        lang == .japanese
            ? "スマホを置いた時間だけが、あなたを作る。"
            : "Only the hours away from your phone build you."
    }

    var body: some View {
        HStack(spacing: 14) {
            OnePercentAvatar(size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(OnePercentAccount.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                }

                Text(bio)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onUnfollow) {
                Text(L.profileUnfollow(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppColors.cardBackground.opacity(0.6)))
                    .overlay(Capsule().stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.cardBackground))
    }
}

// MARK: - Followed User Row Card

private struct FollowedUserRowCard: View {
    let user: FollowedUser
    let onUnfollow: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.displayName ?? "—")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onUnfollow) {
                Text(L.profileUnfollow(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppColors.cardBackground.opacity(0.6)))
                    .overlay(Capsule().stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.cardBackground))
    }

    private var avatar: some View {
        Group {
            if let urlString = user.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(AppColors.accent)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(AppColors.accent)
            }
        }
    }
}
