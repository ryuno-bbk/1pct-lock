//
//  MyProfileView.swift
//  AppBlocker
//
//  マイページ（TikTok 風プロフィール画面）
//  自分の投稿・いいね済み名言を表示、フォロー中はヘッダーの数字タップで別画面へ
//

import SwiftUI
import Supabase

struct MyProfileView: View {
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var quoteService = QuoteService.shared
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared
    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var notifService = NotificationService.shared
    @ObservedObject private var pushService = PushNotificationService.shared

    @State private var selectedSection: ProfileSection = .posts
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var jumpQuote: Quote?
    @State private var jumpPost: UserPost?
    /// いいねタブから開く投稿 (他人の投稿を含む)。jumpPost とは別に持つ —
    /// jumpPost の遷移先は「自分の投稿一覧」なので、他人の投稿を流し込むと別の投稿が開く
    @State private var jumpLikedPost: UserPost?
    /// グリッド長押し削除の確認ダイアログ対象 (即削除は事故のもとなので必ず確認を挟む)
    @State private var deleteCandidate: UserPost?
    @State private var followerCount: Int = 0
    @State private var showNotifications: Bool = false
    /// 順位ピル → ランキング画面 (2026-09-05)
    @State private var showRanking: Bool = false
    @State private var showProfileEdit: Bool = false
    // showFollowedAccounts は 2026-08-04 撤去。2026-07-30 の D案改2 でフォロー中の導線を
    // 設定 (SettingsListView) へ移した時に true を立てる箇所だけが消え、@State と
    // navigationDestination が発火しないまま残っていた。Bool 押し出しの
    // navigationDestination を同じビューに積むほど詰みやすくなる (下の push(_:) 参照) ので消す。
    // 画面自体は SettingsListView の「フォロー中のアカウント」から従来どおり開ける
    /// D案: 統計シート。sheet(item:) で出す — 非nil=表示中+シートの主役 (入口で変わる:
    /// 累計ロックタップ=ロック時間 / 上位%ピル=上位%)。2026-07-30 実機FB: isPresented+別@State
    /// だと初回 presentation がフォーカス設定前の状態で描かれるバグがあり item 方式へ
    @State private var statsSheetFocus: ProfileStatsSheet.Focus?
    /// D案改3: フォロワー数タップ→[フォロワー|フォロー中]タブ一覧 (IG方式)
    @State private var showFollowList: Bool = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var totalFollowing: Int {
        followService.followedAuthorIds.count + followService.followedUserIds.count
    }

    private var totalLikesReceived: Int {
        postService.myPosts.reduce(0) { $0 + $1.likeCount }
    }

    /// 上位%表示。データ不足 (実績ゼロ or 母数10人未満) の時は "—"
    private var topPercentText: String {
        guard let percentile = sessionTracker.percentile,
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
        guard let completion = sessionTracker.completion,
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
        guard let p = sessionTracker.percentile, p.hasData,
              let rank = p.rank, let total = p.totalUsers else { return "—" }
        return L.statInfoRankRow(rank, total, lang)
    }

    /// D案: TOP10%以内ならヒーロー右下の金タイポに出す整数。圏外/母数不足は nil (earned 設計)。
    /// 2026-07-31: デバッグビルドで 3% を仮表示していた確認用コードを撤去
    /// (見た目の確認は済んだ。残すとスクリーンショット撮影時に実データでない数字が写り込む)
    // 🔴 2026-09-09 実機FB: 順位だけのピル (「31位」) は撤去した。
    //    ユーザー判断「上位10%の人に『上位◯%』を出せばよく、それより下の人に
    //    順位ピルは要らない」。ProfileHero 側の rank/onRankTap は残してあるので
    //    出したくなったら1行渡すだけで戻せる。

    private var topPercentBadge: Int? {
        guard let p = sessionTracker.percentile, p.hasData,
              (p.totalUsers ?? 0) >= 10,
              let top = p.topPercent else { return nil }
        let rounded = max(1, Int(top.rounded()))
        return rounded <= 10 ? rounded : nil
    }

    // 非公開行 (D案初版) は 2026-07-30 実機FBで廃止: 連続日数はロックタブ右上へ、
    // 完遂率・現在位置は累計ロックタップのシート (他人にも公開) へ集約

    enum ProfileSection: String, CaseIterable, Identifiable {
        case posts, likes
        var id: String { rawValue }
        func label(_ lang: AppLanguage) -> String {
            switch self {
            case .posts: return L.postsMy(lang)
            case .likes: return L.profileLikes(lang)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        sectionPicker
                        content
                    }
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: ProfileHeroHeader.scrollSpace)
                // ヒーロー画像を画面上端 (ステータスバー下) までべったり付ける (BeReal 準拠)
                .ignoresSafeArea(edges: .top)
            }
            .navigationTitle(L.profileTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            // バー背景は透過してヒーロー画像に重ねる (ベル/歯車/ストリークは画像上に浮く)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // タイトル「マイページ」(2026-07-16 統計パック: 連続日数は下の統計グリッドに集約したため
                // ツールバーの StreakBadge は廃止 (機能ごと撤去済み))
                ToolbarItem(placement: .principal) {
                    Text(L.profileTitle(lang))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    notificationBell
                }
                // 🔴 右上にもベルを置いていたが撤去した (2026-08-29 ユーザー指示)。
                //    未読に気づかせる役目は**タブバーの人型アイコンのバッジ**が担う
                //    (MainTabView の .badge)。同じベルが左右に2つ並ぶ必要は無い
                // 2026-09-09 ユーザー指示: 歯車の左にランキングを置く。
                // ランキングへの入口が「下から出るカードの中」だけだと到達されないため
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        push($showRanking)
                    } label: {
                        Image(systemName: "trophy.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    NavigationLink {
                        SettingsListView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
            .navigationDestination(isPresented: $showNotifications) {
                NotificationListView()
            }
            .navigationDestination(isPresented: $showRanking) {
                RankingView()
            }
            .navigationDestination(isPresented: $showProfileEdit) {
                ProfileEditView()
            }
            .navigationDestination(isPresented: $showFollowList) {
                FollowListView()
            }
            .sheet(item: $statsSheetFocus) { focus in
                lockStatsSheet(focus: focus)
            }
            // プッシュ通知をタップして来た。既に表示中でも、タブ生成直後でも
            // 同じ経路で開けるよう onChange と task の両方から拾う
            .onChange(of: pushService.shouldOpenNotificationList) { _, shouldOpen in
                openNotificationListIfRequested(shouldOpen)
            }
            .task {
                // 常に likedQuoteIds ⇔ likedQuotes を再同期する (フィード側でいいねした直後の反映漏れ対策)
                await likeService.loadLikedQuoteObjects()
                // 2026-08-08: 投稿側も同じ理由で再同期する。これが無いとフィードで
                // 投稿にいいねした直後にタブを開いても出てこない
                await likeService.loadLikedPostObjects()
                await postService.loadMyPosts()
                // flushQueue (キュー反映) → loadStats (統計取得) の順を必ず守る。
                // 逆にするとキュー未反映分を含まない統計を読んでしまう
                await sessionTracker.flushQueue()
                await sessionTracker.loadStats()
                await loadFollowerCount()
                await notifService.refreshUnreadCount()
                openNotificationListIfRequested(pushService.shouldOpenNotificationList)
            }
            // push 遷移 (fullScreenCover だと右スワイプバックが構造的に効かないため navigationDestination に統一)
            .navigationDestination(item: $jumpQuote) { quote in
                FilteredQuoteFeedView(
                    title: L.profileLikes(lang),
                    quotes: likeService.likedQuotes,
                    startIndex: likeService.likedQuotes.firstIndex(where: { $0.id == quote.id }) ?? 0
                )
            }
            // 制限中の投稿に審査中の申し立てがあるかを一括取得 (FeedCardListView と同じ流儀)
            .task(id: moderatedPostIds) {
                guard !moderatedPostIds.isEmpty else {
                    appealPendingPostIds = []
                    return
                }
                appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: moderatedPostIds)
            }
            .navigationDestination(item: $jumpPost) { post in
                MyPostsFeedView(
                    posts: postService.myPosts,
                    startIndex: postService.myPosts.firstIndex(where: { $0.id == post.id }) ?? 0
                )
            }
            // いいねタブから開く投稿 (2026-08-08)。著者が投稿ごとに違うので、
            // MyPostsFeedView に複数渡すと1人ぶんの著者情報しか反映できない。
            // タップした1件だけを渡し、その投稿の著者を明示する。
            // ⚠️ canDelete: false は必須 (他人の投稿に削除ボタンを出さない)
            .navigationDestination(item: $jumpLikedPost) { post in
                let author = likeService.likedPostAuthors[post.userId]
                MyPostsFeedView(
                    posts: [post],
                    startIndex: 0,
                    authorDisplayName: author?.displayName,
                    authorAvatarUrl: author?.avatarUrl,
                    authorIsPro: author?.isPro ?? false,
                    canDelete: false
                )
            }
        }
    }

    /// 審査中の異議申し立てがある自分の投稿 id (グリッドの「異議申し立て中」表示用、2026-07-25 実機FB)
    @State private var appealPendingPostIds: Set<UUID> = []

    private var moderatedPostIds: Set<UUID> {
        Set(postService.myPosts
            .filter { $0.moderationStatus == "rejected" || $0.moderationStatus == "flagged" }
            .map(\.id))
    }

    // MARK: - Grid Tap (実機FB#7 対策)

    /// 実機FB#7 (2026-07-20 初出、2026-07-22 投稿直後の再現手順が確定): navigationDestination(item:)
    /// の push が黙って失敗すると item が非 nil のまま残り、同じ投稿を再タップしても
    /// 「値が変わらない = 遷移が発火しない」ためグリッドが永久に無反応になる
    /// (タブ切替では回復せず、通知ページ往復などで NavigationStack が再同期されるまで詰む)。
    /// 詰み状態を検知したら一度 nil に戻し、次ランループで積み直して2度目以降のタップを
    /// 確実に成立させる。初回 push が落ちる根本原因 (投稿直後トリガー) は別途実機調査。
    private func openPost(_ post: UserPost) {
        if jumpPost != nil {
            jumpPost = nil
            DispatchQueue.main.async { jumpPost = post }
        } else {
            jumpPost = post
        }
    }

    /// openPost と同じガード (いいね名言グリッド側)
    private func openQuote(_ quote: Quote) {
        if jumpQuote != nil {
            jumpQuote = nil
            DispatchQueue.main.async { jumpQuote = quote }
        } else {
            jumpQuote = quote
        }
    }

    /// Bool で押し出す navigationDestination(isPresented:) 用の同じガード (2026-08-04)。
    /// 実機バグ: 「プロフィールを編集」を一度開いて戻ると二度と反応しなくなる。
    /// item: 版 (openPost) とまったく同じ詰み方で、push が黙って失敗する / pop でバインディングが
    /// false へ書き戻されないと true のまま残り、再度 `= true` を代入しても
    /// 「値が変わらない = 遷移が発火しない」でボタンが永久に死ぬ。
    /// 既に true (=詰み) なら一度 false に戻し、少し置いてから積み直して2度目以降を成立させる。
    /// ⚠️ これは復帰措置であって根治ではない (初回 push が落ちる原因は別)。
    ///
    /// asyncAfter 0.05 秒なのは 2026-08-04 レビュー指摘: openPost (item版) が動くのは
    /// async 積み直しの効果ではなく「タップごとに値そのものが変わる」からで、Bool には
    /// その逃げ道が無い。素の DispatchQueue.main.async は現在の CATransaction commit 前に
    /// drain されることがあり、false→true が同一更新パスに合成されると「変化なし」扱いで
    /// 遷移が発火しない。0.05 秒の遅延で別トランザクションを確実にまたぐ
    /// (詰み時のみ通る経路なので、正常系のタップに遅延は一切入らない)。
    private func push(_ flag: Binding<Bool>) {
        if flag.wrappedValue {
            flag.wrappedValue = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flag.wrappedValue = true }
        } else {
            flag.wrappedValue = true
        }
    }

    // 投稿導線はタブバー中央の＋に移設 (2026-07-11 ユーザー確定。旧: 右下 FAB)

    /// プッシュ通知タップの要求を1回だけ消化して通知一覧を開く
    private func openNotificationListIfRequested(_ shouldOpen: Bool) {
        guard shouldOpen else { return }
        pushService.shouldOpenNotificationList = false
        push($showNotifications)
    }

    // MARK: - Notification Bell

    /// 通知への導線 (ベル + 未読バッジ)。左上と右上の両方に同じものを置くので、
    /// 必ずこの1箇所から作ること (片方だけ直して見た目がずれるのを防ぐ)
    private var notificationBell: some View {
        Button {
            push($showNotifications)
        } label: {
            // 実機FB (2026-07-25): ベルは原寸のまま中央に置き、見えない器 (26×24) だけ
            // わずかに広げてバッジをその右上角に重ねる。バッジはベルのアイコン自体に
            // かぶさって「はみ出て見える」が、器の外には出ないので見切れない
            // (offset で枠外に出す方式はボタン境界で右上が欠けた)
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 26, height: 24)
                if notifService.unreadCount > 0 {
                    unreadBadge(count: notifService.unreadCount)
                }
            }
        }
    }

    // MARK: - Unread Badge

    private func unreadBadge(count: Int) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color.red))
    }

    // MARK: - Header (BeReal 風ヒーロー、2026-07-10 / 2026-07-16 統計パックで2×2グリッド化)
    // 統計 = フォロワー / フォロー中 / いいね。累計ロック / 連続 / 完遂率 / 上位% は
    // アクションボタン下の 2×2 グリッド (chips) に完全集約。

    private var header: some View {
        ProfileHeroHeader(
            hero: .url(auth.avatarUrl?.absoluteString),
            displayName: auth.displayName?.isEmpty == false ? auth.displayName! : "—",
            isPro: auth.isPro,
            handle: auth.handle,
            bio: auth.bio,
            // 夢 (宣言) は本人には公開/非公開に関わらず見せる。非公開のときは鍵で示す
            dreamText: auth.dream,
            dreamLocked: !(auth.dream?.isEmpty ?? true) && !auth.dreamIsPublic,
            // D案 (2026-07-30): チップ全廃。統計行=フォロワー/累計ロック/いいね、
            // TOP10%のみ名前横に金タイポ、連続・完遂率 (+圏外の現在位置) は本人のみの非公開行。
            // フォロー中は統計行から followingLink (ヘッダー直下) へ、旧チップの詳細は
            // 累計ロックタップの lockStatsSheet に集約
            topPercent: topPercentBadge,
            onTopPercentTap: {
                statsSheetFocus = .topPercent
            },
            stats: [
                ProfileHeroStat(value: followerCount.abbreviatedCount(lang), label: L.authorFollowers(lang), action: {
                    push($showFollowList)
                }),
                ProfileHeroStat(value: sessionTracker.formattedTotal(), label: L.profileLockTime(lang), action: {
                    statsSheetFocus = .lockTime
                }),
                ProfileHeroStat(value: "\(totalLikesReceived)", label: L.profileLikes(lang))
            ],
            actionTitle: L.settingsEditProfile(lang),
            actionIsProminent: false,
            onAction: { push($showProfileEdit) }
        )
    }

    // MARK: - 統計シート (D案)
    // フォロー中の導線は 2026-07-30 実機FBでプロフィールから撤去し、設定 (SettingsListView) の
    // アカウント節へ移動 (低頻度の管理機能=設定が定位置。プロフィールは何も足さない)

    /// 統計シート (2026-07-30 高級化: 入口の統計が主役になる。共通実装=ProfileStatsSheet)
    /// 連続日数の行は 2026-07-30 実機FBで撤去 (ロックタブ右上の本人専用表示に一本化)
    /// 🔴 統計シートの中から画面遷移はできない (シートに NavigationStack が無い)。
    ///    先にシートを閉じ、閉じ切ってから push する (解除方法シート → ペイウォールと同じ手)
    private func openRankingFromSheet() {
        statsSheetFocus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            push($showRanking)
        }
    }

    private func lockStatsSheet(focus: ProfileStatsSheet.Focus) -> some View {
        let common: [ProfileStatsSheetRow] = [
            .init(icon: "checkmark.circle", label: L.statSheetCompletion30(lang), value: completionRowValue(sessionTracker.completion)),
            .init(icon: "infinity", label: L.statSheetCompletionAll(lang), value: completionRowValue(sessionTracker.completionAllTime))
        ]
        let rows: [ProfileStatsSheetRow] = focus == .lockTime
            ? common + [
                .init(icon: "percent", label: L.profileTopPercent(lang), value: topPercentText),
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet)
            ]
            : [
                .init(icon: "trophy", label: L.statInfoRank(lang), value: rankRowValue, action: openRankingFromSheet),
                .init(icon: "lock.fill", label: L.profileLockTime(lang), value: sessionTracker.formattedTotal())
            ] + common
        return ProfileStatsSheet(
            focus: focus,
            lockTimeText: sessionTracker.formattedTotal(),
            topPercentValue: topPercentBadge,
            topPercentText: topPercentText,
            rows: rows
        )
    }

    // MARK: - Picker

    private var sectionPicker: some View {
        Picker("", selection: $selectedSection) {
            ForEach(ProfileSection.allCases) { section in
                Text(section.label(lang)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .posts: postsContent
        case .likes: likesContent
        }
    }

    @ViewBuilder
    private var postsContent: some View {
        if postService.myPosts.isEmpty {
            emptyPlaceholder(
                systemImage: "square.and.pencil",
                title: L.postsNone(lang),
                subtitle: L.postsNoneSubtitle(lang)
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(postService.myPosts) { post in
                    UserPostGridCell(
                        post: post,
                        onTap: { openPost(post) },
                        showsModerationState: true,
                        isAppealPending: appealPendingPostIds.contains(post.id)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteCandidate = post
                        } label: {
                            Label(L.postsDelete(lang), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            // 完全削除 (DB + Storage、復元不可) のため必ず二重確認を挟む。
            // 2026-07-22 実機FB: confirmationDialog → 画面中央の標準 alert に統一 (削除確認の全箇所で同形式)
            .alert(
                L.postsDeleteConfirmTitle(lang),
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                )
            ) {
                Button(L.postsComposerCancel(lang), role: .cancel) {
                    deleteCandidate = nil
                }
                Button(L.postsDeleteAction(lang), role: .destructive) {
                    if let target = deleteCandidate {
                        let pid = target.id
                        Task { @MainActor in await postService.deletePost(pid) }
                    }
                    deleteCandidate = nil
                }
            } message: {
                Text(L.postsDeleteConfirmMessage(lang))
            }
        }
    }

    @ViewBuilder
    private var likesContent: some View {
        // 🔴 2026-08-08: 以前は likedQuotes だけを見ていたため、公式アカウントの名言に
        // いいねした時しかここに出ず、普通のユーザーの投稿へのいいねが全部消えていた
        if likeService.likedQuotes.isEmpty && likeService.likedPosts.isEmpty {
            emptyPlaceholder(
                systemImage: "heart.slash",
                title: L.profileNoLikes(lang),
                subtitle: L.profileNoLikesSubtitle(lang)
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                // いいねした投稿 (2026-08-08 追加)。自分のグリッドではないので
                // モデレーション状態は出さない (他人の投稿の審査状態を見せる筋合いが無い)
                ForEach(likeService.likedPosts) { post in
                    UserPostGridCell(
                        post: post,
                        // ⚠️ openPost (自分の投稿一覧へ飛ぶ) を使ってはいけない。
                        // 他人の投稿は postService.myPosts に居ないので firstIndex が nil になり、
                        // 無関係な自分の投稿が開く
                        onTap: { jumpLikedPost = post }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            let pid = post.id
                            Task { @MainActor in
                                await likeService.togglePostLike(postId: pid)
                                likeService.removeFromLikedPosts(postId: pid)
                            }
                        } label: {
                            Label(L.profileUnlike(lang), systemImage: "heart.slash")
                        }
                    }
                }

                ForEach(likeService.likedQuotes) { quote in
                    LikedQuoteGridCell(
                        quote: quote,
                        onTap: { openQuote(quote) }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            let qid = quote.id
                            Task { @MainActor in
                                await likeService.unlike(quoteId: qid)
                                likeService.removeFromLikedQuotes(quoteId: qid)
                            }
                        } label: {
                            Label(L.profileUnlike(lang), systemImage: "heart.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func loadFollowerCount() async {
        guard let uid = auth.userId else {
            followerCount = 0
            return
        }
        struct FollowerRow: Decodable { let id: UUID }
        do {
            let rows: [FollowerRow] = try await SupabaseManager.shared.client
                .from("user_follows")
                .select("id")
                .eq("followed_user_id", value: uid.uuidString)
                .execute()
                .value
            self.followerCount = rows.count
        } catch {
            print("⚠️ Failed to load my follower count: \(error)")
        }
    }

    private func emptyPlaceholder(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

#Preview {
    MyProfileView()
}
