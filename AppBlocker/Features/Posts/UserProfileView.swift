//
//  UserProfileView.swift
//  AppBlocker
//
//  一般ユーザー (UGC 投稿者) のプロフィール画面
//  公式偉人 (AuthorProfileView) とは別物
//

import SwiftUI
import Supabase

struct UserProfileView: View {

    let userId: UUID
    var initialDisplayName: String?
    var initialAvatarUrl: String?

    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String?
    @State private var bio: String?
    @State private var dream: String?
    @State private var avatarUrl: String?
    @State private var handle: String?
    @State private var isPro: Bool = false
    /// 公式マーク。🔴 ProfileHero には元から描画コードがあるのに、この画面だけ
    ///    is_official を読んでおらず誰にもマークが出なかった (2026-08-30 修正)。
    ///    1%公式アカウントは OfficialProfileView が true をベタ書きしているので出ていた
    @State private var isOfficial: Bool = false
    @State private var followerCount: Int = 0
    @State private var followingCount: Int = 0
    @State private var percentile: BlockSessionTracker.BlockPercentile?
    /// 相手が自分をフォローしているか (相互フォロー表示、058 RPC。未適用/失敗時は false)
    @State private var isFollowedBy = false
    /// 統計シート (他人のプロフィールでも見られる。連続日数だけは本人専用のため出さない)。
    /// sheet(item:) 方式 — 非nil=表示中+主役。isPresented+別@Stateの初回presentationバグ対策 (2026-07-30)
    @State private var statsSheetFocus: ProfileStatsSheet.Focus?
    /// 他人のプロフィールの統計シートからもランキングへ行けるようにする (2026-09-09)
    @State private var showRanking: Bool = false

    /// シートを閉じ切ってから push する (シート内には NavigationStack が無いため)
    private func openRankingFromSheet() {
        statsSheetFocus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showRanking = true
        }
    }
    @State private var totalBlockSeconds: Int = 0
    /// 連続ロック日数 (get_user_stats RPC 由来)。他人のプロフィールにも表示する仕様 (2026-07-16 統計パック)
    @State private var streakDays: Int = 0
    /// 完遂率 (直近30日・タイマーのみ、get_user_stats RPC 由来)
    @State private var completion: BlockSessionTracker.CompletionRate?
    /// 完遂率 (全期間)。統計セルの詳細シート用 (034 未適用の DB では nil)
    @State private var completionAllTime: BlockSessionTracker.CompletionRate?
    @State private var isLoadingProfile: Bool = true
    @State private var jumpPost: UserPost?
    @State private var reportTarget: ReportSheetView.Target?
    /// 審査中の異議申し立てがある自分の投稿 id (isSelf のグリッド表示用、2026-07-25 実機FB)
    @State private var appealPendingPostIds: Set<UUID> = []
    @State private var showBlockConfirm: Bool = false
    @State private var showReportThanks: Bool = false

    /// 累計ロック時間の表示 (BlockSessionTracker.formattedTotal() と同じ書式)
    private var totalLockText: String {
        let hours = totalBlockSeconds / 3600
        let minutes = (totalBlockSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var viewingPosts: [UserPost] {
        postService.viewingPosts(for: userId)
    }

    /// isSelf のときの制限中 (rejected/flagged) 投稿 id (申し立て状態の一括取得キー)
    private var selfModeratedPostIds: Set<UUID> {
        guard isSelf else { return [] }
        return Set(viewingPosts
            .filter { $0.moderationStatus == "rejected" || $0.moderationStatus == "flagged" }
            .map(\.id))
    }

    private var totalLikesReceived: Int {
        viewingPosts.reduce(0) { $0 + $1.likeCount }
    }

    /// 上位%表示。データ不足 (実績ゼロ or 母数10人未満) の時は "—"
    /// D案: TOP10%以内なら名前横の金タイポバッジに出す整数。圏外/母数不足は nil
    private var topPercentBadge: Int? {
        guard let p = percentile, p.hasData,
              (p.totalUsers ?? 0) >= 10,
              let top = p.topPercent else { return nil }
        let rounded = max(1, Int(top.rounded()))
        return rounded <= 10 ? rounded : nil
    }

    private var topPercentText: String {
        guard let percentile = percentile,
              percentile.hasData,
              (percentile.totalUsers ?? 0) >= 10,
              let topPercent = percentile.topPercent else {
            return "—"
        }
        let roundedPercent = max(1, Int(topPercent.rounded()))
        return L.profileTopPercentValue(roundedPercent, lang)
    }

    /// 完遂率表示 (直近30日・タイマーのみ)。データ不足 (対象セッション0件) の時は "—"
    private var completionRateText: String {
        guard let completion = completion,
              completion.hasData,
              let rate = completion.ratePercent else {
            return "—"
        }
        return L.profileCompletionValue(rate, lang)
    }

    /// 詳細シート用の完遂率行の値 (例: "92% (12/13回)")。nil / データ不足は "—"
    private func completionRowValue(_ c: BlockSessionTracker.CompletionRate?) -> String {
        guard let c, c.hasData, let rate = c.ratePercent,
              let done = c.completedCount, let total = c.eligibleCount else { return "—" }
        return L.statInfoCompletionRow(rate, done, total, lang)
    }

    /// 詳細シート用の順位行の値 (例: "3位 / 128人中")
    private var rankRowValue: String {
        guard let p = percentile, p.hasData,
              let rank = p.rank, let total = p.totalUsers else { return "—" }
        return L.statInfoRankRow(rank, total, lang)
    }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var isSelf: Bool {
        auth.userId == userId
    }

    private var isFollowing: Bool {
        followService.isFollowingUser(userId: userId)
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    profileHeader
                    postsSection
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
        .toolbar {
            if !isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            reportTarget = .user(userId)
                        } label: {
                            Label(L.moderationReport(lang), systemImage: "flag")
                        }
                        Button(role: .destructive) {
                            showBlockConfirm = true
                        } label: {
                            Label(L.moderationBlock(lang), systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .task(id: selfModeratedPostIds) {
            guard isSelf, !selfModeratedPostIds.isEmpty else {
                appealPendingPostIds = []
                return
            }
            appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: selfModeratedPostIds)
        }
        .task {
            displayName = initialDisplayName
            avatarUrl = initialAvatarUrl
            await loadProfile()
            await postService.loadPosts(byUser: userId)
            if !isSelf {
                isFollowedBy = await followService.isFollowedBy(userId: userId)
            }
        }
        .navigationDestination(isPresented: $showRanking) {
            RankingView()
        }
        .sheet(item: $statsSheetFocus) { focus in
            lockStatsSheet(focus: focus)
        }
        // viewingPostsByUser は userId をキーに保持するキー付きストアなので、この画面が
        // 自分自身の上に再度 push されていても互いのデータを上書き/クリアしない。
        // そのため pop 時のクリアは不要 (このプロフィールが再訪された時は .task が再取得する)。
        // push 遷移 (fullScreenCover だと右スワイプバックが構造的に効かないため navigationDestination に統一)
        .navigationDestination(item: $jumpPost) { post in
            MyPostsFeedView(
                posts: viewingPosts,
                startIndex: viewingPosts.firstIndex(where: { $0.id == post.id }) ?? 0,
                authorDisplayName: displayName,
                authorAvatarUrl: avatarUrl,
                authorIsPro: isPro,
                canDelete: isSelf
            )
        }
        .sheet(item: $reportTarget) { target in
            ReportSheetView(target: target, onSubmitted: { showReportThanks = true })
        }
        .alert(L.moderationBlockConfirmTitle(lang), isPresented: $showBlockConfirm) {
            Button(L.moderationReportCancel(lang), role: .cancel) {}
            Button(L.moderationBlock(lang), role: .destructive) {
                Task {
                    await BlockService.shared.block(userId: userId)
                    dismiss()
                }
            }
        } message: {
            Text(L.moderationBlockConfirmMessage(lang))
        }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Header (BeReal 風ヒーロー、2026-07-10)

    private var profileHeader: some View {
        ProfileHeroHeader(
            hero: .url(avatarUrl),
            displayName: displayName ?? "—",
            isPro: isPro,
            isOfficial: isOfficial,
            handle: handle,
            bio: bio,
            // 夢は公開 (is_public=true) の行だけ RLS が返す (非公開なら user_dreams が 0 行 = 非表示)
            dreamText: dream,
            // D案 (2026-07-30): チップ全廃。統計行=フォロワー/累計ロック/いいね、
            // TOP10%のみ名前横に金タイポ (earned)。連続・完遂率は非公開化 (本人のマイページのみ)。
            // フォロー中の数字は表示から外す (他人のフォロー中一覧はもともと導線なし)。
            // 相互フォロー時はボタンが「相互フォロー」+双方向アイコンに変わる
            topPercent: topPercentBadge,
            onTopPercentTap: {
                statsSheetFocus = .topPercent
            },
            stats: [
                ProfileHeroStat(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang)),
                ProfileHeroStat(value: totalLockText, label: L.profileLockTime(lang), action: {
                    statsSheetFocus = .lockTime
                }),
                ProfileHeroStat(value: "\(totalLikesReceived)", label: L.profileLikes(lang))
            ],
            actionTitle: isSelf ? nil : (isFollowing && isFollowedBy
                ? (lang == .japanese ? "相互フォロー" : "Mutuals")  // 文言はユーザー添削待ち
                : L.authorFollowButton(isFollowing, lang)),
            actionIsProminent: !isFollowing,
            actionIcon: isFollowing ? (isFollowedBy ? "arrow.left.arrow.right" : "checkmark") : "plus",
            onAction: {
                Task { await followService.toggleUserFollow(userId: userId) }
            }
        )
    }

    // MARK: - 統計シート (D案: 累計ロックタップ。他人プロフィール版=連続日数なし)

    /// 統計シート (2026-07-30 高級化: 入口の統計が主役。共通実装=ProfileStatsSheet、他人版=連続なし)
    private func lockStatsSheet(focus: ProfileStatsSheet.Focus) -> some View {
        let common: [ProfileStatsSheetRow] = [
            .init(icon: "checkmark.circle", label: L.statSheetCompletion30(lang), value: completionRowValue(completion)),
            .init(icon: "infinity", label: L.statSheetCompletionAll(lang), value: completionRowValue(completionAllTime))
        ]
        let rows: [ProfileStatsSheetRow] = focus == .lockTime
            ? common + [
                .init(icon: "percent", label: L.profileTopPercent(lang), value: topPercentText),
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet)
            ]
            : [
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet),
                .init(icon: "lock.fill", label: L.profileLockTime(lang), value: totalLockText)
            ] + common
        return ProfileStatsSheet(
            focus: focus,
            lockTimeText: totalLockText,
            topPercentValue: topPercentBadge,
            topPercentText: topPercentText,
            rows: rows
        )
    }

    // MARK: - Posts Section

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.authorQuotes(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            if viewingPosts.isEmpty {
                Text(L.authorNoQuotes(lang))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(viewingPosts) { post in
                        UserPostGridCell(
                            post: post,
                            onTap: { jumpPost = post },
                            // 検索等から自分のプロフィールをこの画面で開いた場合も制限状態を明示する
                            showsModerationState: isSelf,
                            isAppealPending: isSelf && appealPendingPostIds.contains(post.id)
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Helpers

    private func loadProfile() async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }

        struct UserRow: Decodable {
            let displayName: String?
            let avatarUrl: String?
            let handle: String?
            let bio: String?
            let isPro: Bool?
            let isOfficial: Bool?
            let totalBlockSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case avatarUrl   = "avatar_url"
                case handle
                case bio
                case isPro       = "is_pro"
                case isOfficial  = "is_official"
                case totalBlockSeconds = "total_block_seconds"
            }
        }

        struct FollowerRow: Decodable {
            let id: UUID
        }

        do {
            let row: UserRow = try await SupabaseManager.shared.client
                .from("users")
                .select("display_name, avatar_url, handle, bio, is_pro, is_official, total_block_seconds")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            self.displayName = row.displayName ?? self.displayName
            self.avatarUrl   = row.avatarUrl   ?? self.avatarUrl
            self.handle      = row.handle
            self.bio         = row.bio
            self.isPro       = row.isPro ?? false
            self.isOfficial  = row.isOfficial ?? false
            self.totalBlockSeconds = row.totalBlockSeconds ?? 0
        } catch {
            print("⚠️ Failed to load user profile: \(error)")
        }

        // 夢: user_dreams (024 v2)。非公開の行は RLS で本人以外に返らないため、
        // ここでの出し分けは不要 (行が返らない = 非表示)。アプリ側フィルタだけの
        // 旧方式は API 直叩きで非公開の夢が読めてしまうため廃止した
        do {
            struct DreamRow: Decodable { let dream: String? }
            let rows: [DreamRow] = try await SupabaseManager.shared.client
                .from("user_dreams")
                .select("dream")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            self.dream = rows.first?.dream
        } catch {
            print("⚠️ Failed to load user dream: \(error)")
        }

        do {
            let rows: [FollowerRow] = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id")
                .eq("followed_user_id", value: userId.uuidString)
                .execute()
                .value
            self.followerCount = rows.count
        } catch {
            print("⚠️ Failed to load follower count: \(error)")
        }

        // フォロー中 (このユーザーがフォローしている数 = 1%公式 + 一般ユーザー合算)。
        // head + count で件数だけもらう
        do {
            let response = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .execute()
            self.followingCount = response.count ?? 0
        } catch {
            print("⚠️ Failed to load following count: \(error)")
        }

        // 統計 (上位% / 連続日数 / 完遂率) を1 RPCで取得 (033 get_user_stats)。
        // 累計ロック秒数は上の users select で既に取得済みなのでここでは使わない
        // (RPC失敗時のフォールバック表示を users select 由来のまま残すため二重取得しない)
        do {
            struct UserStatsResponse: Decodable {
                let streakDays: Int
                let percentile: BlockSessionTracker.BlockPercentile
                let completion: BlockSessionTracker.CompletionRate
                // 034 で追加。033 のみ適用の DB ではキーが無いため Optional
                let completionAllTime: BlockSessionTracker.CompletionRate?

                enum CodingKeys: String, CodingKey {
                    case streakDays = "streak_days"
                    case percentile
                    case completion
                    case completionAllTime = "completion_all_time"
                }
            }
            let params: [String: AnyJSON] = [
                "target_user_id": .string(userId.uuidString),
                "tz": .string(TimeZone.current.identifier)
            ]
            let result: UserStatsResponse = try await SupabaseManager.shared.client
                .rpc("get_user_stats", params: params)
                .execute()
                .value
            self.streakDays = result.streakDays
            self.percentile = result.percentile
            self.completion = result.completion
            self.completionAllTime = result.completionAllTime
        } catch {
            print("⚠️ Failed to load user stats: \(error)")
        }
    }
}

