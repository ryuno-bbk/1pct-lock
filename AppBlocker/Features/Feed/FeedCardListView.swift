//
//  FeedCardListView.swift
//  AppBlocker
//
//  FeedListCard を縦に並べる共通の詳細フィード (2026-07-10 確定仕様)。
//  プロフィールのグリッドタップ / いいね一覧 / 著者トピック / タグフィードが
//  すべてこの 1 つの View を使う (旧: FeedItemCard の全画面 TikTok スクロール群)。
//
//  - startItemKey (FeedItem.id) までスクロールした状態で開く
//  - post カードが表示されたら record_post_view で閲覧計上 (タップ数の実体)
//  - コメントは CommentPageView へ push (シート廃止)
//  - canDeletePosts = true (自分の投稿) なら … メニューに削除、rejected バッジ表示
//

import SwiftUI

struct FeedCardListView: View {

    let items: [FeedItem]
    /// このリストが「投稿詳細が開かれた」タップとして record_post_view を計上すべきか。
    /// ホームフィード (おすすめ/フォロー中) やタグ/著者/いいね一覧などの「スクロールで通り過ぎるだけ」の
    /// 面では false にする (029 の w_seen ペナルティが読む post_views をスクロール通過で汚染しないため)。
    /// デフォルトを設けず全呼び出し元に明示させる
    let recordsViews: Bool
    /// 開いた時にスクロールしておく位置 (FeedItem.id)。nil なら先頭
    var startItemKey: String? = nil
    /// 自分の投稿フィードか (… メニューに削除を出す / rejected バッジ表示)
    var canDeletePosts: Bool = false
    /// AI モデレーション rejected の投稿 id (自分の投稿のみバッジ表示)
    var rejectedPostIds: Set<UUID> = []
    /// AI モデレーション flagged の投稿 id (自分の投稿のみ上端バナー表示。039 以降は本人に可視化する方針)
    var flaggedPostIds: Set<UUID> = []
    /// タグフィード内でのタグタップ無効化など、親が挙動を差し替えたい時に指定
    var onTagTapOverride: ((String) -> Void)? = nil
    /// 著者トピックフィード自身の中では「— 著者名」タップを無効化する (既にその著者の一覧のため)
    var disableTopicTap: Bool = false
    /// いいねトグル後に親へ通知 (いいね一覧のグリッド同期など)。(item, いいね後の状態)
    var onLikeToggled: ((FeedItem, Bool) -> Void)? = nil
    /// ブロック実行後に親へ通知 (リスト再取得など)
    var onBlocked: (() -> Void)? = nil
    /// pull-to-refresh (nil なら無効)。ホームフィードのおすすめ/フォロー中用
    var onRefresh: (() async -> Void)? = nil
    /// 上部の追加余白 (ホームのセグメントバーぶんなど)
    var topContentInset: CGFloat = 0
    /// AdMob ネイティブ広告をN件ごとに差し込むか (2026-07-31 広告v1)。
    /// ホームフィード (おすすめ/フォロー中) だけ true。プロフィール/タグ/いいね一覧などの
    /// 派生フィードには一切出さない (ユーザー指定「フィード画面以外には出さない」)。
    /// items 配列には混ぜず描画側で差し込む = 062/063 のスコアリング/キャップに影響しない
    var showsAds: Bool = false
    /// カードが「画面に半分以上見えているか」が変わったら親に伝える
    /// (解除課題の滞在時間計測に使う)。nil なら何もしない = 通常のフィードには影響しない。
    /// 🔴 onAppear/onDisappear だと判定が厳しすぎて、少し動かしただけで計測が切れる
    var onItemVisibilityChanged: ((FeedItem, Bool) -> Void)? = nil

    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var followService = FollowService.shared
    @ObservedObject private var blockService = BlockService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var extrasService = FeedExtrasService.shared
    @ObservedObject private var postService = UserPostService.shared
    @ObservedObject private var commentService = CommentService.shared

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    @Environment(\.dismiss) private var dismiss

    @State private var scrollTargetKey: String?
    /// 指が画面に触れている間 true (引き下げ更新を「離した瞬間」に走らせるために使う)
    @State private var isFingerDown = false
    @State private var showOfficialProfile = false
    @State private var selectedTopicAuthor: Author?
    @State private var selectedTopicQuotes: [Quote] = []
    @State private var selectedTopicStartIndex: Int = 0
    @State private var showTopicFeed = false
    @State private var selectedUserId: UUID?
    @State private var selectedUserName: String?
    @State private var showUserProfile = false
    @State private var selectedTag: String?
    @State private var showTagFeed = false
    @State private var commentPageRequest: CommentPageRequest?
    /// commentPageRequest が nil に戻った瞬間に extras キャッシュを無効化するため、
    /// 直近に開いたコメントページの対象アイテムキーを保持する (F6)
    @State private var lastCommentItemKey: String?
    @State private var reportTarget: ReportSheetView.Target?
    /// 異議申し立てシートの対象 (rejected スクリムの「異議申し立て」ボタン / flagged バナーの「異議申し立て」ボタンから)
    @State private var appealTarget: AppealTarget?
    /// 審査中 (pending) の異議申し立てがある自分の投稿 id (制限オーバーレイのピルを
    /// 「異議申し立て中」表示に切り替える。2026-07-23 実機FB)
    @State private var appealPendingPostIds: Set<UUID> = []
    @State private var blockCandidateUserId: UUID?
    @State private var showBlockConfirm = false
    @State private var showReportThanks = false
    @State private var saveToastMessage: String?
    @State private var saveAlert: SaveImageAlert?
    @State private var deleteCandidatePostId: UUID?
    /// いいねした人一覧シートの対象 (スタックタップで開く)
    @State private var likersSheetItem: FeedItem?
    /// このビュー内で削除した投稿 (親の配列は let なのでローカルで除外)
    @State private var deletedPostIds: Set<UUID> = []

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var visibleItems: [FeedItem] {
        items.filter { !($0.kind == .post && deletedPostIds.contains($0.itemId)) }
    }

    var body: some View {
        if let onRefresh {
            scrollBody
                // 指が画面に触れているかを見る (下の refreshable が「離すまで待つ」ために使う)。
                // simultaneousGesture なのでスクロールもタップも従来どおり動く
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in if !isFingerDown { isFingerDown = true } }
                        .onEnded { _ in isFingerDown = false }
                )
                .refreshable {
                    // ① 指を離すまで待つ (2026-07-31 実機FB)。
                    // SwiftUI の refreshable は「引き下げ量が閾値を越えた瞬間」に発火するため、
                    // 何もしないと指を下ろしたまま内容が入れ替わってしまう。離してから取りに行く。
                    // 保険で最大2秒 (ジェスチャが中断されて onEnded が来ない場合に固まらないよう)
                    let waitStarted = Date()
                    while isFingerDown, Date().timeIntervalSince(waitStarted) < 2.0 {
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }

                    let fetchStarted = Date()
                    // ② 取得はビューの寿命から切り離した非構造化 Task で行う。
                    // SwiftUI は refreshable のアクションを「そのビューに紐づくタスク」として
                    // 実行するため、取得中にビューが再構成されるとタスクごとキャンセルされ、
                    // URLSession のリクエストも道連れで中断される (実機で -999 を確認)。
                    // Task { } は囲みのキャンセルを継承しないので取得は必ず走り切る
                    await Task { await onRefresh() }.value

                    // ③ 取得が速すぎるとくるくるが瞬きのように消えるので、最低 0.5 秒は見せる
                    let elapsed = Date().timeIntervalSince(fetchStarted)
                    if elapsed < 0.5 {
                        try? await Task.sleep(nanoseconds: UInt64((0.5 - elapsed) * 1_000_000_000))
                    }
                }
        } else {
            scrollBody
        }
    }

    private var rawScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // カードレス構成のため投稿間はゆったり空ける (境界線が無いぶん余白が区切りになる)
            LazyVStack(spacing: 28) {
                if topContentInset > 0 {
                    Color.clear.frame(height: topContentInset)
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    card(item: item)
                        .id(item.id)
                        // 2026-07-22 実機FB改: flagged の上端小バナーは (1) 著者ヘッダーに被る
                        // (2) 文字部分のタップが下のアバターへ素通りする (3) 制限中と分かりにくい、
                        // で却下 → rejected/flagged とも同じ「暗幕+中央表示」に統一。
                        // overlayPreferenceValue なのはゴミ箱を「画像の右上」(FeedMediaBoundsKey) に
                        // 合わせるため (2026-07-25 実機FB)
                        .overlayPreferenceValue(FeedMediaBoundsKey.self) { mediaAnchor in
                            if canDeletePosts, item.kind == .post,
                               rejectedPostIds.contains(item.itemId) || flaggedPostIds.contains(item.itemId) {
                                GeometryReader { geo in
                                    moderationStateOverlay(
                                        postId: item.itemId,
                                        isRejected: rejectedPostIds.contains(item.itemId),
                                        mediaFrame: mediaAnchor.map { geo[$0] }
                                    )
                                }
                            }
                        }
                        .onAppear {
                            if recordsViews, item.kind == .post {
                                extrasService.recordPostView(postId: item.itemId)
                            }
                        }
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            onItemVisibilityChanged?(item, isVisible)
                        }

                    // 広告枠: 10件に1件 (NativeAdService.adInterval)。在庫が無ければ FeedAdSlot が
                    // 空を返し枠ごと消える (空白は残らない)。スロット番号は「何番目の枠か」で安定させ、
                    // スクロール往復で同じ位置に同じ広告を出す
                    if showsAds, (index + 1) % NativeAdService.adInterval == 0 {
                        FeedAdSlot(slot: (index + 1) / NativeAdService.adInterval - 1)
                    }
                }
            }
            // カードは画面幅いっぱい (横余白なし)。角丸だけでカードを表現する (ユーザー指定 2026-07-10)
            .padding(.vertical, 16)
            .scrollTargetLayout()
        }
    }

    /// スクロール位置の束縛は「N件目から開く」用途 (グリッド/通知からの遷移) の時だけ行う。
    ///
    /// 2026-07-31 実機バグの真因 (ユーザー複数回報告「引き下げ更新しても内容が変わらない」):
    /// scrollPosition(id:) を束縛すると、SwiftUI はスクロールのたびに「今いちばん上に見えて
    /// いるカードの ID」をバインディングへ書き戻し、データが差し替わってもその ID のカードを
    /// 探して画面上端に留め続ける。つまり並び順は新しくなっているのに、先頭には常に同じ
    /// カードが座り「1件も変わっていない」ように見えていた。
    /// (アプリ再起動ではバインディングが nil から始まるので新しい並びが見える = 症状と一致)
    ///
    /// ホームフィード (startItemKey == nil) では位置を覚える必要がないので、束縛ごと外す。
    @ViewBuilder
    private var positionedScroll: some View {
        if startItemKey == nil {
            rawScroll
        } else {
            rawScroll.scrollPosition(id: $scrollTargetKey, anchor: .top)
        }
    }

    private var scrollBody: some View {
        positionedScroll
        .overlay {
            // 空状態 (例: いいね一覧の最後の1件を解除した、投稿削除で0件になった等)。
            // ローディング判定は呼び出し元 (MixedFeedView 等) が持つため、ここは単純に
            // 「表示対象が0件」で判定する
            if visibleItems.isEmpty {
                emptyStateView
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .toolbarBackground(AppColors.background, for: .navigationBar)
        // 実機FB#6 緩和策 (2026-07-22、未検証): 親 (MyProfileView 等) はヒーロー用に
        // toolbarBackground(.hidden) を使っており、push 先が可視性を明示しないとバー周りの
        // レイアウトが親の透過状態を引きずる疑いがある。スタイル指定に加えて可視を明示する
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarRole(.editor)
        .onAppear {
            // 実機FB#6 緩和策 (2026-07-22、未検証): 開始位置が先頭アイテムの場合はアンカー設定を
            // スキップする。リストは元々先頭表示なのでスクロールは本来不要だが、scrollPosition の
            // 初期アンカーがセーフエリア確定前に適用されると「先頭カードのヘッダーがナビバーの
            // 上に食い込み、引っ張っても離すと戻る」症状 (#6 スクショの状況 = 通知/グリッド先頭
            // タップの1件表示) を作り得る。先頭以外へのジャンプ (グリッド2件目以降) は従来どおり
            if scrollTargetKey == nil, let startItemKey,
               startItemKey != visibleItems.first?.id {
                scrollTargetKey = startItemKey
            }
        }
        .task {
            // 広告はホームフィード表示が最初のトリガー (起動シーケンスには混ぜない)
            if showsAds {
                // ATT の可否を先に確定させてからロードする。順序が逆だと初回ぶんが
                // 非パーソナライズで確定してしまう。AdTrackingConsent.isEnabled == false
                // (既定) なら即 return するので、従来と同じタイミングで preload が走る
                await AdTrackingConsent.shared.requestIfNeeded()
                NativeAdService.shared.preloadIfNeeded()
            }
            await extrasService.loadExtras(for: items)
        }
        // 制限中 (rejected/flagged) の自分の投稿に審査中の申し立てがあるかを一括取得し、
        // オーバーレイのピルを「異議申し立て中」に切り替える (2026-07-23 実機FB)。
        // id: に union を渡すことでフィード再読み込みで制限対象が変わった時だけ再取得する
        .task(id: rejectedPostIds.union(flaggedPostIds)) {
            guard canDeletePosts else { return }
            let moderatedIds = rejectedPostIds.union(flaggedPostIds)
            guard !moderatedIds.isEmpty else { return }
            appealPendingPostIds = await AppealService.shared.fetchPendingAppealPostIds(for: moderatedIds)
        }
        // フィード再読み込み (refresh 等) で items が変わったら extras も追従。
        // items ([FeedItem]) 全体の Equatable 比較は更新のたびにフルウォークになるため、
        // 変化検知は軽量な id 配列だけで行う (中身の並び/件数が変われば id 配列も変わる)
        .onChange(of: items.map(\.id)) { _, _ in
            // items の中身が実際に変わった (= pull-to-refresh 等の真の再読み込み) 場合は
            // TTL キャッシュを無視して確実に最新のいいね/コメント数を取り直す
            Task { await extrasService.loadExtras(for: items, force: true) }
        }
        .navigationDestination(isPresented: $showOfficialProfile) {
            OfficialProfileView()
        }
        .navigationDestination(isPresented: $showTopicFeed) {
            if let author = selectedTopicAuthor {
                AuthorQuoteFeedView(
                    author: author,
                    quotes: selectedTopicQuotes,
                    startIndex: selectedTopicStartIndex
                )
            }
        }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = selectedUserId {
                UserProfileView(userId: uid, initialDisplayName: selectedUserName)
            }
        }
        .navigationDestination(isPresented: $showTagFeed) {
            if let tag = selectedTag {
                TagFeedView(tag: tag, lang: lang, showOriginal: showOriginal)
            }
        }
        .navigationDestination(item: $commentPageRequest) { request in
            CommentPageView(request: request)
        }
        // コメントページを閉じて戻ってきたら、そのアイテムの extras (コメントプレビュー) を
        // TTL 無視で再取得対象にする。自分が投稿したコメントが最大60秒プレビューに
        // 出ないという regression を防ぐ (F6)
        .onChange(of: commentPageRequest) { _, newValue in
            if newValue == nil, let key = lastCommentItemKey {
                extrasService.invalidate(key: key)
                lastCommentItemKey = nil
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheetView(target: target, onSubmitted: { showReportThanks = true })
        }
        .sheet(item: $appealTarget) { target in
            // 送信成功したらフィードを再読み込みせずともピルを即「異議申し立て中」へ
            AppealSheetView(target: target, onFiled: {
                if case .post(let pid) = target {
                    appealPendingPostIds.insert(pid)
                }
            })
        }
        .sheet(item: $likersSheetItem) { item in
            LikersSheet(item: item)
        }
        .alert(L.moderationBlockConfirmTitle(lang), isPresented: $showBlockConfirm) {
            Button(L.moderationReportCancel(lang), role: .cancel) { }
            Button(L.moderationBlock(lang), role: .destructive) {
                if let uid = blockCandidateUserId {
                    Task {
                        await blockService.block(userId: uid)
                        onBlocked?()
                    }
                }
            }
        } message: {
            Text(L.moderationBlockConfirmMessage(lang))
        }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) { }
        }
        .alert(
            L.feedMenuDownloadFailedTitle(lang),
            isPresented: Binding(
                get: { saveAlert != nil },
                set: { if !$0 { saveAlert = nil } }
            )
        ) {
            if saveAlert?.isPermissionError == true {
                Button(L.feedMenuOpenSettings(lang)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveAlert?.message ?? "")
        }
        // 2026-07-22 実機FB: confirmationDialog (画面端のシート) は押したボタンから遠く「吹き出し」に
        // 見えて違和感 → コメント削除と同じ画面中央の標準 alert に統一
        .alert(
            L.postsDeleteConfirmTitle(lang),
            isPresented: Binding(
                get: { deleteCandidatePostId != nil },
                set: { if !$0 { deleteCandidatePostId = nil } }
            )
        ) {
            Button(L.postsComposerCancel(lang), role: .cancel) {
                deleteCandidatePostId = nil
            }
            Button(L.postsDeleteAction(lang), role: .destructive) {
                if let pid = deleteCandidatePostId {
                    deletedPostIds.insert(pid)
                    Task { @MainActor in
                        let success = await postService.deletePost(pid)
                        if success {
                            if visibleItems.isEmpty { dismiss() }
                        } else {
                            // 失敗したのでカードを復活させる (dismiss は成功時のみ)
                            deletedPostIds.remove(pid)
                        }
                    }
                }
                deleteCandidatePostId = nil
            }
        } message: {
            Text(L.postsDeleteConfirmMessage(lang))
        }
        .overlay(alignment: .bottom) {
            if let toast = saveToastMessage {
                Text(toast)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.black.opacity(0.8)))
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Card

    private func card(item: FeedItem) -> some View {
        FeedListCard(
            item: item,
            lang: lang,
            showOriginal: showOriginal,
            isLiked: isLikedItem(item),
            isFollowing: isFollowingAuthor(item),
            extras: extrasService.extras(for: item),
            onLikeTap: { handleLikeTap(item: item) },
            onFollowTap: { handleFollowTap(item: item) },
            onAuthorTap: { handleAuthorTap(item: item) },
            onTagTap: { tag in
                if let onTagTapOverride {
                    onTagTapOverride(tag)
                } else {
                    selectedTag = tag
                    showTagFeed = true
                }
            },
            onTopicTap: disableTopicTap ? nil : { handleTopicTap(item: item) },
            menuContent: moderationMenu(for: item),
            onCommentTap: {
                lastCommentItemKey = item.id
                commentPageRequest = CommentPageRequest(item: item)
            },
            onLikersTap: {
                likersSheetItem = item
            }
        )
    }

    // MARK: - Handlers (MixedFeedView と同じ流儀)

    private func isLikedItem(_ item: FeedItem) -> Bool {
        switch item.kind {
        case .quote: return likeService.isLiked(quoteId: item.itemId)
        case .post:  return likeService.isLikedPost(postId: item.itemId)
        }
    }

    private func isFollowingAuthor(_ item: FeedItem) -> Bool {
        switch item.kind {
        case .quote:
            return followService.isFollowing(authorId: OnePercentAccount.authorId)
        case .post:
            guard let authorId = item.authorId else { return false }
            return followService.isFollowingUser(userId: authorId)
        }
    }

    private func handleLikeTap(item: FeedItem) {
        let willLike = !isLikedItem(item)
        Task {
            switch item.kind {
            case .quote: await likeService.toggleLike(quoteId: item.itemId)
            case .post:  await likeService.togglePostLike(postId: item.itemId)
            }
        }
        onLikeToggled?(item, willLike)
        // 自分のいいねが likers スタックに即座に反映されるよう、この項目の TTL キャッシュだけ
        // 無効化する (60秒 TTL のまま remount すると自分のいいねが消えて見える regression 対策、F6)
        extrasService.invalidate(key: item.id)
    }

    private func handleFollowTap(item: FeedItem) {
        Task {
            switch item.kind {
            case .quote:
                await followService.toggleFollow(authorId: OnePercentAccount.authorId)
            case .post:
                guard let authorId = item.authorId else { return }
                await followService.toggleUserFollow(userId: authorId)
            }
        }
    }

    private func handleAuthorTap(item: FeedItem) {
        switch item.kind {
        case .quote:
            showOfficialProfile = true
        case .post:
            guard let authorId = item.authorId else { return }
            selectedUserName = item.authorName
            selectedUserId   = authorId
            showUserProfile  = true
        }
    }

    /// 「— 著者名」タップ → 著者の名言一式を取得し著者トピックフィードへ
    private func handleTopicTap(item: FeedItem) {
        guard item.kind == .quote, let authorId = item.authorId else { return }
        guard let author = QuoteService.shared.authors.first(where: { $0.id == authorId }) else { return }
        Task {
            do {
                let authorQuotes = try await QuoteService.shared.fetchQuotesByAuthor(authorId: authorId)
                await MainActor.run {
                    selectedTopicAuthor = author
                    selectedTopicQuotes = authorQuotes
                    selectedTopicStartIndex = authorQuotes.firstIndex { $0.id == item.itemId } ?? 0
                    showTopicFeed = true
                }
            } catch {
                print("⚠️ Failed to load author quotes for topic feed: \(error)")
            }
        }
    }

    // MARK: - Menu

    /// 共通: 共有 / ダウンロード。他人 UGC: 通報 + ブロック。公式名言: 通報。自分 UGC (canDeletePosts): 削除
    private func moderationMenu(for item: FeedItem) -> AnyView {
        let shareText = L.feedMenuShareText(item, lang, showOriginal)
        let isMine: Bool = {
            guard item.kind == .post, let authorId = item.authorId, let me = auth.userId else { return false }
            return me == authorId
        }()
        let isOtherUGC: Bool = item.kind == .post && !isMine

        return AnyView(
            Group {
                ShareLink(item: shareText) {
                    Label(L.feedMenuShare(lang), systemImage: "square.and.arrow.up")
                }
                Button {
                    handleSaveImage(item: item)
                } label: {
                    Label(L.feedMenuDownload(lang), systemImage: "arrow.down.circle")
                }
                if isOtherUGC, let authorId = item.authorId {
                    let postId = item.itemId
                    Button {
                        reportTarget = .post(postId)
                    } label: {
                        Label(L.moderationReport(lang), systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        blockCandidateUserId = authorId
                        showBlockConfirm = true
                    } label: {
                        Label(L.moderationBlock(lang), systemImage: "hand.raised")
                    }
                }
                if item.kind == .quote {
                    Button {
                        reportTarget = .quote(item.itemId)
                    } label: {
                        Label(L.moderationReport(lang), systemImage: "flag")
                    }
                }
                if canDeletePosts, isMine {
                    Button(role: .destructive) {
                        deleteCandidatePostId = item.itemId
                    } label: {
                        Label(L.postsDelete(lang), systemImage: "trash")
                    }
                }
            }
        )
    }

    // MARK: - Save Image

    private func handleSaveImage(item: FeedItem) {
        Task {
            do {
                try await ImageExportService.shared.saveQuoteImage(
                    item: item,
                    lang: lang,
                    showOriginal: showOriginal
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    saveToastMessage = L.feedMenuDownloadSuccess(lang)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        saveToastMessage = nil
                    }
                }
            } catch ImageExportError.permissionDenied {
                saveAlert = SaveImageAlert(
                    message: L.feedMenuDownloadPermissionMessage(lang),
                    isPermissionError: true
                )
            } catch {
                saveAlert = SaveImageAlert(
                    message: L.feedMenuDownloadGenericMessage(lang),
                    isPermissionError: false
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.white.opacity(0.35))
            Text(L.feedEmptyGeneric(lang))
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - AI Moderation Overlay (rejected/flagged 共通、自分の投稿のみ)

    /// 制限中投稿の全面オーバーレイ (2026-07-22 実機FB改で rejected/flagged を統一)。
    /// 暗幕はタップを通さない = 制限中投稿への いいね/コメント等の操作をまとめて封じる (ユーザー指定
    /// 「バグの原因になるなら消して大丈夫」)。そのぶん下の「…」メニューに到達できなくなるため、
    /// 削除はオーバーレイ内のボタンで代替する。判定理由の全文と異議申し立ては
    /// 「詳細・異議申し立て」→ AppealSheetView に集約 (通知プレビューの2行では全文が読めないため)。
    private func moderationStateOverlay(postId: UUID, isRejected: Bool, mediaFrame: CGRect? = nil) -> some View {
        // 審査中の申し立てがある投稿はピル/CTA を申し立て済み表示に切り替える (2026-07-23 実機FB)
        let isAppealPending = appealPendingPostIds.contains(postId)
        return ZStack {
            // hit-testable のまま置く = 下のカード操作 (いいね/コメント/アバター遷移) を遮断する
            Color.black.opacity(0.6)

            VStack(spacing: 12) {
                Image(systemName: isAppealPending
                      ? "clock.fill"
                      : (isRejected ? "eye.slash.fill" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                Text(isAppealPending
                     ? (lang == .japanese ? "異議申し立て中" : "Appeal under review")  // 文言はユーザー添削待ち
                     : isRejected
                     ? L.postsModerationRejectedBadge(lang)
                     : (lang == .japanese ? "表示が制限されています" : "Visibility limited"))  // 文言はユーザー添削待ち
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))

                Button {
                    appealTarget = .post(postId)
                } label: {
                    Text(isAppealPending
                         ? (lang == .japanese ? "詳細を見る" : "View details")  // 文言はユーザー添削待ち
                         : (lang == .japanese ? "詳細・異議申し立て" : "Details & appeal"))  // 文言はユーザー添削待ち
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.background)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(AppColors.textPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        // 2026-07-22 実機FB: 中央のピル過多で見にくい → 削除は右上のゴミ箱アイコンに分離
        // (ぼかし付きの半透明円背景、ユーザー指定)。
        // 2026-07-25 実機FB: 位置は「カードの右上 (ヘッダー横)」でなく「画像の右上」に固定
        .overlay {
            if let mediaFrame {
                trashButton(for: postId)
                    .position(x: mediaFrame.maxX - 31, y: mediaFrame.minY + 31)  // 画像の角から余白12pt (ボタン38pt の半径19)
            } else {
                // 枠が取れなかった場合のフォールバック (従来のカード右上)
                trashButton(for: postId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func trashButton(for postId: UUID) -> some View {
        Button {
            deleteCandidatePostId = postId
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }
}
