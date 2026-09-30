//
//  FeedListCard.swift
//  AppBlocker
//
//  BeReal/IG-style card for the home / tag / detail feeds (spec finalized 2026-07-10).
//    - Header: avatar + name (+badge) / follow pill / ... menu
//    - Title row: truncated to 1 line with "..." → expands on tap (#tags share the same area and
//      become buttons when expanded)
//    - Media (4:5): fit + blurred fill of the same image / carousel / quote = background + text
//        Bottom right: like ♥ and comment 💬 buttons (BeReal-style overlay, icons only)
//        Bottom left: avatars of users who liked ≤3 + "+N" (FeedExtras)
//    - Card bottom: "N件のコメントをすべて表示" ("View all N comments") + preview of 3 comments
//      (FeedExtras)
//  Quotes are handled exactly the same as posts (confirmed by the user).
//

import SwiftUI

/// Reports the frame of the media (4:5 image) inside the card to the parent (FeedCardListView).
/// Used to position the trash button of the restriction overlay at "the top right of the image" (it is
/// read with overlayPreferenceValue per card, so it does not mix with other cards in the list)
struct FeedMediaBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct FeedListCard: View {

    let item: FeedItem
    let lang: AppLanguage
    let showOriginal: Bool
    let isLiked: Bool
    let isFollowing: Bool
    /// Users who liked + comment preview (the parent passes it from FeedExtrasService. Hidden if nil)
    var extras: FeedExtras? = nil
    let onLikeTap: () -> Void
    let onFollowTap: () -> Void
    /// Tap on the avatar/name row. For a quote, goes to the 1% official account; for a post, to the author
    let onAuthorTap: () -> Void
    let onTagTap: (String) -> Void
    /// Tap on the "- author name" line of a quote (quote only). Goes to the author topic feed
    var onTopicTap: (() -> Void)? = nil
    /// ... menu (share / save / report etc.). Shown at the right of the header
    var menuContent: AnyView? = nil
    /// Tap on the comment button / preview area → comment page
    var onCommentTap: (() -> Void)? = nil
    /// Tap on the stack of users who liked at the bottom left of the image → list of users who liked
    var onLikersTap: (() -> Void)? = nil

    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var commentService = CommentService.shared
    @State private var heartBursts: [HeartBurstToken] = []
    @State private var titleExpanded = false
    /// Follow tap effect: show a check mark for 0.9 seconds, then hide the pill (if it disappears
    /// immediately, the effect cannot be seen)
    @State private var followTapped = false
    @State private var followLingering = false

    /// Baseline to prevent double-counting of the like count (see Fix1).
    /// item.likeCount is "the aggregate at the time the server last returned it", and after
    /// toggle_quote_like/toggle_post_like or a re-fetch it already includes your own like. Simply adding
    /// + (isLiked ? 1 : 0) here shows +1 too many in the case "it was already liked at load time", so we
    /// record isLiked at mount time as the reference point, and afterwards only add the difference from
    /// that reference point.
    /// When item.likeCount itself changes (= a new confirmed server value arrived), the reference point is
    /// re-synced to isLiked.
    @State private var baselineLiked: Bool?
    /// Baseline to prevent double-counting of the comment count (see Fix2. Details under displayCommentCount)
    @State private var baselineCommentDelta: Int?

    private var isOwnPost: Bool {
        guard let myId = auth.userId, let authorId = item.authorId else { return false }
        return myId == authorId
    }

    private var displayLikeCount: Int {
        max(0, item.likeCount + (isLiked ? 1 : 0) - (baselineLiked == true ? 1 : 0))
    }

    /// Local delta held by CommentService (per quote/post).
    /// Value used to move comment_count "in place" when this card is pushed to CommentPageView
    private var currentCommentDelta: Int {
        switch item.kind {
        case .quote: return commentService.commentCountDelta(forQuote: item.itemId)
        case .post:  return commentService.commentCountDelta(forPost: item.itemId)
        }
    }

    /// Comment count for display. Key points of the exactly-once double-count prevention:
    /// - The home feed (FeedService.recommendedFeed/followingFeed) and your own post list
    ///   (UserPostService.myPosts/viewingPostsByUser) are @Published arrays, and
    ///   CommentService.bumpLocalCommentCount patches item.commentCount itself directly on every comment
    ///   post/delete. In this case the delta moves at the same time, so adding it as is would double-count.
    /// - For static snapshots such as author topic / tag / liked quotes (quotes: [Quote] mapped every
    ///   time), item.commentCount does not move in place, so the delta is the only update path.
    /// To support both, "at the moment item.commentCount changes (= a direct patch, or a real re-fetch)"
    /// we re-sync baselineCommentDelta to the delta at that time, and afterwards only add "the new delta
    /// from that reference point".
    /// → The directly patched amount is absorbed into the baseline and cancels out (home feed = applied
    ///   exactly once), and in static snapshots the baseline does not move, so the full delta is applied
    ///   (the only update path = applied exactly once).
    private var displayCommentCount: Int {
        max(0, item.commentCount + (currentCommentDelta - (baselineCommentDelta ?? 0)))
    }

    private var showFollowPill: Bool { (!isFollowing && !isOwnPost) || followLingering }

    // Cardless layout (follows BeReal, user-specified 2026-07-10):
    // no card background/border; only the rounded image sits directly on the black background.
    // Header/title/comment preview are drawn directly on the black background with no borders
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            titleRow
            media
            commentPreview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if baselineLiked == nil { baselineLiked = isLiked }
            if baselineCommentDelta == nil { baselineCommentDelta = currentCommentDelta }
        }
        .onChange(of: item.likeCount) { _, _ in baselineLiked = isLiked }
        .onChange(of: item.commentCount) { _, _ in baselineCommentDelta = currentCommentDelta }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onAuthorTap) {
                HStack(spacing: 9) {
                    if item.kind == .quote {
                        OnePercentAvatar(size: 34)
                        nameLabel(OnePercentAccount.name, official: true, pro: false)
                    } else {
                        AvatarImage(
                            urlString: item.authorAvatarUrl,
                            size: 34,
                            placeholderColor: AppColors.textSecondary
                        )
                        nameLabel(item.authorName ?? "—",
                                  official: item.isOfficialAuthor,
                                  pro: item.isProAuthor)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())

            Spacer(minLength: 8)

            if showFollowPill {
                Button {
                    guard !followTapped else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) { followTapped = true }
                    followLingering = true
                    onFollowTap()
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        withAnimation(.easeOut(duration: 0.2)) {
                            followLingering = false
                            followTapped = false
                        }
                    }
                } label: {
                    Group {
                        if followTapped {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text(L.authorFollowShort(isFollowing, lang))
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundColor(AppColors.background)
                    .frame(minWidth: 56)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppColors.textPrimary))
                }
                .buttonStyle(PlainButtonStyle())
            }

            if let menuContent {
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func nameLabel(_ name: String, official: Bool, pro: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            if official {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.blue)
                    .accessibilityLabel(L.feedOfficialBadgeLabel(lang))
            }
        }
    }

    // MARK: - Title Row (under the header: title + #tags. Truncated to 1 line → expands on tap)

    @ViewBuilder
    private var titleRow: some View {
        let tags = item.displayTags

        if item.kind == .post {
            let title = (item.displayTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty || !tags.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    if titleExpanded {
                        if !title.isEmpty {
                            Text(title)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textPrimary.opacity(0.92))
                                .multilineTextAlignment(.leading)
                        }
                        if !tags.isEmpty { tagButtons(tags) }
                    } else {
                        // Collapsed: title + tags on 1 line, truncated with "...". Expands on tap
                        (Text(title)
                         + Text(tags.isEmpty ? "" : "  " + tags.map { "#\(Quote.categoryDisplay($0, lang: lang))" }.joined(separator: " "))
                            .foregroundColor(AppColors.textTertiary))
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.18)) { titleExpanded.toggle() }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
            }
        } else {
            // Quote: tags only (author names were removed entirely in the 2026-07-30 quote audit; for anonymous
            // authors the whole line is hidden)
            HStack(spacing: 10) {
                if let authorName = item.authorName, !Quote.isAnonymousAuthor(authorName) {
                    if let onTopicTap {
                        Button(action: onTopicTap) {
                            Text("— \(authorName)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Text("— \(authorName)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                if !tags.isEmpty { tagButtons(tags) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
    }

    private func tagButtons(_ tags: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onTagTap(tag)
                } label: {
                    Text("#\(Quote.categoryDisplay(tag, lang: lang))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Media (4:5 + overlay)

    private var media: some View {
        FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal)
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))  // Only the image has rounded corners (cardless)
            .contentShape(Rectangle())
            // Frame notification so the restriction overlay (FeedCardListView) can align the trash button with
            // "the top right of the image"
            // (2026-07-25 real-device feedback: it floated at the card's top right = next to the header; moved to
            // the top right inside the image)
            .anchorPreference(key: FeedMediaBoundsKey.self, value: .bounds) { $0 }
            .overlay(alignment: .bottomLeading) { likerStack }
            .overlay(alignment: .bottomTrailing) { imageActionButtons }
            .overlay { heartBurstLayer }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        if !isLiked { onLikeTap() }
                        let token = HeartBurstToken(position: value.location)
                        heartBursts.append(token)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            heartBursts.removeAll { $0.id == token.id }
                        }
                    }
            )
    }

    /// Bottom left of the image: avatars of users who liked ≤3 + "+N" (BeReal RealMoji stack style).
    /// Tap → list of users who liked (onLikersTap)
    /// Users who liked, shown as avatars.
    ///
    /// 🔴 If you have liked it but you are not yet in the list that came from the server,
    ///    add yourself at the front so the counts match. displayLikeCount optimistically adds +1
    ///    for you, so if only the avatar side keeps the old list, the two sides of the subtraction
    ///    do not match, and you get "+1 shown with no avatar" or "only 1 person but it looks like 2"
    ///    (reported on a real device 2026-08-29). The server side returns ≤3 items, so we also cut at 3
    private var displayLikers: [FeedLiker] {
        let base = extras?.likers ?? []
        guard isLiked,
              let myId = auth.userId,
              !base.contains(where: { $0.userId == myId })
        else { return base }

        let me = FeedLiker(
            userId: myId,
            displayName: auth.displayName,
            avatarUrl: auth.avatarUrl?.absoluteString
        )
        return Array(([me] + base).prefix(3))
    }

    @ViewBuilder
    private var likerStack: some View {
        let likers = displayLikers
        let remaining = max(0, displayLikeCount - likers.count)

        if !likers.isEmpty || remaining > 0 {
            Button {
                onLikersTap?()
            } label: {
                HStack(spacing: 7) {
                    if !likers.isEmpty {
                        HStack(spacing: -11) {
                            ForEach(likers) { liker in
                                AvatarImage(
                                    urlString: liker.avatarUrl,
                                    size: 34,
                                    placeholderColor: AppColors.textSecondary
                                )
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                            }
                        }
                    }
                    if remaining > 0 {
                        Text("+\(remaining.abbreviated)")
                            .font(.system(size: 13, weight: .bold)).monospacedDigit()
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.55)))
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    /// Bottom right of the image: like + comment (BeReal-style vertical overlay, icons only).
    /// Make the space between buttons = space between the comment and the bottom edge = space to the right
    /// edge, for an even rhythm
    private var imageActionButtons: some View {
        // Unified vertical rhythm (2026-07-25 real-device feedback): the gap "like count → comment icon"
        // (spacing 10) is made equal to "comment count → image bottom edge" (bottom 10). Icon and number sit
        // tight (spacing 0 + icon frame 32→28) so they read as a group
        VStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onLikeTap()
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 25))
                        .foregroundColor(isLiked ? .red : .white)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        .frame(width: 40, height: 28)
                        // Sink → spring + particles (LikePopEffect.swift; the old symbolEffect.bounce was rejected)
                        .likePopEffect(isLiked: isLiked, particleRadius: 24)
                    // When the number appears on 0→1, the comment button below shifts with it (real-device feedback
                    // 2026-07-15). Always reserve the number slot, and make it transparent at 0 to fix the height
                    actionCountLabel(displayLikeCount)
                        .opacity(displayLikeCount > 0 ? 1 : 0)
                }
                .frame(width: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if let onCommentTap {
                Button(action: onCommentTap) {
                    VStack(spacing: 0) {
                        Image(systemName: "ellipsis.bubble.fill")
                            .font(.system(size: 23))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                            .frame(width: 40, height: 28)
                        // Always reserve the number slot, for the same reason as the like side
                        actionCountLabel(displayCommentCount)
                            .opacity(displayCommentCount > 0 ? 1 : 0)
                    }
                    .frame(width: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 10)
    }

    /// Small count number under the ♥/💬 icons (white text + shadow so it is readable on the image)
    private func actionCountLabel(_ count: Int) -> some View {
        Text(count.abbreviatedCount(lang))
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }

    @ViewBuilder
    private var heartBurstLayer: some View {
        ForEach(heartBursts) { burst in
            DoubleTapHeartBurst(position: burst.position)
                .zIndex(999)
        }
    }

    // MARK: - Comment Preview (drawn directly under the image with no border. Shows nothing at 0 comments = no space either)

    @ViewBuilder
    private var commentPreview: some View {
        let previews = extras?.comments ?? []
        let count = displayCommentCount

        if count > 0 || !previews.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if count > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(L.feedCommentsViewAll(count, lang))
                            .font(.system(size: 13))
                    }
                    .foregroundColor(AppColors.textSecondary)
                }

                ForEach(previews.prefix(3)) { preview in
                    (Text(preview.authorName ?? "—")
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.textPrimary.opacity(0.9))
                     + Text("  \(preview.text)")
                        .foregroundColor(AppColors.textSecondary))
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onCommentTap?() }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }
}

// MARK: - FeedCardMediaView (shared part for drawing media)
//
// Shared by the card body and the header of the comment page. Contains no overlays/gestures.
// Callers must fix frame / aspectRatio before using it.

struct FeedCardMediaView: View {
    let item: FeedItem
    let lang: AppLanguage
    let showOriginal: Bool

    @State private var currentPage: Int = 0

    var body: some View {
        if item.imageCount > 1 {
            ZStack(alignment: .bottom) {
                TabView(selection: $currentPage) {
                    ForEach(Array(item.imageUrls.enumerated()), id: \.offset) { idx, url in
                        // Actually load only the one page before and after the selected page
                        // (fix for loading all hidden pages at once, which increased Storage egress up to 4x = M19)
                        //
                        // 🔴 Do not use if/else here to switch between "Views of different types".
                        //    currentPage is read inside the ForEach, so every time the page moves,
                        //    all pages are rebuilt. If the type changes at that point, the page identity
                        //    changes, and the TabView (a UIPageViewController inside) recreates its children
                        //    during the swipe and the gesture is cut off
                        //    = it jumps to the next page when the finger is only halfway (reported on a real device 2026-08-27).
                        //    Up to 2 images, abs(idx-currentPage) <= 1 was always true, so no swap happened and
                        //    the bug stayed hidden; it showed up once 077 allowed 5-image posts.
                        //    → Always draw FeedFitBlurImage, and switch only whether it loads or not.
                        imageFitBlur(url: url, shouldLoad: abs(idx - currentPage) <= 1)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Page dots (bottom center)
                HStack(spacing: 6) {
                    ForEach(0..<item.imageCount, id: \.self) { idx in
                        Circle()
                            .fill(idx == currentPage ? Color.white : Color.white.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 10)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .allowsHitTesting(false)
            }
        } else if let url = item.imageUrl {
            imageFitBlur(url: url)
        } else {
            quoteMedia
        }
    }

    /// IG/BeReal style: show the whole image in the frame (scaledToFit) and fill the remaining space with a
    /// blur of the same image. The image itself is never cropped (absolute user requirement 2026-07-11).
    ///
    /// Important: fix "the frame actually given" with GeometryReader, and give that frame explicitly to
    /// both fill (blurred background) and fit (the image). If the sizing is left to the ZStack, the fill
    /// layer pushes the ZStack wider, fit applies to the widened frame, and the image gets cropped
    /// (a bug that really happened in the 34% header of the comment page. In the feed the frame was 4:5,
    /// so it stayed hidden)
    private func imageFitBlur(url: URL, shouldLoad: Bool = true) -> some View {
        FeedFitBlurImage(url: url, shouldLoad: shouldLoad)
    }

    /// ⚠️ Not called from anywhere since 2026-08-28 (kept for rollback).
    /// Non-selected carousel pages are no longer swapped to this; instead FeedFitBlurImage is always
    /// drawn and only loading is stopped with shouldLoad=false.
    /// Switching the View type changes the page identity, and the TabView swipe is cut off halfway
    /// (see the ForEach comment above)
    private func mediaPlaceholder() -> some View {
        GeometryReader { geo in
            Color.black
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    /// Quote / post without an image: centered text
    /// 2026-07-30 major change: all photo backgrounds for official quotes were removed and replaced with
    /// 10 "paper × typography" templates (QuoteCardView). UGC posts without images keep the selected
    /// background as before (QuoteBackgroundView)
    @ViewBuilder
    private var quoteMedia: some View {
        if item.kind == .quote {
            QuoteCardView(
                primary: item.displayPrimary(lang: lang, showOriginal: showOriginal),
                secondary: item.displaySecondary(lang: lang, showOriginal: showOriginal),
                seedId: item.itemId
            )
        } else {
            legacyTextMedia
        }
    }

    /// UGC posts without images (the user has chosen a background): the old rendering is kept
    private var legacyTextMedia: some View {
        let primary = item.displayPrimary(lang: lang, showOriginal: showOriginal)
        return ZStack {
            QuoteBackgroundView(quoteId: item.itemId, backgroundIndex: item.backgroundId)
            Color.black.opacity(0.25)

            VStack(spacing: 10) {
                Text("\"\(QuoteTypography.poeticText(primary))\"")
                    .font(.system(size: QuoteTypography.displayFontSize(for: primary), weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(7)
                    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                    .lineLimit(8)
                    .minimumScaleFactor(0.6)

                if let secondary = item.displaySecondary(lang: lang, showOriginal: showOriginal) {
                    Text(QuoteTypography.poeticText(secondary))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: - FeedFitBlurImage (actual drawing of fit + blurred fill)

/// Actual drawing of fit + blurred fill of the same image. Replaces AsyncImage (2026-08-09):
/// AsyncImage gets stuck in .failure even on a cancel during scrolling (no retry mechanism), and
/// previously it fell from there into quoteMedia, which caused the bug "an image post turns into a
/// forest background + quotation marks"
/// (a leftover of the same kind of bug that was already fixed in the profile grid UserPostGridCell).
/// - Cancel: do not write phase, stay in .loading → the .task runs again on reappearance, a natural retry
/// - Real failure: neutral placeholder (black + photo). Never fall into quoteMedia
///   (presenting an image post as different content is worse than showing nothing)
private struct FeedFitBlurImage: View {
    let url: URL

    /// While false, no network fetch is started and it keeps the same look as loading (Color.black).
    /// Used to stop hidden carousel pages (outside ±1 of the selected one) = egress fix for M19.
    ///
    /// 🔴 Express "load or not" with this flag, not by switching Views.
    ///    Previously the caller used if/else to swap in a placeholder of a different type, but then
    ///    the page identity changed and the TabView recreated its children during the swipe, and the
    ///    gesture was cut off (the swipe bug reported on a real device 2026-08-27).
    var shouldLoad: Bool = true

    /// Re-run key for .task. Including shouldLoad, not just url, makes loading start the moment the page
    /// enters the range, and frees the image the moment it leaves the range
    private struct LoadKey: Equatable {
        let url: URL
        let shouldLoad: Bool
    }

    private enum Phase {
        case loading
        case success(UIImage)
        case failure
    }
    @State private var phase: Phase = .loading
    /// Holds which url the .success image belongs to (checked by the guard in the .task below)
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            Group {
                switch phase {
                case .success(let uiImage):
                    ZStack {
                        Image(uiImage: uiImage).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: 18)
                            .opacity(0.55)
                            // (moved existing comment) The blur is recomputed every frame during scrolling and its GPU cost is
                            // high, so only this layer is rasterized once
                            .drawingGroup()
                        Image(uiImage: uiImage).resizable().scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                case .failure:
                    ZStack {
                        Color.black
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.25))
                    }
                case .loading:
                    Color.black
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: LoadKey(url: url, shouldLoad: shouldLoad)) {
            // Release the image when it leaves the range. Previously the whole View was discarded, so this keeps
            // the same memory behavior as then (1 image ≈ 5.8MB. If the View keeps holding them in a 5-image post,
            // the NSCache of FeedImageLoader cannot evict them and memory only grows).
            // When it comes back, it returns from NSCache immediately, so no network traffic happens
            guard shouldLoad else {
                if case .success = phase {
                    phase = .loading
                    loadedURL = nil
                }
                return
            }
            // Runs every time it reappears. If already fetched for the same url, do nothing (prevents re-decoding
            // and flicker).
            // When it reappears from .failure, it passes here and retries.
            // Without the loadedURL check, if only the url changed while the view identity was kept, the old
            // image would keep showing (that path does not exist now, but if something like a future change of
            // the ForEach key hits it, it would cause the accident "another post's image is shown", so we block
            // it in advance)
            if case .success = phase, loadedURL == url { return }
            phase = .loading
            let image = await FeedImageLoader.shared.image(for: url)
            // Do not write if already canceled (the same root-cause fix as in UserPostGridCell).
            // Code after returning from await is not stopped by cooperative cancellation, so without this guard
            // nil would be permanently fixed as a "real failure"
            if Task.isCancelled { return }
            if let image {
                loadedURL = url
                phase = .success(image)
            } else {
                phase = .failure
            }
        }
    }
}
