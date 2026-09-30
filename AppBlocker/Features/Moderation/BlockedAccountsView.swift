//
//  BlockedAccountsView.swift
//  AppBlocker
//
//  Blocked users list + unblock
//

import SwiftUI

struct BlockedAccountsView: View {

    @ObservedObject private var blockService = BlockService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var blockedUsers: [BlockedUser] = []
    @State private var isLoading: Bool = true

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if isLoading && blockedUsers.isEmpty {
                ProgressView()
                    .tint(AppColors.textPrimary)
            } else if blockedUsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 50, weight: .thin))
                        .foregroundColor(AppColors.textTertiary)
                    Text(L.moderationBlockedListEmpty(lang))
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.textSecondary)
                }
            } else {
                List {
                    ForEach(blockedUsers) { user in
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 36))
                                .foregroundColor(AppColors.textTertiary)
                            Text(user.displayName?.isEmpty == false ? user.displayName! : "—")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Button(L.moderationUnblock(lang)) {
                                Task { await unblock(user.id) }
                            }
                            .foregroundColor(AppColors.accent)
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L.moderationBlockedListTitle(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        await blockService.loadMyBlocks()
        blockedUsers = await blockService.fetchBlockedUsers()
        isLoading = false
    }

    @MainActor
    private func unblock(_ userId: UUID) async {
        await blockService.unblock(userId: userId)
        blockedUsers.removeAll { $0.id == userId }
    }
}
