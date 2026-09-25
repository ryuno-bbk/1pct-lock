//
//  NotificationListView.swift
//  AppBlocker
//
//  アプリ内通知一覧 (いいね / フォロー / コメント / 返信 / コメントいいね)
//  画面に入った時点で全件既読化、未読バッジを 0 にする
//

import SwiftUI

struct NotificationListView: View {

    @ObservedObject private var notifService = NotificationService.shared
    @ObservedObject private var auth = UserAuthService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var jumpToPost: PostJump?
    @State private var jumpToUserId: UUID?
    @State private var showUserProfile: Bool = false
    @State private var commentPageRequest: CommentPageRequest?
    /// システム通知 (モデレーション結果/異議申し立て結果) タップ時の異議申し立てシート対象
    @State private var appealSheetTarget: AppealTarget?
    /// 週次レポート通知をタップした時の遷移 (081)
    @State private var showWeeklyReport: Bool = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if notifService.isLoading && notifService.notifications.isEmpty {
                ProgressView()
                    .tint(AppColors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notifService.notifications.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifService.notifications) { notif in
                            NotificationRow(
                                notification: notif,
                                lang: lang,
                                onTap: { handleTap(notif) }
                            )
                            Divider().overlay(AppColors.cardBackground)
                        }
                    }
                }
                .refreshable {
                    await notifService.loadNotifications()
                }
            }
        }
        .navigationTitle(L.notificationsTitle(lang))
        .navigationBarTitleDisplayMode(.inline)
        // 実機FB#6系 緩和策 (2026-07-22、未検証): この画面は MyProfileView (ヒーロー用に
        // toolbarBackground(.hidden)) から push される。可視な不透明バーを明示しないと、
        // 「リスト先頭が上に食い込み、最新の通知が引っ張らないと見えない」症状が出た
        // (投稿直後トリガーの疑い)。バーを明示的に不透明可視化してレイアウトを確定させる
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // 実機FB#6: インセット崩壊の実測補正 (SafeAreaCollapseFix.swift 参照)
        .safeAreaCollapseFix()
        .task {
            await notifService.loadNotifications()
            await notifService.markAllRead()
            // 通知を見に来ている人に聞くのが一番自然な瞬間 (起動直後に唐突に聞くと
            // 拒否されやすく、一度拒否されるとアプリ内から復帰できない)。
            // 既に決定済みなら何も起きない
            await PushNotificationService.shared.requestAuthorizationIfNeeded()
        }
        // 2026-07-22 実機FB: fullScreenCover だと戻る手段が無く詰む (カバー内の新規 NavigationStack には
        // 戻るボタンが出ない)。この画面自体が MyProfileView の NavigationStack 内に push されているので、
        // 投稿ジャンプも push に統一する (戻るボタン+右スワイプバックが自然に付く)
        .navigationDestination(isPresented: $showWeeklyReport) {
            WeeklyReportView()
        }
        .navigationDestination(item: $jumpToPost) { jump in
            // ⚠️ 投稿者情報と canDelete を必ず渡すこと。省略すると MyPostsFeedView が
            //    「自分の投稿フィード」だと解釈して、他人の投稿に自分の名前/アバター/
            //    Pro バッジを出す (2026-08-28 ユーザー報告のバグ)
            MyPostsFeedView(
                posts: [jump.post],
                startIndex: 0,
                authorDisplayName: jump.authorName,
                authorAvatarUrl: jump.authorAvatarUrl,
                authorIsPro: jump.authorIsPro,
                canDelete: jump.isMine
            )
        }
        .navigationDestination(isPresented: $showUserProfile) {
            if let uid = jumpToUserId {
                UserProfileView(userId: uid, initialDisplayName: nil)
            }
        }
        .navigationDestination(item: $commentPageRequest) { request in
            CommentPageView(request: request)
        }
        .sheet(item: $appealSheetTarget) { target in
            AppealSheetView(target: target)
        }
    }

    // MARK: - Tap Handler

    private func handleTap(_ notif: UserNotification) {
        switch notif.kind {
        case .follow:
            jumpToUserId = notif.actorUserId
            showUserProfile = true
        case .like, .comment, .reply, .commentLike, .newPost:
            // 公式名言への返信通知 (target_quote_id あり) は最小実装としてコメントページを直接開く
            // (画像ヘッダー用の FeedItem は持っていないため nil = プレーン表示)
            if let quoteId = notif.targetQuoteId {
                commentPageRequest = CommentPageRequest(item: nil, target: .quote(quoteId), postOwnerId: nil)
                return
            }
            guard let postId = notif.targetPostId else { return }
            openPost(postId, from: notif)
        case .contentRejected, .contentFlagged, .appealApproved, .appealRejected:
            // コメントは rejected/flagged になるとコメント一覧 RPC から本人にも出なくなる仕様のため、
            // 通知から直接 AppealSheetView (状態表示 or 申し立て入力) を開く。
            // 投稿は RLS (037) で本人の rejected/flagged 投稿も取得可能なので既存の fetchPost 経路を使う
            if let commentId = notif.targetCommentId {
                appealSheetTarget = .comment(commentId)
                return
            }
            guard let postId = notif.targetPostId else { return }
            openPost(postId, from: notif)
        case .weeklyReport:
            // 081: タップでその週のレポートを開く (直近の完了週 = offset 1)
            showWeeklyReport = true
        case .appealUnsure:
            // 運営専用: 裁定は当面 SQL Editor で行う (管理コンソールはリリース後バックログ)。
            // 対象は他ユーザーの flagged コンテンツで RLS 上開けないため遷移しない
            break
        case .unknown:
            break
        }
    }

    /// post_id から投稿を取得してフィード全画面 (MyPostsFeedView) へジャンプする。
    ///
    /// 🔴 投稿者が誰かは post.userId で決まる。通知の actor とは限らない:
    ///   - new_post          → actor = 投稿者 (他人の投稿を見に行く)
    ///   - like/comment 等   → actor = 行動した人で、投稿は自分のもの
    /// actor と投稿者が一致するときだけ通知が持っている表示情報を使い、
    /// そうでなければ渡さない (MyPostsFeedView 側が自分の情報で埋める)
    private func openPost(_ postId: UUID, from notification: UserNotification) {
        Task {
            guard let post = await UserPostService.shared.fetchPost(id: postId) else { return }
            let authorIsActor = post.userId == notification.actorUserId
            jumpToPost = PostJump(
                post: post,
                authorName: authorIsActor ? notification.actorName : nil,
                authorAvatarUrl: authorIsActor ? notification.actorAvatarUrl : nil,
                authorIsPro: authorIsActor ? notification.isProActor : false,
                isMine: post.userId == UserAuthService.shared.userId
            )
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(L.notificationsNone(lang))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text(L.notificationsNoneSubtitle(lang))
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PostJump

/// 通知から投稿を開くときの遷移データ。投稿だけでなく「その投稿者は誰か」を
/// 一緒に運ぶ (投稿単体では表示名/アバター/Pro を持っていないため)
private struct PostJump: Identifiable, Hashable {
    let post: UserPost
    let authorName: String?
    let authorAvatarUrl: String?
    let authorIsPro: Bool
    /// 自分の投稿か。削除メニューの可否になる
    let isMine: Bool

    var id: UUID { post.id }
}

// MARK: - NotificationRow

private struct NotificationRow: View {
    let notification: UserNotification
    let lang: AppLanguage
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if notification.kind.isSystemKind {
                        // システム通知 (自己参照方式で actor が本人自身になってしまうため、
                        // 本人のアバターではなく中立なシステムアイコンを出す)
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 44, height: 44)
                            Image(systemName: systemIconName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary)
                        }
                    } else {
                        AvatarImage(urlString: notification.actorAvatarUrl, size: 44)

                        if notification.kind == .newPost {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(AppColors.accent)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(AppColors.background, lineWidth: 2))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        // システム通知は自己参照方式のため actorName が「自分の名前」になってしまう。
                        // アプリ名 "1%" 固定で表示する (両言語共通、OnePercentAccount.name を再利用)
                        Text(notification.kind.isSystemKind ? OnePercentAccount.name : (notification.actorName ?? L.notificationsAnonymous(lang)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)

                        Spacer()

                        Text(relativeTime(notification.createdAt))
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary)
                    }

                    Text(message)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let preview = notification.previewText, !preview.isEmpty {
                        Text("\"\(preview)\"")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textTertiary)
                            .italic()
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }

                // 未読インジケータ
                if notification.isUnread {
                    Circle()
                        .fill(AppColors.accent)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(notification.isUnread ? AppColors.cardBackground.opacity(0.4) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var message: String {
        let actor = notification.actorName ?? L.notificationsAnonymous(lang)
        let isComment = notification.targetCommentId != nil
        switch notification.kind {
        case .like:        return L.notificationLikeMessage(actor, lang)
        case .follow:      return L.notificationFollowMessage(actor, lang)
        case .comment:     return L.notificationCommentMessage(actor, lang)
        case .reply:       return L.notificationReplyMessage(actor, lang)
        case .commentLike: return L.notificationCommentLikeMessage(actor, lang)
        case .newPost:     return L.notificationNewPostMessage(actor, lang)
        case .contentRejected:
            return isComment
                ? (lang == .japanese ? "コメントがガイドライン違反と判定され、非表示になりました" : "Your comment was found to violate the guidelines and has been hidden")  // 文言はユーザー添削待ち
                : (lang == .japanese ? "投稿がガイドライン違反と判定され、非表示になりました" : "Your post was found to violate the guidelines and has been hidden")  // 文言はユーザー添削待ち
        case .contentFlagged:
            return isComment
                ? (lang == .japanese ? "コメントの表示が制限されました" : "Your comment's visibility has been limited")  // 文言はユーザー添削待ち
                : (lang == .japanese ? "投稿の表示が制限されました" : "Your post's visibility has been limited")  // 文言はユーザー添削待ち
        case .appealApproved:
            return lang == .japanese ? "異議申し立てが承認され、コンテンツが復元されました" : "Your appeal was approved and your content has been restored"  // 文言はユーザー添削待ち
        case .appealRejected:
            return lang == .japanese ? "異議申し立ては承認されませんでした" : "Your appeal was not approved"  // 文言はユーザー添削待ち
        case .appealUnsure:
            // 運営アカウントにしか届かない kind (054)。preview_text に申し立て理由の冒頭が入る
            return lang == .japanese
                ? "\(actor)さんの異議申し立てが審査待ちです (AIは判定を保留)"
                : "\(actor)'s appeal is awaiting your review (AI deferred)"
        case .weeklyReport:
            // preview_text にその週のロック秒数が入る (081)。0秒の人にも届く
            let secs = Int(notification.previewText ?? "") ?? 0
            if secs <= 0 {
                return lang == .japanese ? "先週のレポートができました" : "Your weekly report is ready"  // 文言はユーザー添削待ち
            }
            let h = secs / 3600, m = (secs % 3600) / 60
            let dur = lang == .japanese
                ? (h > 0 ? "\(h)時間\(m)分" : "\(m)分")
                : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
            return lang == .japanese
                ? "先週のレポートができました。ロックした時間は\(dur)"   // 文言はユーザー添削待ち
                : "Your weekly report is ready. You locked \(dur)"
        case .unknown:     return ""
        }
    }

    /// isSystemKind の4種のみで参照される (それ以外は到達しない)
    private var systemIconName: String {
        switch notification.kind {
        case .contentRejected: return "eye.slash.fill"
        case .contentFlagged:  return "exclamationmark.triangle.fill"
        case .appealApproved:  return "checkmark.seal.fill"
        case .appealRejected:  return "xmark.seal.fill"
        case .appealUnsure:    return "questionmark.diamond.fill"
        case .weeklyReport:    return "chart.bar.doc.horizontal"
        default:               return "bell.fill"
        }
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
