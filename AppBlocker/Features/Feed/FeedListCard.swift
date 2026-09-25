//
//  FeedListCard.swift
//  AppBlocker
//
//  ホーム/タグ/詳細フィード用の BeReal/IG 風カード (2026-07-10 確定仕様)。
//    - ヘッダ: アバター + 名前(+バッジ) / フォローピル / … メニュー
//    - タイトル行: 1行省略「…」→ タップで展開 (#タグも同領域、展開時にボタン化)
//    - メディア(4:5): fit+同画像ぼかし埋め / カルーセル / 名言=背景+テキスト
//        右下: いいね♥・コメント💬ボタン (BeReal式オーバーレイ、アイコンのみ)
//        左下: いいねした人アバター ≤3 + 「+N」(FeedExtras)
//    - カード下部: 「N件のコメントをすべて表示」+ コメント3件プレビュー (FeedExtras)
//  名言 (quote) も投稿と完全に同じ扱い (ユーザー確定)。
//

import SwiftUI

/// カード内の media (4:5 画像) の枠を親 (FeedCardListView) へ通知する。
/// 制限オーバーレイのゴミ箱を「画像の右上」に位置合わせするために使う (カード単位の
/// overlayPreferenceValue で読むため、リスト内の他カードと混ざらない)
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
    /// いいねした人 + コメントプレビュー (FeedExtrasService から親が渡す。nil なら非表示)
    var extras: FeedExtras? = nil
    let onLikeTap: () -> Void
    let onFollowTap: () -> Void
    /// アバター/名前行タップ。quote 時は 1% 公式アカウント、post 時は投稿者本人へ
    let onAuthorTap: () -> Void
    let onTagTap: (String) -> Void
    /// 名言の「— 著者名」タップ (quote のみ)。著者トピックフィードへ
    var onTopicTap: (() -> Void)? = nil
    /// … メニュー (共有 / 保存 / 通報 など)。ヘッダ右に表示
    var menuContent: AnyView? = nil
    /// コメントボタン / プレビュー領域タップ → コメントページへ
    var onCommentTap: (() -> Void)? = nil
    /// 画像左下のいいねした人スタックタップ → いいねした人一覧へ
    var onLikersTap: (() -> Void)? = nil

    @ObservedObject private var auth = UserAuthService.shared
    @ObservedObject private var commentService = CommentService.shared
    @State private var heartBursts: [HeartBurstToken] = []
    @State private var titleExpanded = false
    /// フォロータップ演出: チェックマークを 0.9 秒表示してからピルを消す (即消えだと演出が見えない)
    @State private var followTapped = false
    @State private var followLingering = false

    /// いいね数の二重加算防止用ベースライン (Fix1 参照)。
    /// item.likeCount は「サーバーが最後に返した時点の集計値」で、toggle_quote_like/toggle_post_like や
    /// 再 fetch の後は既に自分のいいねを含んでいる。ここで単純に + (isLiked ? 1 : 0) すると
    /// 「読み込み時点で既にいいね済みだった」ケースで +1 過剰表示になるため、
    /// マウント時の isLiked を基準点として記録し、以後は基準点からの差分だけを足す。
    /// item.likeCount 自体が変化した (= 新しいサーバー確定値が届いた) タイミングで基準点を isLiked に再同期する。
    @State private var baselineLiked: Bool?
    /// コメント数の二重加算防止用ベースライン (Fix2 参照。displayCommentCount の項に詳細)
    @State private var baselineCommentDelta: Int?

    private var isOwnPost: Bool {
        guard let myId = auth.userId, let authorId = item.authorId else { return false }
        return myId == authorId
    }

    private var displayLikeCount: Int {
        max(0, item.likeCount + (isLiked ? 1 : 0) - (baselineLiked == true ? 1 : 0))
    }

    /// CommentService が持つローカル差分 (quote/post 別)。
    /// このカードが CommentPageView へ push された「その場」で comment_count を動かすための値
    private var currentCommentDelta: Int {
        switch item.kind {
        case .quote: return commentService.commentCountDelta(forQuote: item.itemId)
        case .post:  return commentService.commentCountDelta(forPost: item.itemId)
        }
    }

    /// 表示用コメント数。exactly-once 二重加算防止の要点:
    /// - ホームフィード (FeedService.recommendedFeed/followingFeed) や自分の投稿一覧
    ///   (UserPostService.myPosts/viewingPostsByUser) は @Published 配列で、
    ///   CommentService.bumpLocalCommentCount がコメント投稿/削除の度に item.commentCount 自体を直接 patch する。
    ///   このケースでは delta も同時に動くため、そのまま足すと二重加算になる。
    /// - 著者トピック/タグ/いいね名言などの静的スナップショット (quotes: [Quote] を毎回 map) は
    ///   item.commentCount がその場では動かないため、delta が唯一の更新経路になる。
    /// この2つを両立させるため「item.commentCount が変化した瞬間 (= 直接 patch か、真の再 fetch)」に
    /// baselineCommentDelta をその時点の delta で再同期し、以後は "その基準点からの新規差分" だけを足す。
    /// → 直接 patch されたぶんは baseline に吸収されて相殺され (ホームフィード = ちょうど1回反映)、
    ///   静的スナップショットでは baseline が動かないので delta がフルに乗る (唯一の更新経路 = ちょうど1回反映)。
    private var displayCommentCount: Int {
        max(0, item.commentCount + (currentCommentDelta - (baselineCommentDelta ?? 0)))
    }

    private var showFollowPill: Bool { (!isFollowing && !isOwnPost) || followLingering }

    // カードレス構成 (BeReal 準拠、2026-07-10 ユーザー指定):
    // カード背景/枠線は持たず、角丸の画像だけが黒背景に直接載る。
    // ヘッダー/タイトル/コメントプレビューは境界線なしで黒背景に直書き
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

    // MARK: - Title Row (ヘッダ下: タイトル + #タグ。1行省略 → タップで展開)

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
                        // 折りたたみ: タイトル + タグを 1 行にまとめ「…」省略。タップで展開
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
            // 名言: タグのみ (著者名は 2026-07-30 名言監査で全廃 — 匿名著者は行ごと非表示)
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

    // MARK: - Media (4:5 + オーバーレイ)

    private var media: some View {
        FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal)
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))  // 角丸は画像だけが持つ (カードレス)
            .contentShape(Rectangle())
            // 制限オーバーレイ (FeedCardListView) がゴミ箱を「画像の右上」に合わせるための枠通知
            // (2026-07-25 実機FB: カード右上=ヘッダー横に浮いていたのを画像内右上へ)
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

    /// 画像左下: いいねした人アバター ≤3 + 「+N」(BeReal RealMoji スタック風)。
    /// タップでいいねした人一覧へ (onLikersTap)
    /// アバターに出すいいねした人。
    ///
    /// 🔴 自分がいいね済みなのにサーバー由来の一覧に自分がまだ入っていない場合、
    ///    先頭に自分を足して母数を揃える。displayLikeCount は自分の分を楽観的に +1
    ///    しているので、アバター側だけ古い一覧のままだと引き算の左右がズレて
    ///    「アバターが無いのに +1 が出る」「1人しかいないのに2人に見える」になる
    ///    (2026-08-29 実機報告)。サーバー側は ≤3 件なので同じく3件で打ち切る
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

    /// 画像右下: いいね + コメント (BeReal 式の縦積みオーバーレイ、アイコンのみ)。
    /// ボタン間の余白 = コメントと下端の余白 = 右端の余白 を揃えて均等リズムにする
    private var imageActionButtons: some View {
        // 縦リズムの統一 (2026-07-25 実機FB): 「いいね数字→コメントアイコン」の間隔 (spacing 10) と
        // 「コメント数字→画像下端」(bottom 10) を同値にする。アイコンと数字は密着 (spacing 0 +
        // アイコン枠 32→28) でグループ感を出す
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
                        // 沈み込み→スプリング+パーティクル (LikePopEffect.swift、旧 symbolEffect.bounce は却下)
                        .likePopEffect(isLiked: isLiked, particleRadius: 24)
                    // 0→1 で数字が出現すると下のコメントボタンごと位置がズレる (実機FB 2026-07-15)。
                    // 数字スロットを常時確保し、0 のときは透明にして高さを固定する
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
                        // いいね側と同じ理由で数字スロットを常時確保
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

    /// ♥/💬 アイコン下の小さなカウント数字 (画像上で読めるよう白文字 + シャドウ)
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

    // MARK: - Comment Preview (画像の下に境界線なしで直書き。0 件なら何も出さない = 余白も作らない)

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

// MARK: - FeedCardMediaView (メディア描画の共通部品)
//
// カード本体とコメントページのヘッダーで共用する。オーバーレイ/ジェスチャは含まない。
// 呼び出し側で frame / aspectRatio を確定させてから使うこと。

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
                        // 選択中ページの前後1枚だけ実ロードする
                        // (非表示ページの一斉ロードで Storage egress が最大4倍化していた問題 = M19)
                        //
                        // 🔴 ここで if/else で「別の型の View」を出し分けてはいけない。
                        //    currentPage は ForEach の中で読まれるので、ページが動くたびに
                        //    全ページが再構築される。そのとき型が入れ替わるとページの identity が
                        //    変わり、TabView (内部は UIPageViewController) がスワイプ中に子を
                        //    作り直してジェスチャーが打ち切られる
                        //    = 指が半分まで来たところで次ページへ飛ぶ (2026-08-27 実機報告)。
                        //    2枚組までは abs(idx-currentPage) <= 1 が常に真で入れ替えが起きず
                        //    潜伏していたが、077 で5枚投稿を可能にしたことで顕在化した。
                        //    → 常に FeedFitBlurImage を描画し、ロードするか否かだけを切り替える。
                        imageFitBlur(url: url, shouldLoad: abs(idx - currentPage) <= 1)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // ページドット (中央下)
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

    /// 枠に画像全体を見せ (scaledToFit)、余白は同じ画像のぼかしで埋める IG/BeReal 式。
    /// 本体は絶対にクロップしない (ユーザー絶対要件 2026-07-11)。
    ///
    /// 重要: GeometryReader で「実際に与えられた枠」を確定し、fill (ぼかし背景) と
    /// fit (本体) の両方にその枠を明示 frame する。ZStack のサイズ決定に任せると
    /// fill レイヤーが ZStack を押し広げ、fit が広がった枠に効いて本体がクロップされる
    /// (コメントページの 34% ヘッダーで実発生したバグ。フィードは枠=4:5 だったため潜伏)
    private func imageFitBlur(url: URL, shouldLoad: Bool = true) -> some View {
        FeedFitBlurImage(url: url, shouldLoad: shouldLoad)
    }

    /// ⚠️ 2026-08-28 以降どこからも呼ばれていない (ロールバック用に残置)。
    /// カルーセルの非選択ページはこれに差し替えるのではなく、FeedFitBlurImage を
    /// 常に描画して shouldLoad=false でロードだけ止める形に変更した。
    /// View の型を出し分けるとページの identity が変わり、TabView のスワイプが
    /// 途中で打ち切られるため (上の ForEach のコメント参照)
    private func mediaPlaceholder() -> some View {
        GeometryReader { geo in
            Color.black
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    /// 名言 / 画像なし投稿: 中央テキスト
    /// 2026-07-30 大転換: 公式名言=写真背景を全廃し「紙×タイポ」の10テンプレート
    /// (QuoteCardView)。UGC の画像なし投稿は従来どおり選択済み背景 (QuoteBackgroundView)
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

    /// UGC の画像なし投稿 (ユーザーが背景を選んでいる) — 旧レンダリングを維持
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

// MARK: - FeedFitBlurImage (fit+ぼかし埋めの実描画)

/// fit+同画像ぼかし埋めの実描画。AsyncImage からの置き換え (2026-08-09):
/// AsyncImage はスクロール中のキャンセルでも .failure に固着し (リトライ機構なし)、
/// 従来はそこから quoteMedia に落ちて「画像投稿が森背景＋引用符に化ける」バグになっていた
/// (プロフィールグリッド UserPostGridCell で対策済みだった同型バグの取り残し)。
/// - キャンセル: phase を書かず .loading のまま → 再出現時の .task 再実行で自然リトライ
/// - 本当の失敗: 中立プレースホルダ (黒+photo)。quoteMedia には絶対に落とさない
///   (画像投稿である事実を偽って別コンテンツに見せるのは無表示より悪い)
private struct FeedFitBlurImage: View {
    let url: URL

    /// false の間はネットワーク取得を開始せず、ロード中と同じ見た目 (Color.black) に留める。
    /// カルーセルの非表示ページ (選択中の ±1 の範囲外) を止めるため = M19 の egress 対策。
    ///
    /// 🔴 この「読み込むか否か」は View の出し分けではなくフラグで表現すること。
    ///    以前は呼び出し側が if/else で別型のプレースホルダに差し替えていたが、それだと
    ///    ページの identity が変わって TabView がスワイプ中に子を作り直し、ジェスチャーが
    ///    打ち切られていた (2026-08-27 実機報告のスワイプバグ)。
    var shouldLoad: Bool = true

    /// .task の再実行キー。url だけでなく shouldLoad も含めることで、
    /// 範囲内に入った瞬間にロードが始まり、範囲外に出た瞬間に画像を解放できる
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
    /// .success の画像がどの url のものかを持つ (下の .task のガードで照合する)
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
                            // (既存コメントを移設) ぼかしはスクロール中に毎フレーム再計算される
                            // GPU コストが大きいため、このレイヤーだけ一度だけラスタライズする
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
            // 範囲外に出たら画像を手放す。以前は View ごと破棄していたので、そのときと
            // 同じメモリ挙動を保つ (1枚 ≈ 5.8MB。5枚組で View が持ち続けると
            // FeedImageLoader の NSCache が追い出せず純増する)。
            // 戻ってきたときは NSCache から即復帰するので通信は発生しない
            guard shouldLoad else {
                if case .success = phase {
                    phase = .loading
                    loadedURL = nil
                }
                return
            }
            // 再出現のたびに走る。同じ url で取得済みなら何もしない (再デコード・ちらつき防止)。
            // .failure から再出現した場合はここを通ってリトライになる。
            // loadedURL の照合が無いと、view identity が維持されたまま url だけ変わった場合に
            // 古い画像が残り続ける (現状その経路は無いが、将来 ForEach のキー変更等で踏むと
            // 「別投稿の画像が表示される」事故になるため先に潰しておく)
            if case .success = phase, loadedURL == url { return }
            phase = .loading
            let image = await FeedImageLoader.shared.image(for: url)
            // キャンセル済みなら書かない (UserPostGridCell と同じ真因対策)。
            // await 復帰後のコードは協調的キャンセルでは止まらないため、この guard が無いと
            // nil を「本当の失敗」として恒久固定してしまう
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
