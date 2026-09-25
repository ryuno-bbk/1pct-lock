//
//  CommentPageView.swift
//  AppBlocker
//
//  BeReal 風コメントフルページ (旧 CommentsSheet を置き換え、2026-07-10 確定仕様)。
//  push 遷移の完全別ページ:
//    - 上部: 投稿画像の固定ヘッダー (コラプシブル)。開いた直後は縮小状態で、
//      コメントをどれだけスクロールしても固定。リスト最上部でさらに引き下げると
//      画像がほぼ全画面まで拡大され、タップ/チェブロンで縮小に戻る
//    - 中段: 親コメント + 返信 (1 階層) のスクロールリスト
//    - 下段: CommentInputBar (独立 View、タイピング再描画を局所化)
//  UGC 投稿 (post) と公式名言 (quote) の両対応 (CommentTarget)。
//

import SwiftUI
import UIKit

/// コメントページへの push リクエスト (navigationDestination(item:) 用)
struct CommentPageRequest: Identifiable, Hashable {
    /// 画像ヘッダー用。nil なら画像なしのプレーン表示 (通知からの遷移など)
    let item: FeedItem?
    let target: CommentTarget
    /// target が .post の時のみ意味を持つ (投稿者の user_id、全削除メニュー表示判定に使用)
    let postOwnerId: UUID?

    var id: UUID { target.id }

    /// FeedItem から標準的なリクエストを構築
    init(item: FeedItem) {
        self.item = item
        switch item.kind {
        case .post:
            self.target = .post(item.itemId)
            self.postOwnerId = item.authorId
        case .quote:
            self.target = .quote(item.itemId)
            self.postOwnerId = nil
        }
    }

    init(item: FeedItem?, target: CommentTarget, postOwnerId: UUID?) {
        self.item = item
        self.target = target
        self.postOwnerId = postOwnerId
    }
}

struct CommentPageView: View {

    let request: CommentPageRequest

    @ObservedObject private var commentService = CommentService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    @State private var replyingTo: UserComment?
    @State private var requestFocus: Bool = false
    @State private var showDeleteAllConfirm: Bool = false
    @State private var deleteTargetComment: UserComment?
    @State private var selectedUserId: UUID?
    @State private var showUserProfile: Bool = false
    @State private var reportTarget: ReportSheetView.Target?
    @State private var showReportThanks = false
    /// 返信を展開中の親コメント id (TikTok 準拠でデフォルトは全部畳む、2026-07-25 実機FB)
    @State private var expandedParentIds: Set<UUID> = []

    private var target: CommentTarget { request.target }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var allComments: [UserComment] {
        commentService.comments(for: target)
    }

    private var topLevelComments: [UserComment] {
        allComments.filter { $0.parentCommentId == nil }
    }

    private func replies(to parentId: UUID) -> [UserComment] {
        allComments.filter { $0.parentCommentId == parentId }
    }

    private var isPostOwner: Bool {
        guard let me = auth.userId, let owner = request.postOwnerId else { return false }
        return me == owner
    }

    // BeReal 準拠 (2026-07-11 実機FB 6回目で挙動確定):
    // ヘッダー画像は「横幅いっぱいの実寸 (width×5/4)」でスクロール内に常に存在し、
    // 開いた時点で上 1/3 だけ見える位置までスクロール済みにしておく。
    // 引き下げれば下げたぶんだけ画像が現れて手を離してもそこで止まり (バネ戻りなし)、
    // 実寸まで達したらコンテンツ最上端なので自然に止まる。ただの素のスクロール。
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let headerFullHeight = width * 5.0 / 4.0
            // 初期に見せる高さ = 画面全高 (ステータスバー込み) の 1/3 強
            let baseVisible = (geo.size.height + geo.safeAreaInsets.top) * 0.36
            let initialOffset = max(0, headerFullHeight - baseVisible)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if let item = request.item {
                            // 実寸 (width×5/4) のヘッダー。コンテンツ最上端でさらに引き下げた時だけ、
                            // プロフィールヒーローと同じく上端ピン留めのままズームする (minY > 0 の間のみ)
                            Color.clear
                                .frame(height: headerFullHeight)
                                .overlay {
                                    GeometryReader { g in
                                        let minY = g.frame(in: .named("commentPageScroll")).minY
                                        let stretch = max(0, minY)
                                        let zoom = 1 + stretch / headerFullHeight

                                        FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal)
                                            .frame(width: width, height: headerFullHeight)
                                            // 上端は画面にべったり付くので下 2 角だけ角丸
                                            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                                                topLeading: 0, bottomLeading: 24, bottomTrailing: 24, topTrailing: 0
                                            )))
                                            .scaleEffect(zoom, anchor: .top)
                                            .offset(y: -stretch)
                                    }
                                }
                                // 初期スクロール位置用の目印 (ここが画面上端に来ると 1/3 だけ見える)
                                .overlay(alignment: .topLeading) {
                                    Color.clear
                                        .frame(width: 1, height: 1)
                                        .offset(y: initialOffset)
                                        .id("commentInitialAnchor")
                                }
                        }

                        // コメント部は「viewport − 初期ヘッダー」以上の高さを確保する。
                        // コメントが少なくても初期位置 (1/3 表示) が成立し、スクロール範囲が
                        // ちょうど「1/3 ⇔ 実寸」の往復になる。
                        // プレーンモード (item == nil、通知からの名言コメント等) はヒーロー画像が
                        // 存在しないため 36% ぶんの見込み高さを差し引く必要がない。差し引いたままだと
                        // ヘッダーの無い分だけ上部にスクロール可能な空白 (dead scroll region) ができてしまう
                        VStack(spacing: 0) {
                            commentsSectionHeader
                            commentsContent
                            Spacer(minLength: 0)
                        }
                        .frame(
                            minHeight: request.item != nil
                                ? geo.size.height + geo.safeAreaInsets.top - baseVisible
                                : geo.size.height,
                            alignment: .top
                        )
                    }
                }
                .coordinateSpace(name: "commentPageScroll")
                .scrollDismissesKeyboard(.interactively)
                // 2026-07-25 実機FB: 入力欄の外 (コメント一覧やヒーロー画像) をタップしたら
                // キーボードを閉じる。Button が乗っている場所は Button が優先されるので、
                // ここに届くのは「関係ない場所」のタップだけ
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                }
                // ヒーロー画像がある時だけ画面上端 (ステータスバー下) までべったり付ける。
                // プレーンモードは safe area を無視しないので、コメント見出しがステータスバー/
                // 戻るシェブロンの下に潜り込まない (通常のナビゲーションバー下からコンテンツが始まる)
                .ignoresSafeArea(edges: request.item != nil ? .top : [])
                .onAppear {
                    guard request.item != nil else { return }
                    // レイアウト確定後に初期位置 (画像 1/3 見え) までジャンプ (アニメなし)
                    DispatchQueue.main.async {
                        proxy.scrollTo("commentInitialAnchor", anchor: .top)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // BeReal 風: ネイティブな半透明カプセルの入力欄を下端に固定
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommentInputBar(
                target: target,
                lang: lang,
                replyingTo: $replyingTo,
                requestFocus: $requestFocus
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // コメントは完全別ページなのでタブバー (フィード/タイマー/マイページ) は隠す (実機FB 2026-07-11)
        .toolbar(.hidden, for: .tabBar)
        .toolbarRole(.editor)
        .toolbar {
            // 投稿者のみ「全削除」メニュー
            if isPostOwner && !allComments.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label(L.commentsDeleteAll(lang), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .task(id: target) {
            // 🔴 「キャッシュが空のときだけ取る」にしてはいけない。
            //    CommentService はシングルトンでキャッシュがアプリ生存期間ずっと残るため、
            //    一度開いた投稿は二度と通信せず、新しいコメントが永久に出なくなる
            //    (カード下部のプレビューは別RPC fetch_feed_extras で更新されるので、
            //     「プレビューには出るのに開くと無い」というズレになる。2026-08-28 実機報告)。
            //    スピナーは allComments.isEmpty のときだけ出るので、キャッシュがある間は
            //    古い内容を表示したまま裏で取り直す形になりちらつかない
            await commentService.loadComments(target: target)
        }
        .alert(L.commentsDeleteAllConfirmTitle(lang), isPresented: $showDeleteAllConfirm) {
            Button(L.postsComposerCancel(lang), role: .cancel) {}
            Button(L.commentsDelete(lang), role: .destructive) {
                if case .post(let postId) = target {
                    Task { _ = await commentService.deleteAllComments(postId: postId) }
                }
            }
        } message: {
            Text(L.commentsDeleteAllConfirmMessage(lang))
        }
        // 2026-07-22 実機FB: confirmationDialog (画面端のアクションシート) は押した削除ボタンから
        // 遠い位置に出て違和感がある → 画面中央の標準 alert に変更 (全削除の既存 alert とも揃う)
        .alert(
            L.commentsDeleteConfirmTitle(lang),
            isPresented: Binding(
                get: { deleteTargetComment != nil },
                set: { if !$0 { deleteTargetComment = nil } }
            )
        ) {
            Button(L.postsComposerCancel(lang), role: .cancel) {
                deleteTargetComment = nil
            }
            Button(L.commentsDelete(lang), role: .destructive) {
                if let comment = deleteTargetComment {
                    let cid = comment.id
                    let commentTarget = target
                    Task { await commentService.deleteComment(cid, target: commentTarget) }
                }
                deleteTargetComment = nil
            }
        } message: {
            Text(L.commentsDeleteConfirmMessage(lang))
        }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = selectedUserId {
                UserProfileView(userId: uid, initialDisplayName: nil)
            }
        }
        .sheet(item: $reportTarget) { ReportSheetView(target: $0, onSubmitted: { showReportThanks = true }) }
        .alert(L.moderationReportThanks(lang), isPresented: $showReportThanks) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Comments Section (単一スクロール内)

    private var commentsSectionHeader: some View {
        HStack(spacing: 8) {
            Text(L.commentsTitle(lang))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text("\(allComments.count)")
                .font(.system(size: 16))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var commentsContent: some View {
        if commentService.isLoading(target: target) && allComments.isEmpty {
            loadingView
        } else if allComments.isEmpty {
            emptyView
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(topLevelComments) { parent in
                    CommentRow(
                        comment: parent,
                        indent: 0,
                        canDelete: canDelete(parent),
                        canReport: canReport(parent),
                        lang: lang,
                        ownerAvatarUrl: request.item?.authorAvatarUrl,
                        onLike: { Task { await commentService.toggleLike(commentId: parent.id, target: target, viewerIsPostOwner: isPostOwner) } },
                        onReply: { startReply(to: parent) },
                        onAvatarTap: { openUserProfile(userId: parent.authorUserId) },
                        onDelete: { deleteTargetComment = parent },
                        onReport: { reportTarget = .comment(parent.id) }
                    )

                    // TikTok 準拠 (2026-07-25 実機FB): 返信はデフォルト全部畳み、
                    // 「── 返信N件を表示 ∨」で展開 / 展開後は「── 返信を隠す ∧」
                    let replyList = replies(to: parent.id)
                    if !replyList.isEmpty {
                        if expandedParentIds.contains(parent.id) {
                            ForEach(replyList) { reply in
                                CommentRow(
                                    comment: reply,
                                    indent: 1,
                                    canDelete: canDelete(reply),
                                    canReport: canReport(reply),
                                    lang: lang,
                                    ownerAvatarUrl: request.item?.authorAvatarUrl,
                                    onLike: { Task { await commentService.toggleLike(commentId: reply.id, target: target, viewerIsPostOwner: isPostOwner) } },
                                    onReply: { startReply(to: parent) },  // 子への返信も親に紐づける (1 階層維持)
                                    onAvatarTap: { openUserProfile(userId: reply.authorUserId) },
                                    onDelete: { deleteTargetComment = reply },
                                    onReport: { reportTarget = .comment(reply.id) }
                                )
                            }
                        }
                        repliesToggleRow(parentId: parent.id, count: replyList.count)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func canDelete(_ comment: UserComment) -> Bool {
        guard let me = auth.userId else { return false }
        if comment.authorUserId == me { return true }
        if let owner = request.postOwnerId, owner == me { return true }
        return false
    }

    /// 自分のコメントは通報できない (auth.userId が nil = 未サインインも不可)
    private func canReport(_ comment: UserComment) -> Bool {
        guard let me = auth.userId else { return false }
        return comment.authorUserId != me
    }

    private func startReply(to parent: UserComment) {
        replyingTo = parent
        requestFocus = true  // CommentInputBar 側でフォーカスを取って flag をリセット
        // 返信先の既存返信は畳まれていても展開しておく (送った返信が畳みの中に消えないように)
        expandedParentIds.insert(parent.id)
    }

    /// 「── 返信N件を表示 ∨」/「── 返信を隠す ∧」(TikTok 準拠、親の本文開始位置に揃える)
    private func repliesToggleRow(parentId: UUID, count: Int) -> some View {
        let isExpanded = expandedParentIds.contains(parentId)
        return Button {
            // アニメーション強制無効 (2026-07-25 実機FB: 行が滑って移動する経過が見えるのが不要。
            // withAnimation を外すだけでは暗黙アニメーションが残ったため Transaction で殺す)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if isExpanded {
                    expandedParentIds.remove(parentId)
                } else {
                    expandedParentIds.insert(parentId)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(AppColors.textTertiary.opacity(0.5))
                    .frame(width: 26, height: 1)
                Text(isExpanded
                     ? (lang == .japanese ? "返信を隠す" : "Hide replies")  // 文言はユーザー添削待ち
                     : (lang == .japanese ? "返信\(count)件を表示" : "View \(count) replies"))  // 文言はユーザー添削待ち
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textTertiary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.leading, 56)  // 親のアバター(32)+間隔(10)+左余白(14) = 本文の開始位置
            .padding(.trailing, 14)
            .padding(.top, 0)
            .padding(.bottom, 6)  // 返信ボタンとの距離を詰める (2026-07-25 実機FB)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openUserProfile(userId: UUID) {
        selectedUserId = userId
        showUserProfile = true
    }

    // MARK: - Empty / Loading

    private var emptyView: some View {
        VStack(spacing: 12) {
            // 2026-07-25 実機FB: クオーテーションマークは意味不明 → コメントの吹き出しアイコンに
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 34, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(L.commentsNone(lang))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary)
            Text(L.commentsNoneSubtitle(lang))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var loadingView: some View {
        ProgressView()
            .tint(AppColors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }
}

// MARK: - CommentInputBar (独立 View)
//
// 重要: タイピング時の inputText 変化、focus 変化を CommentPageView 本体の
// body 再描画から完全に切り離すために独立 View にしている。
// これがないと 1 文字ごとに header / commentList / AvatarImage 群まで再評価されて
// 実機でカクつく。

private struct CommentInputBar: View {

    let target: CommentTarget
    let lang: AppLanguage
    @Binding var replyingTo: UserComment?
    /// 親から focus 要求が来るたびに true にセットされる。受け取った側で focus 後に false に戻す
    @Binding var requestFocus: Bool

    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var commentService = CommentService.shared

    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    /// 送信失敗時のアラート文言 (046 レート制限/汎用。nil = 非表示)
    @State private var sendError: String?
    @FocusState private var focused: Bool

    // BeReal 風: バー自体は背景を持たず浮かせ、半透明マテリアルのカプセル入力欄 +
    // 白丸の送信ボタンだけを置く (2026-07-10 実機FB)
    var body: some View {
        VStack(spacing: 6) {
            if let target = replyingTo {
                replyHeader(target: target)
            }

            HStack(spacing: 10) {
                if auth.userId == nil {
                    Text(L.commentsLoginRequired(lang))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.vertical, 12)
                    Spacer()
                } else {
                    // BeReal のガラス質感: ultraThinMaterial + 薄い白ストローク +
                    // 明るめプレースホルダー。下をコメントが通ると透けてぼける
                    TextField(
                        "",
                        text: $inputText,
                        prompt: Text(placeholderText).foregroundColor(.white.opacity(0.55))
                    )
                    .focused($focused)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .environment(\.colorScheme, .dark)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await submit() }
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.white))
                            .contentShape(Circle())
                    }
                    .opacity(canSubmit ? 1 : 0.45)
                    .animation(.easeOut(duration: 0.15), value: canSubmit)
                    .disabled(!canSubmit || isSending)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onChange(of: requestFocus) { _, newValue in
            if newValue {
                focused = true
                requestFocus = false
            }
        }
        // 削除/エラー系モーダルは中央 .alert 統一 (2026-07-22 設計ルール)
        .alert(
            lang == .japanese ? "コメントできません" : "Can't comment",  // 文言はユーザー添削待ち
            isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
    }

    private var canSubmit: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 500 && !isSending
    }

    private var placeholderText: String {
        if let r = replyingTo, let name = r.authorName, !name.isEmpty {
            return L.commentsReplyPlaceholder(name, lang)
        }
        return L.commentsPlaceholder(lang)
    }

    private func replyHeader(target: UserComment) -> some View {
        HStack {
            Text(L.commentsReplyingTo(target.authorName ?? "—", lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
    }

    private func submit() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }

        let parentId = replyingTo?.id
        let ok = await commentService.createComment(
            target: target,
            text: trimmed,
            parentCommentId: parentId
        )
        if ok {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            inputText = ""
            replyingTo = nil
            focused = false  // 送信成功時にキーボードを閉じる
        } else {
            // 失敗を無言で握りつぶさない (046 レート制限は専用文言、それ以外は汎用)
            sendError = commentService.lastCreateWasRateLimited
                ? (lang == .japanese
                    ? "本日のコメント上限に達しました。また明日コメントできます"
                    : "You've reached today's comment limit. You can comment again tomorrow")  // 文言はユーザー添削待ち
                : (lang == .japanese
                    ? "コメントを送信できませんでした。時間をおいて再試行してください"
                    : "Couldn't send your comment. Please try again later")  // 文言はユーザー添削待ち
        }
    }
}

// MARK: - CommentRow

private struct CommentRow: View {
    let comment: UserComment
    let indent: Int  // 0 = 親、1 = 返信
    let canDelete: Bool
    let canReport: Bool
    let lang: AppLanguage
    /// 「投稿者がいいねしました」バッジ用 (投稿の作者のアバター。名言コメント等では nil)
    let ownerAvatarUrl: String?
    let onLike: () -> Void
    let onReply: () -> Void
    let onAvatarTap: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    // TikTok 準拠レイアウト (2026-07-25 実機FB):
    //   1段目=名前+日付 / 2段目=本文 / 3段目=返信(左)+ハート・数字横並び(右下)。
    //   通報/削除はテキストボタンをやめて行の長押しメニューに格納 (TikTok と同じ構造。
    //   コメントUGCの通報手段を残すことで App Store 1.2 も満たす)
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onAvatarTap) {
                // 2026-07-25 実機FB: コメント欄のアイコンは一回り小さく
                AvatarImage(urlString: comment.authorAvatarUrl, size: indent == 0 ? 32 : 24)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(comment.authorName ?? "—")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)

                    Text(relativeTime(comment.createdAt))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                }

                // 本文が主役: サイズを一段格上げし、行間を確保
                // @メンションは YouTube と同じ青系 (アクセント=オフホワイトだと地の文に溶ける)
                if let replyTo = comment.replyToName, indent == 1 {
                    (Text("@\(replyTo) ").foregroundColor(Color(hex: "3EA6FF"))
                     + Text(comment.text).foregroundColor(AppColors.textPrimary))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(comment.text)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 3段目: 返信 (左) + 投稿者いいねバッジ + いいね (右端、ハートの右に数字 = TikTok 準拠)
                HStack(spacing: 12) {
                    Button(action: onReply) {
                        Text(L.commentsReply(lang))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.textTertiary)
                            .frame(minHeight: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // 投稿者がいいねしたバッジ (TikTok の作成者ハート。投稿者アバター+右下に赤ハート、
                    // ハートは背景色リングでアバターと分離)
                    if comment.isLikedByOwner {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarImage(urlString: ownerAvatarUrl, size: 18)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.red)
                                .padding(2)
                                .background(Circle().fill(AppColors.background))
                                .offset(x: 4, y: 4)
                        }
                        .padding(.trailing, 4)  // はみ出したハートぶんの余白
                    }

                    Spacer(minLength: 0)

                    Button(action: onLike) {
                        // ハートの位置を固定するため、数字側に固定幅スロットを常に確保する
                        // (いいねで 0→1、999→1K 等になってもハートが動かない。想定最大 = "999K")
                        HStack(spacing: 5) {
                            Image(systemName: comment.isLikedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 15))
                                .foregroundColor(comment.isLikedByMe ? .red : AppColors.textTertiary)
                                .likePopEffect(isLiked: comment.isLikedByMe, particleRadius: 14)
                            Text(comment.likeCount > 0 ? Self.compactCount(comment.likeCount) : "")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textTertiary)
                                .frame(width: 34, alignment: .leading)
                        }
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indent == 0 ? 14 : 56)
        .padding(.trailing, 14)
        .padding(.vertical, 6)  // 2026-07-25 実機FB: コメント同士の間隔を詰める
        .contentShape(Rectangle())
        // 長押しメニュー: 他人のコメント=通報 / 自分(or 投稿者権限)=削除
        .contextMenu {
            if canReport {
                Button {
                    onReport()
                } label: {
                    Label(L.moderationReport(lang), systemImage: "flag")
                }
            }
            if canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(L.commentsDelete(lang), systemImage: "trash")
                }
            }
        }
    }

    /// TikTok 式の省略表記 (999 → 999 / 1500 → 1K / 1_200_000 → 1M)。
    /// 固定幅スロット (34pt) に収まる長さを保証する
    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return L.timeJustNow(lang) }
        if seconds < 3600 { return L.timeMinutesAgo(Int(seconds / 60), lang) }
        if seconds < 86400 { return L.timeHoursAgo(Int(seconds / 3600), lang) }
        if seconds < 604800 { return L.timeDaysAgo(Int(seconds / 86400), lang) }
        return L.timeWeeksAgo(Int(seconds / 604800), lang)
    }
}
