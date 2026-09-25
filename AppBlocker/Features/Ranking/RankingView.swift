//
//  RankingView.swift
//  AppBlocker
//
//  累計ロック時間のランキング (2026-09-05 新設)
//
//  🔴 掲載するのは上位10%だけ (ユーザー決定)。
//     母数が増えるほど掲載人数も増える。
//     圏外の人の順位はプロフィールの順位ピルから見られるので、ここには出さない。
//
//  🔴 累計のみ。週次ランキングは作らない (2つあると自分の順位が分からなくなる)。
//
//  ⚠️ 文言はユーザー添削待ち
//

import SwiftUI

struct RankingView: View {

    @ObservedObject private var service = RankingService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// タップした行のプロフィールへ飛ぶ
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
        .navigationTitle(isJa ? "累計ランキング" : "All-time Ranking")  // 文言はユーザー添削待ち
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
                // この画面が何の順位なのかを最初に言う。
                // 🔴 週次レポートの「今週の順位」からも来るので、
                //    ここが累計であることを明示しないと数字が違って見えて混乱する
                Text(isJa
                     ? "累計ロック時間の上位 \(ranking.shown)人／\(ranking.totalUsers)人中"
                     : "Top \(ranking.shown) of \(ranking.totalUsers) by all-time lock time")  // 文言はユーザー添削待ち
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
                        // 自分の行だけ枠で分かるようにする
                        .stroke(row.isMe ? AppColors.accent.opacity(0.6) : .clear, lineWidth: 1.5)
                )
        )
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary)
            Text(isJa ? "まだランキングがありません" : "No ranking yet")  // 文言はユーザー添削待ち
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(32)
    }
}

#Preview {
    NavigationStack { RankingView() }
}
