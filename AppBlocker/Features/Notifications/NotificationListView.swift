//
//  NotificationListView.swift
//  AppBlocker
//
//  In-app notification list (like / follow / comment / reply / comment like)
//  Marks everything as read on entering the screen and sets the unread badge to 0
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
    /// Target of the appeal sheet when a system notification (moderation result/appeal result) is tapped
    @State private var appealSheetTarget: AppealTarget?
    /// Navigation when a weekly report notification is tapped (081)
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
        // Mitigation for the real device feedback #6 family (2026-07-22, not verified): this screen is pushed
        // from MyProfileView (toolbarBackground(.hidden) for the hero). Without an explicitly visible opaque bar,
        // the symptom "the top of the list is pushed up under the bar and the latest notification cannot be
        // seen without pulling" appeared (suspected to be triggered right after posting). Make the bar
        // explicitly opaque and visible to fix the layout
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Real device feedback #6: measured correction for the inset collapse (see SafeAreaCollapseFix.swift)
        .safeAreaCollapseFix()
        .task {
            await notifService.loadNotifications()
            await notifService.markAllRead()
            // The most natural moment to ask is when someone came to look at notifications (asking suddenly right
            // after launch tends to get denied, and once denied it cannot be recovered from inside the app).
            // If already decided, nothing happens
            await PushNotificationService.shared.requestAuthorizationIfNeeded()
        }
        // 2026-07-22 real device feedback: with fullScreenCover there is no way back and you get stuck (a new
        // NavigationStack inside the cover has no back button). This screen itself is pushed inside
        // MyProfileView's NavigationStack, so the post jump is also unified to push (the back button +
        // swipe-right-to-go-back come naturally)
        .navigationDestination(isPresented: $showWeeklyReport) {
            WeeklyReportView()
        }
        .navigationDestination(item: $jumpToPost) { jump in
            // ⚠️ Always pass the author info and canDelete. If omitted, MyPostsFeedView interprets it as
            //    "my own post feed" and shows my name/avatar/
            //    Pro badge on another user's post (bug reported by the user on 2026-08-28)
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
            // A reply notification on an official quote (has target_quote_id) opens the comment page directly as a
            // minimal implementation (we do not have a FeedItem for the image header, so nil = plain display)
            if let quoteId = notif.targetQuoteId {
                commentPageRequest = CommentPageRequest(item: nil, target: .quote(quoteId), postOwnerId: nil)
                return
            }
            guard let postId = notif.targetPostId else { return }
            openPost(postId, from: notif)
        case .contentRejected, .contentFlagged, .appealApproved, .appealRejected:
            // By spec, once a comment is rejected/flagged it no longer appears even to its author in the comment
            // list RPC, so open AppealSheetView (status display or appeal input) directly from the notification.
            // For posts, RLS (037) lets the author fetch their own rejected/flagged posts, so use the existing
            // fetchPost path
            if let commentId = notif.targetCommentId {
                appealSheetTarget = .comment(commentId)
                return
            }
            guard let postId = notif.targetPostId else { return }
            openPost(postId, from: notif)
        case .weeklyReport:
            // 081: Tap opens that week's report (the most recent completed week = offset 1)
            showWeeklyReport = true
        case .appealUnsure:
            // Operators only: rulings are done in the SQL Editor for now (an admin console is in the post-release
            // backlog). The target is another user's flagged content, which RLS does not let us open, so no navigation
            break
        case .unknown:
            break
        }
    }

    /// Fetch the post by post_id and jump to the full-screen feed (MyPostsFeedView).
    ///
    /// 🔴 Who the author is is decided by post.userId. It is not necessarily the notification's actor:
    ///   - new_post          → actor = author (going to see someone else's post)
    ///   - like/comment etc. → actor = the person who acted, and the post is mine
    /// Use the display info the notification carries only when the actor and the author match;
    /// otherwise do not pass it (MyPostsFeedView fills it with my own info)
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

/// Navigation data for opening a post from a notification. Carries not only the post but also "who its
/// author is" (the post alone does not have the display name/avatar/Pro)
private struct PostJump: Identifiable, Hashable {
    let post: UserPost
    let authorName: String?
    let authorAvatarUrl: String?
    let authorIsPro: Bool
    /// Whether it is my post. Decides whether the delete menu is available
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
                        // System notification (with the self-reference approach the actor becomes the user themselves, so
                        // show a neutral system icon instead of the user's own avatar)
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
                        // System notifications use the self-reference approach, so actorName would be "your own name".
                        // Show the fixed app name "1%" (same for both languages, reusing OnePercentAccount.name)
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

                // Unread indicator
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
                ? (lang == .japanese ? "コメントがガイドライン違反と判定され、非表示になりました" : "Your comment was found to violate the guidelines and has been hidden")  // Wording pending user review
                : (lang == .japanese ? "投稿がガイドライン違反と判定され、非表示になりました" : "Your post was found to violate the guidelines and has been hidden")  // Wording pending user review
        case .contentFlagged:
            return isComment
                ? (lang == .japanese ? "コメントの表示が制限されました" : "Your comment's visibility has been limited")  // Wording pending user review
                : (lang == .japanese ? "投稿の表示が制限されました" : "Your post's visibility has been limited")  // Wording pending user review
        case .appealApproved:
            return lang == .japanese ? "異議申し立てが承認され、コンテンツが復元されました" : "Your appeal was approved and your content has been restored"  // Wording pending user review
        case .appealRejected:
            return lang == .japanese ? "異議申し立ては承認されませんでした" : "Your appeal was not approved"  // Wording pending user review
        case .appealUnsure:
            // A kind delivered only to the operator account (054). preview_text holds the start of the appeal reason
            return lang == .japanese
                ? "\(actor)さんの異議申し立てが審査待ちです (AIは判定を保留)"
                : "\(actor)'s appeal is awaiting your review (AI deferred)"
        case .weeklyReport:
            // preview_text holds that week's lock seconds (081). It is also sent to people with 0 seconds
            let secs = Int(notification.previewText ?? "") ?? 0
            if secs <= 0 {
                return lang == .japanese ? "先週のレポートができました" : "Your weekly report is ready"  // Wording pending user review
            }
            let h = secs / 3600, m = (secs % 3600) / 60
            let dur = lang == .japanese
                ? (h > 0 ? "\(h)時間\(m)分" : "\(m)分")
                : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
            return lang == .japanese
                ? "先週のレポートができました。ロックした時間は\(dur)"   // Wording pending user review
                : "Your weekly report is ready. You locked \(dur)"
        case .unknown:     return ""
        }
    }

    /// Referenced only by the 4 isSystemKind kinds (the others never reach here)
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
