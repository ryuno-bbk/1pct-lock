//
//  RankingView.swift
//  AppBlocker
//
//  Ranking by total lock time (new on 2026-09-05)
//
//  🔴 Only the top 10% are listed (user decision).
//     The more users there are, the more people are listed.
//     People outside it can see their rank from the rank pill on the profile, so they are not shown here.
//
//  🔴 All-time only. No weekly ranking (with 2 of them you can no longer tell your own rank).
//
//  ⚠️ Wording pending user review
//

import SwiftUI

struct RankingView: View {

    @ObservedObject private var service = RankingService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// Jump to the profile of the tapped row
    @State private var jumpToUserId: UUID?
    @State private var showUserProfile = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }
    private var isJa: Bool { lang == .japanese }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if service.isLoading && service.ranking == nil {
                ProgressView()
                    .tint(AppColors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let ranking = service.ranking, !ranking.rows.isEmpty {
                content(ranking)
            } else {
                emptyView
            }
        }
        .navigationTitle(isJa ? "累計ランキング" : "All-time Ranking")  // Wording pending user review
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await service.load() }
        .refreshable { await service.load() }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = jumpToUserId {
                UserProfileView(userId: uid)
            }
        }
    }

    private func content(_ ranking: BlockRanking) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Say first what this screen ranks.
                // 🔴 People also come here from "今週の順位" ("This week's rank") in the weekly report, so
                //    unless we state clearly that this is all-time, the numbers look different and confuse people
                Text(isJa
                     ? "累計ロック時間の上位 \(ranking.shown)人／\(ranking.totalUsers)人中"
                     : "Top \(ranking.shown) of \(ranking.totalUsers) by all-time lock time")  // Wording pending user review
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                ForEach(ranking.rows) { row in
                    Button {
                        jumpToUserId = row.userId
                        showUserProfile = true
                    } label: {
                        rowLabel(row)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func rowLabel(_ row: BlockRankingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.custom("Montserrat-BlackItalic", size: 18))
                .monospacedDigit()
                .foregroundColor(row.rank <= 3 ? AppColors.textPrimary : AppColors.textTertiary)
                .frame(width: 34, alignment: .center)

            AvatarImage(urlString: row.avatarUrl, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.displayName?.isEmpty == false ? row.displayName! : "—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                    if row.isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }
                if let handle = row.handle, !handle.isEmpty {
                    Text("@\(handle)")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(row.totalSeconds.lockDurationText)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        // Only my own row is marked with a frame
                        .stroke(row.isMe ? AppColors.accent.opacity(0.6) : .clear, lineWidth: 1.5)
                )
        )
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary)
            Text(isJa ? "まだランキングがありません" : "No ranking yet")  // Wording pending user review
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(32)
    }
}

#Preview {
    NavigationStack { RankingView() }
}
