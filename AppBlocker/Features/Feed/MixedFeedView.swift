//
//  MixedFeedView.swift
//  AppBlocker
//
//  混在フィード (公式 quotes + UGC user_posts)。上部に「おすすめ / フォロー中」セグメント。
//  2026-07-10 BeReal 風改修: 全画面 TikTok ページング → FeedCardListView (4:5 カードリスト)。
//  カード実装 / モデレーションメニュー / コメントページ遷移はすべて FeedCardListView に集約。
//

import SwiftUI

/// 画像保存失敗時の alert 表示用。`isPermissionError` true なら「設定を開く」ボタンを追加表示する。
struct SaveImageAlert: Identifiable {
    let id = UUID()
    let message: String
    let isPermissionError: Bool
}

struct MixedFeedView: View {
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var selectedSegment: Segment = .recommended
    /// タブ再タップ更新中に、引っ張って更新と同じ「くるくる」をセグメントバーの下に出す
    /// (2026-08-04 実機FB)。SwiftUI の refreshable はプログラムから発火できないため
    /// (公開APIが無い)、同じ見た目を safeAreaInset の高さアニメーションで自前で作る。
    /// 高さが増える = スクロール領域が押し下げられるので「引っ張られた」見え方になる
    @State private var isTabRefreshing = false

    enum Segment: Hashable {
        case recommended
        case following
    }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                Group {
                    switch selectedSegment {
                    case .recommended:
                        recommendedContent
                    case .following:
                        followingContent
                    }
                }
            }
            // セグメントバーは safeAreaInset で上に固定する。こうすると pull-to-refresh の
            // くるくるがバーの「下」に出て、おすすめ/フォロー中の文字に被らない (実機FB 2026-07-10)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    segmentBar

                    // タブ再タップ更新中のくるくる。バーの「下」に出すのは
                    // pull-to-refresh の時と同じ位置 (おすすめ/フォロー中の文字に被らない)
                    if isTabRefreshing {
                        ProgressView()
                            .tint(.white)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isTabRefreshing)
            }
            // 取得失敗を黙って握りつぶさない (2026-07-31)。更新が空振りした時に
            // 「何も起きない」ではなく理由が出るようにする。数秒で自動的に消える
            .overlay(alignment: .top) {
                if let error = feedService.lastFeedError {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(AppColors.error.opacity(0.9))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { feedService.clearFeedError() }
                        .task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            feedService.clearFeedError()
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: feedService.lastFeedError)
            .navigationBarHidden(true)
        }
        // 選択中のフィードタブ再タップ → 表示中セグメントを引っ張って更新と同じ内容で再取得
        // (2026-08-04 ユーザー要望)。取得関数は refreshable が呼ぶものと同一。
        // 通知は「既にフィードタブにいる時」しか飛ばないので、裏のタブで受けることはない
        .onReceive(NotificationCenter.default.publisher(for: .reloadFeedTab)) { _ in
            reloadCurrentSegment()
        }
        .task {
            // おすすめ / フォロー中 / 累計ロック統計は互いに独立しているので並列に読み込む
            // (直列だと合計待ち時間が3つの合計になり、初回表示が体感で遅い)
            async let recommended: Void = feedService.recommendedFeed.isEmpty ? feedService.loadRecommended() : ()
            async let following: Void = feedService.followingFeed.isEmpty ? feedService.loadFollowing() : ()
            async let stats: Void = sessionTracker.loadStats()
            _ = await (recommended, following, stats)
        }
    }

    // MARK: - Segment Bar

    private var segmentBar: some View {
        ZStack {
            HStack(spacing: 24) {
                segmentButton(.recommended, title: L.feedRecommended(lang))
                segmentButton(.following,   title: L.feedFollowing(lang))
            }
            // ストリークバッジはフィードには置かない (ユーザー指定 2026-07-06: タイマーとマイページのみ)
            // 虫眼鏡ボタンは 2026-07-15 検索タブ (SearchView) 新設に伴い撤去
        }
        // 虫眼鏡撤去時に幅を張っていた HStack{Spacer()} も消えてバーがラベル幅まで縮み、
        // 黒背景が全幅に届かない退行が出た (実機FB第11弾 2026-07-16)。明示的に全幅へ戻す
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // 実機FB第14弾 (2026-07-16): 背景帯は完全廃止して透明に (ユーザー第一案)。
        // マテリアル (第12弾) は灰色に濁り、黒スクリム (第13弾) は帯の境界線が見えて両方不合格。
        // 文字は segmentButton 内の黒シャドウで立たせる (TikTok と同じ構造 = 帯の境界問題が構造的に消える)
    }

    private func segmentButton(_ segment: Segment, title: String) -> some View {
        let isSelected = selectedSegment == segment
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSegment = segment
            }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.5))

                Rectangle()
                    .fill(isSelected ? Color.white : Color.clear)
                    .frame(width: 24, height: 2)
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
        }
    }

    // MARK: - Recommended

    @ViewBuilder
    private var recommendedContent: some View {
        if feedService.isLoadingRecommended && feedService.recommendedFeed.isEmpty {
            loadingView
        } else if feedService.recommendedFeed.isEmpty {
            emptyRecommendedView
        } else {
            FeedCardListView(
                items: feedService.recommendedFeed,
                recordsViews: false,  // ホームのスクロール通過は「タップ」ではない (post_views 汚染防止)
                onBlocked: { reloadBothFeeds() },
                // タブ再タップ更新中 (isTabRefreshing) の引き下げは取得をスキップする
                // (2026-08-04 レビュー指摘: ガード無しだと同じ取得が並行2本走り、
                //  last-writer-wins でリストが2回入れ替わって見える。どうせ同じデータを
                //  取りに行っている最中なので、くるくるだけ見せて2本目は投げない)
                onRefresh: { if !isTabRefreshing { await feedService.loadRecommended() } },
                showsAds: true  // 広告はホームフィード限定 (2026-07-31 広告v1)
            )
        }
    }

    // MARK: - Following

    @ViewBuilder
    private var followingContent: some View {
        if feedService.isLoadingFollowing && feedService.followingFeed.isEmpty {
            loadingView
        } else if feedService.followingFeed.isEmpty {
            emptyFollowingView
        } else {
            FeedCardListView(
                items: feedService.followingFeed,
                recordsViews: false,  // ホームのスクロール通過は「タップ」ではない (post_views 汚染防止)
                onBlocked: { reloadBothFeeds() },
                // おすすめ側と同じ二重取得ガード (2026-08-04 レビュー指摘)
                onRefresh: { if !isTabRefreshing { await feedService.loadFollowing() } },
                showsAds: true  // 広告はホームフィード限定 (2026-07-31 広告v1)
            )
        }
    }

    /// 表示中のセグメントだけを再取得する (タブ再タップ用)。
    /// FeedService 側に多重実行ガードが無く、タブは連打しやすいので取得中は無視する。
    /// 取得中は isTabRefreshing でくるくるを出す (見た目は pull-to-refresh と同じ)。
    private func reloadCurrentSegment() {
        guard !isTabRefreshing else { return }
        let feedIsEmpty: Bool
        switch selectedSegment {
        case .recommended:
            guard !feedService.isLoadingRecommended else { return }
            feedIsEmpty = feedService.recommendedFeed.isEmpty
        case .following:
            guard !feedService.isLoadingFollowing else { return }
            feedIsEmpty = feedService.followingFeed.isEmpty
        }

        // 空フィードの時はバー下のくるくるを出さない (2026-08-04 レビュー指摘:
        // isLoading && isEmpty で中央の loadingView が出るため、両方出すと2枚になる)
        isTabRefreshing = !feedIsEmpty
        // 取得は非構造化 Task で行う (FeedCardListView の refreshable と同じ理由:
        // ビュー再構成で URLSession ごとキャンセルされるのを避ける)
        Task {
            let started = Date()
            switch selectedSegment {
            case .recommended: await feedService.loadRecommended()
            case .following:   await feedService.loadFollowing()
            }
            // 取得が速すぎるとくるくるが瞬きのように消えるので最低 0.6 秒は見せる
            // (refreshable 側の 0.5 秒と同じ思想。こちらは指を離す待ちが無いぶん少し長く)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.6 {
                try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000))
            }
            isTabRefreshing = false
        }
    }

    private func reloadBothFeeds() {
        Task {
            async let recommended: Void = feedService.loadRecommended()
            async let following: Void = feedService.loadFollowing()
            _ = await (recommended, following)
        }
    }

    // MARK: - Empty / Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white).scaleEffect(1.5)
            Text(L.feedLoading(lang))
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRecommendedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.white.opacity(0.4))
            Text(L.feedPostsEmpty(lang))
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFollowingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.white.opacity(0.4))
            Text(L.feedFollowingEmpty(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(L.feedFollowingEmptySubtitle(lang))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Tag Feed View (ハッシュタグタップ → タグ別混在フィード)

struct TagFeedView: View {
    let tag: String
    let lang: AppLanguage
    let showOriginal: Bool

    @State private var items: [FeedItem] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(L.feedPostsEmpty(lang))
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FeedCardListView(
                    items: items,
                    recordsViews: false,  // タグ別フィードもスクロール一覧であり投稿詳細タップではない
                    onTagTapOverride: { _ in /* タグフィード内は何もしない */ },
                    onBlocked: {
                        let currentTag = tag
                        Task { items = await FeedService.shared.fetchTagFeed(tag: currentTag) }
                    }
                )
            }
        }
        .navigationTitle("#\(Quote.categoryDisplay(tag, lang: lang))")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            items = await FeedService.shared.fetchTagFeed(tag: tag)
            isLoading = false
        }
    }
}

#Preview {
    MixedFeedView()
}
