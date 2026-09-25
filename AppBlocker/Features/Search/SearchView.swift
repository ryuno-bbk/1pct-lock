//
//  SearchView.swift
//  AppBlocker
//
//  検索タブのルート View (2026-07-15 新設)。
//  「アカウント / 投稿」2セグメント。アカウント側は旧アカウント検索画面の挙動を再現し
//  (1%公式特別行 + UserSearchResult 行)、投稿側は SearchService.searchPosts の結果を
//  簡易リスト行で表示してタップで FeedCardListView へ push する。
//

import SwiftUI

struct SearchView: View {
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var query: String = ""
    // 実機FB第7弾: 検索のデフォルトは投稿セグメント (2026-07-15)
    @State private var selectedTab: SearchTab = .posts

    // アカウント検索の状態
    @State private var userResults: [UserSearchResult] = []
    @State private var isSearchingUsers: Bool = false

    // 投稿検索の状態
    @State private var postResults: [FeedItem] = []
    @State private var isSearchingPosts: Bool = false

    @State private var searchTask: Task<Void, Never>?

    @State private var selectedUserId: UUID?
    @State private var selectedUserName: String?
    @State private var selectedAvatarUrl: String?
    @State private var showUserProfile: Bool = false
    @State private var showOfficialProfile: Bool = false

    @State private var postDetailRequest: PostDetailRequest?

    enum SearchTab: String, Hashable, CaseIterable, Identifiable {
        case posts
        case accounts
        var id: String { rawValue }
    }

    /// 投稿詳細への遷移リクエスト (item 方式。isPresented + 別 @State だと
    /// いいね後に selectedPostStartKey が変化しても showPostDetail が既に true のままだと
    /// navigationDestination が更新されず開けなくなる regression があった、実機FB第7弾 2026-07-15)
    struct PostDetailRequest: Identifiable, Hashable {
        let startKey: String
        var id: String { startKey }
    }

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 1%公式アカウントの特別行を出すか判定 (旧アカウント検索画面と同じロジック)。
    private var showOfficialRow: Bool {
        let q = trimmedQuery.lowercased()
        if q.isEmpty { return true }
        if "1%".hasPrefix(q) || "onepercent".hasPrefix(q) { return true }
        return ["1", "o", "%"].contains(q)
    }

    private var showUsersEmptyState: Bool {
        !isSearchingUsers && trimmedQuery.count >= 2 && userResults.isEmpty && !showOfficialRow
    }

    private var showPostsEmptyState: Bool {
        !isSearchingPosts && !trimmedQuery.isEmpty && postResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 実機FB第7弾 (2026-07-15): 「詰まりすぎ」対応で上下の余白を拡張
                    SearchBarField(text: $query, placeholder: SearchTabStrings.placeholder(lang))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    segmentBar
                        .padding(.bottom, 12)

                    Group {
                        switch selectedTab {
                        case .accounts:
                            accountsContent
                        case .posts:
                            postsContent
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showUserProfile) {
                if let uid = selectedUserId {
                    UserProfileView(
                        userId: uid,
                        initialDisplayName: selectedUserName,
                        initialAvatarUrl: selectedAvatarUrl
                    )
                }
            }
            .navigationDestination(isPresented: $showOfficialProfile) {
                OfficialProfileView()
            }
            .navigationDestination(item: $postDetailRequest) { req in
                FeedCardListView(
                    items: postResults,
                    recordsViews: true,   // タップ=詳細を開く行為なので閲覧計上する
                    startItemKey: req.startKey,
                    onLikeToggled: { item, isLiked in
                        // 検索結果リストにいいね数を反映する (実機FB第7弾: 反映されないバグ)
                        guard let idx = postResults.firstIndex(where: { $0.id == item.id }) else { return }
                        let old = postResults[idx]
                        postResults[idx] = FeedItem(
                            kind: old.kind,
                            itemId: old.itemId,
                            bodyJp: old.bodyJp,
                            bodyEn: old.bodyEn,
                            tags: old.tags,
                            likeCount: max(0, old.likeCount + (isLiked ? 1 : -1)),
                            commentCount: old.commentCount,
                            createdAt: old.createdAt,
                            authorId: old.authorId,
                            authorName: old.authorName,
                            authorAvatarUrl: old.authorAvatarUrl,
                            isOfficialAuthor: old.isOfficialAuthor,
                            isProAuthor: old.isProAuthor,
                            backgroundId: old.backgroundId,
                            title: old.title,
                            imagePath: old.imagePath,
                            imageCount: old.imageCount
                        )
                    }
                )
                // 検索→投稿詳細のヘッダーがステータスバー領域に食い込む見切れ修正 (実機FB第7弾)
                .navigationBarTitleDisplayMode(.inline)
            }
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onChange(of: selectedTab) { _, _ in
                scheduleSearch(query)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    // MARK: - Segment Bar
    // 2026-07-31 実機FB: 下線式の自前セグメントを廃止し、マイページの「投稿/いいね」と
    // まったく同じ OS 標準セグメント (iOS 26 ではガラス質感で描かれる) に統一。
    // MyProfileView.sectionPicker と同じ書き方・同じ水平パディング (20) を使う

    private var segmentBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(SearchTab.allCases) { tab in
                Text(tab == .posts ? SearchTabStrings.postsTab(lang)
                                   : SearchTabStrings.accountsTab(lang))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    // MARK: - Accounts Tab

    @ViewBuilder
    private var accountsContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if showOfficialRow {
                    officialRow
                }

                ForEach(userResults) { user in
                    userRow(user)
                }

                if isSearchingUsers {
                    ProgressView()
                        .tint(AppColors.textSecondary)
                        .padding(.top, 24)
                } else if showUsersEmptyState {
                    emptyStateView(
                        icon: "person.crop.circle.badge.questionmark",
                        text: SearchTabStrings.noAccountResults(lang)
                    )
                } else if trimmedQuery.isEmpty {
                    emptyStateView(
                        icon: "magnifyingglass",
                        text: SearchTabStrings.emptyPrompt(lang)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private var officialRow: some View {
        Button {
            showOfficialProfile = true
        } label: {
            HStack(spacing: 12) {
                OnePercentAvatar(size: 44)

                HStack(spacing: 6) {
                    Text(OnePercentAccount.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                }

                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))
        }
        .buttonStyle(.plain)
    }

    private func userRow(_ user: UserSearchResult) -> some View {
        Button {
            selectedUserId = user.id
            selectedUserName = user.displayName
            selectedAvatarUrl = user.avatarUrl
            showUserProfile = true
        } label: {
            HStack(spacing: 12) {
                AvatarImage(urlString: user.avatarUrl, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.displayName?.isEmpty == false ? user.displayName! : "—")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(1)
                        // 083: 検索結果だけ公式マークが出ていなかった (サーバーが返していなかった)
                        if user.isOfficial {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.blue)
                        }
                    }

                    if let handle = user.handle, !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Posts Tab

    @ViewBuilder
    private var postsContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(postResults) { item in
                    postRow(item)
                }

                if isSearchingPosts {
                    ProgressView()
                        .tint(AppColors.textSecondary)
                        .padding(.top, 24)
                } else if showPostsEmptyState {
                    emptyStateView(
                        icon: "text.magnifyingglass",
                        text: SearchTabStrings.noPostResults(lang)
                    )
                } else if trimmedQuery.isEmpty {
                    emptyStateView(
                        icon: "magnifyingglass",
                        text: SearchTabStrings.emptyPrompt(lang)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func postRow(_ item: FeedItem) -> some View {
        Button {
            postDetailRequest = PostDetailRequest(startKey: item.id)
        } label: {
            HStack(spacing: 12) {
                postThumbnail(item)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle?.isEmpty == false ? item.displayTitle! : item.displayPrimary(lang: lang, showOriginal: false))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let name = item.authorName, !name.isEmpty {
                            Text(name)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12))
                            Text("\(item.likeCount)")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(AppColors.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.cardBackground))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func postThumbnail(_ item: FeedItem) -> some View {
        if let url = item.imageUrl {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    postThumbnailPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            postThumbnailPlaceholder
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var postThumbnailPlaceholder: some View {
        ZStack {
            AppColors.secondaryBackground
            Image(systemName: "text.quote")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textTertiary)
        }
    }

    // MARK: - Empty State

    private func emptyStateView(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(AppColors.textTertiary)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.top, 60)
    }

    // MARK: - Search

    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeTab = selectedTab

        switch activeTab {
        case .accounts:
            guard trimmed.count >= 2 else {
                userResults = []
                isSearchingUsers = false
                return
            }
            isSearchingUsers = true
        case .posts:
            guard trimmed.count >= 1 else {
                postResults = []
                isSearchingPosts = false
                return
            }
            isSearchingPosts = true
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            switch activeTab {
            case .accounts:
                let fetched = await SearchService.shared.searchUsers(query: trimmed, limit: 30)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.userResults = fetched
                    self.isSearchingUsers = false
                }
            case .posts:
                let fetched = await SearchService.shared.searchPosts(query: trimmed, limit: 30)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.postResults = fetched
                    self.isSearchingPosts = false
                }
            }
        }
    }
}

// MARK: - Search Bar Field (旧アカウント検索画面と同じパターン。タブルートなので自動フォーカスはしない)

private struct SearchBarField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var isFocused: Bool

    // 2026-07-25 実機FB: 見た目をコメント入力バー (CommentInputBar) と同じ
    // ガラス質感カプセル (ultraThinMaterial + 薄い白ストローク) に統一。検索アイコンは左のまま
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(.white.opacity(0.55))
            )
                .font(.system(size: 16))
                .foregroundColor(.white)
                .focused($isFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        // 選択中の検索タブを再タップ → キーボードを開く (MainTabView から通知)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isFocused = true
        }
    }
}

// MARK: - Strings (このファイル限定。文言はユーザー添削待ち)

private enum SearchTabStrings {
    static func placeholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントや投稿を検索" : "Search accounts or posts"
    }

    static func accountsTab(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウント" : "Accounts"
    }

    static func postsTab(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Posts"
    }

    static func emptyPrompt(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントや投稿を検索" : "Search accounts or posts"
    }

    static func noAccountResults(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントが見つかりません" : "No accounts found"
    }

    static func noPostResults(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿が見つかりません" : "No posts found"
    }
}

#Preview {
    SearchView()
}
