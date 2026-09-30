//
//  LikersSheet.swift
//  AppBlocker
//
//  Sheet listing the people who liked (2026-07-10 user spec).
//  Opened by tapping the like avatar stack at the bottom left of a feed card.
//  A light implementation that calls the 030 fetch_likers RPC once, on demand.
//  Tapping a row goes to that user's profile (push inside the sheet).
//

import SwiftUI

struct LikersSheet: View {

    let item: FeedItem

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var likers: [FeedLiker] = []
    @State private var isLoading = true

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if likers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "heart")
                            .font(.system(size: 30, weight: .thin))
                            .foregroundColor(AppColors.textTertiary)
                        Text(L.feedLikersEmpty(lang))
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(likers) { liker in
                                NavigationLink {
                                    UserProfileView(
                                        userId: liker.userId,
                                        initialDisplayName: liker.displayName,
                                        initialAvatarUrl: liker.avatarUrl
                                    )
                                } label: {
                                    likerRow(liker)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(L.profileLikes(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            likers = await FeedExtrasService.shared.fetchLikers(for: item)
            isLoading = false
        }
    }

    private func likerRow(_ liker: FeedLiker) -> some View {
        HStack(spacing: 12) {
            AvatarImage(
                urlString: liker.avatarUrl,
                size: 44,
                placeholderColor: AppColors.textSecondary
            )

            HStack(spacing: 5) {
                Text(liker.displayName ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "heart.fill")
                .font(.system(size: 14))
                .foregroundColor(.red.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
