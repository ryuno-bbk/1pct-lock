//
//  LocalizedStrings.swift
//  AppBlocker
//
//  AppLanguage に連動する全 UI 文字列を集約。
//  使い方: L.tabFeed(lang)
//

import Foundation

enum L {

    // MARK: - Tabs (MainTabView)

    static func tabFeed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フィード" : "Feed"
    }

    static func tabHome(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ホーム" : "Home"
    }

    static func tabTimer(_ lang: AppLanguage) -> String {
        // 3モード (タイマー/スケジュール/位置) を束ねる画面になったため「ロック」に改名 (2026-07-15 実機FB)
        lang == .japanese ? "ロック" : "Lock" // 文言はユーザー添削待ち
    }

    static func tabMyPage(_ lang: AppLanguage) -> String {
        lang == .japanese ? "マイページ" : "My Page"
    }

    static func tabPost(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Post"
    }

    static func tabSearch(_ lang: AppLanguage) -> String {
        lang == .japanese ? "検索" : "Search" // 文言はユーザー添削待ち
    }

    // MARK: - HomeView

    static func homeGreeting(_ lang: AppLanguage) -> String {
        lang == .japanese ? "おかえりなさい" : "Welcome back"
    }

    static func homeSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "集中を始めよう" : "Start focusing"
    }

    static func homeBlockMode(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロックモード" : "Block Mode"
    }

    static func homeBlockTime(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック時間" : "Block Duration"
    }

    static func homeSelectApps(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロックするアプリ" : "Apps to Block"
    }

    static func homeSelectAppsButton(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アプリを選択" : "Select Apps"
    }

    static func homeAppsSelected(_ appCount: Int, _ categoryCount: Int, _ lang: AppLanguage) -> String {
        lang == .japanese
            ? "\(appCount)個のアプリ、\(categoryCount)カテゴリ選択中"
            : "\(appCount) apps, \(categoryCount) categories selected"
    }

    static func homeStartBlock(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック開始" : "Start Blocking"
    }

    static func homeBlockTimeMinutes(_ lang: AppLanguage) -> String {
        lang == .japanese ? "分" : "min"
    }

    static func homeBlockTimeSliderMin(_ lang: AppLanguage) -> String {
        lang == .japanese ? "5分" : "5 min"
    }

    static func homeBlockTimeSliderMax(_ lang: AppLanguage) -> String {
        lang == .japanese ? "3時間" : "3 hours"
    }

    static func homeTimerBlock(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タイマーブロック" : "Timer Block"
    }

    static func homeRemainingTime(_ lang: AppLanguage) -> String {
        lang == .japanese ? "残り時間" : "Remaining"
    }

    static func homeStopTimer(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タイマーを停止" : "Stop Timer"
    }

    // MARK: - HomeView (Shield hint / ロック源バッジ / 継続ロックトースト)

    static func homeShieldFirstRunHint(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "初回はロック画面の表示に数秒かかることがあります(iOSの仕様です)"
            : "The block screen may take a few seconds to appear at first (an iOS limitation)."
    }

    static func homeBadgeTimer(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タイマー" : "Timer"
    }

    static func homeBadgeSchedule(_ lang: AppLanguage) -> String {
        lang == .japanese ? "スケジュール" : "Schedule"
    }

    static func homeBadgeLocation(_ lang: AppLanguage) -> String {
        lang == .japanese ? "位置情報" : "Location"
    }

    static func homeStillLockedSchedule(_ lang: AppLanguage) -> String {
        lang == .japanese ? "スケジュールで引き続きロック中です" : "Still locked by your schedule"
    }

    static func homeStillLockedLocation(_ lang: AppLanguage) -> String {
        lang == .japanese ? "指定場所にいる間はロック中です" : "Still locked while at this location"
    }

    // MARK: - SessionCompleteView

    static func sessionCompleteAchievedLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "集中を守った時間" : "Time you protected your focus"
    }

    static func sessionCompleteTotalLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "累計ロック時間" : "Total lock time"
    }

    static func sessionCompleteStreakLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ストリーク" : "Streak"
    }

    /// ストリークの値表示 (例: "N日連続" / "N-day streak")
    static func sessionCompleteStreakValue(_ days: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(days)日連続" : "\(days)-day streak"
    }

    static func sessionCompleteDone(_ lang: AppLanguage) -> String {
        lang == .japanese ? "完了" : "Done"
    }

    // MARK: - BlockMode

    static func blockModeDisplayName(_ mode: BlockMode, _ lang: AppLanguage) -> String {
        switch mode {
        case .timer:
            return lang == .japanese ? "タイマーブロック" : "Timer Block"
        case .schedule:
            return lang == .japanese ? "スケジュール制限" : "Schedule"
        case .location:
            return lang == .japanese ? "位置情報ロック" : "Location Lock"
        }
    }

    static func blockModeDescription(_ mode: BlockMode, _ lang: AppLanguage) -> String {
        switch mode {
        case .timer:
            return lang == .japanese ? "指定した時間だけブロック" : "Block for a set duration"
        case .schedule:
            return lang == .japanese ? "指定した時間帯に自動ブロック" : "Auto-block during set hours"
        case .location:
            return lang == .japanese ? "特定の場所で自動ブロック" : "Auto-block at specific locations"
        }
    }

    static func blockModeDetail(_ mode: BlockMode, _ lang: AppLanguage) -> String {
        switch mode {
        case .timer:
            return lang == .japanese
                ? "設定した時間が経過するまでアプリをブロック。時間が来たら自動で解除されます。"
                : "Block apps until the timer runs out. Automatically unlocks when time is up."
        case .schedule:
            return lang == .japanese
                ? "毎日決まった時間帯にアプリを自動ブロック。仕事中や就寝前など、集中したい時間を設定できます。"
                : "Automatically block apps during set hours every day. Perfect for work or bedtime."
        case .location:
            return lang == .japanese
                ? "カフェや職場など、特定の場所に入ると自動でアプリをブロック。場所を離れると解除されます。"
                : "Automatically block apps when you enter a specific place. Unlocks when you leave."
        }
    }

    // MARK: - ScheduleBlockView (L14: 最小長バリデーション)

    static func scheduleTooShort(_ minMinutes: Int, _ lang: AppLanguage) -> String {
        lang == .japanese
            ? "ブロック時間は最低\(minMinutes)分以上にしてください" // 文言はユーザー添削待ち
            : "Schedule must be at least \(minMinutes) minutes long" // 文言はユーザー添削待ち
    }

    // MARK: - Settings (SettingsListView)

    static func settingsTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "設定" : "Settings"
    }

    static func settingsSectionDisplay(_ lang: AppLanguage) -> String {
        lang == .japanese ? "表示" : "Display"
    }

    static func settingsLanguage(_ lang: AppLanguage) -> String {
        lang == .japanese ? "言語 / Language" : "Language"
    }

    static func settingsShowOriginal(_ lang: AppLanguage) -> String {
        lang == .japanese ? "英語の原文を併記" : "Show original English text"
    }

    static func settingsBackground(_ lang: AppLanguage) -> String {
        lang == .japanese ? "背景デザイン" : "Background Design"
    }

    static func settingsBackgroundComingSoon(_ lang: AppLanguage) -> String {
        lang == .japanese ? "背景デザイン設定は準備中です" : "Background design settings coming soon"
    }

    static func settingsSectionContent(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コンテンツ" : "Content"
    }

    static func settingsAuthorIcon(_ lang: AppLanguage) -> String {
        lang == .japanese ? "著者アイコン" : "Author Icons"
    }

    static func settingsAuthorIconComingSoon(_ lang: AppLanguage) -> String {
        lang == .japanese ? "著者アイコン設定は準備中です" : "Author icon settings coming soon"
    }

    static func settingsSectionAbout(_ lang: AppLanguage) -> String {
        lang == .japanese ? "このアプリ" : "About"
    }

    static func settingsVersion(_ lang: AppLanguage) -> String {
        lang == .japanese ? "バージョン" : "Version"
    }

    static func settingsFeedback(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フィードバックを送る" : "Send Feedback"
    }

    static func settingsFeedbackComingSoon(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フィードバック送信は準備中です" : "Feedback feature coming soon"
    }

    static func settingsComingSoon(_ lang: AppLanguage) -> String {
        lang == .japanese ? "準備中" : "Coming Soon"
    }

    static func settingsSectionAccount(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウント" : "Account"
    }

    static func settingsSignOut(_ lang: AppLanguage) -> String {
        lang == .japanese ? "サインアウト" : "Sign Out"
    }

    static func settingsSignOutConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "サインアウトしますか？" : "Sign out?"
    }

    static func settingsSignOutConfirmMessage(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "再度サインインするまでいいねやフォローなど一部の機能が利用できません"
            : "Likes, follows, and other account features will be unavailable until you sign in again."
    }

    static func settingsSignOutCancel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "キャンセル" : "Cancel"
    }

    // MARK: - MyProfileView

    static func profileTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "マイページ" : "My Page"
    }

    static func profileYou(_ lang: AppLanguage) -> String {
        lang == .japanese ? "あなた" : "You"
    }

    static func profileLikes(_ lang: AppLanguage) -> String {
        lang == .japanese ? "いいね" : "Likes"
    }

    static func profileFollowing(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フォロー中" : "Following"
    }

    static func profileLockTime(_ lang: AppLanguage) -> String {
        lang == .japanese ? "累計ロック" : "Locked"
    }

    static func profileTopPercent(_ lang: AppLanguage) -> String {
        lang == .japanese ? "上位%" : "Top %"
    }

    /// 上位%の値表示 (データ不足時は呼び出し側で "—" を使う)
    static func profileTopPercentValue(_ percent: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "上位\(percent)%" : "Top \(percent)%"
    }

    static func profileStreak(_ lang: AppLanguage) -> String {
        lang == .japanese ? "連続日数" : "Streak"
    }

    /// 連続ロック日数の値表示 (0日も表示)
    static func profileStreakValue(_ days: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(days)日" : "\(days)d"
    }

    // MARK: - 統計パック (完遂率、2026-07-16)

    /// 完遂率チップのラベル (直近30日・タイマーのみ)
    static func profileCompletionLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "完遂率・30日" : "Completion · 30d" // 文言はユーザー添削待ち
    }

    /// 完遂率の値表示 (データ不足時は呼び出し側で "—" を使う)
    static func profileCompletionValue(_ percent: Int, _ lang: AppLanguage) -> String {
        "\(percent)%" // 文言はユーザー添削待ち
    }

    // MARK: - 統計セルの詳細説明シート (2026-07-17)

    static func statInfoTotalTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "累計ロック" : "Total locked" // 文言はユーザー添削待ち
    }

    static func statInfoTotalDesc(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "これまでにロックした時間の合計です。タイマー・スケジュール・位置情報の全モードを合算しています。" // 文言はユーザー添削待ち
            : "Total time you've locked so far, across timer, schedule, and location modes."
    }

    static func statInfoStreakTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "連続日数" : "Streak" // 文言はユーザー添削待ち
    }

    static func statInfoStreakDesc(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "その日に1回でもロックした日が連続している日数です。今日まだロックしていなくても、昨日までの連続は途切れません。" // 文言はユーザー添削待ち
            : "Consecutive days with at least one lock. Yesterday's streak stays alive until today ends."
    }

    static func statInfoCompletionTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "完遂率" : "Completion rate" // 文言はユーザー添削待ち
    }

    static func statInfoCompletionDesc(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "開始したタイマーロックを途中で終了せず最後まで完遂した割合です。10分以上のタイマーだけが対象で、スケジュール・位置情報ロックは含まれません。" // 文言はユーザー添削待ち
            : "How often you finish the timer locks you start. Only timers of 10 minutes or longer count; schedule and location locks are excluded."
    }

    static func statInfoTopPercentTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "上位%" : "Top %" // 文言はユーザー添削待ち
    }

    static func statInfoTopPercentDesc(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "累計ロック時間の、全ユーザーの中での順位です。" // 文言はユーザー添削待ち
            : "Your rank among all users by total locked time."
    }

    /// 詳細シートの数値行ラベル: 直近30日
    static func statInfoLast30(_ lang: AppLanguage) -> String {
        lang == .japanese ? "直近30日" : "Last 30 days" // 文言はユーザー添削待ち
    }

    /// 詳細シートの数値行ラベル: 全期間
    static func statInfoAllTime(_ lang: AppLanguage) -> String {
        lang == .japanese ? "全期間" : "All time" // 文言はユーザー添削待ち
    }

    /// 詳細シートの数値行ラベル: 順位
    static func statInfoRank(_ lang: AppLanguage) -> String {
        lang == .japanese ? "順位" : "Rank" // 文言はユーザー添削待ち
    }

    /// 完遂率の詳細行の値 (例: "92% (12/13回)")
    static func statInfoCompletionRow(_ percent: Int, _ done: Int, _ total: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(percent)% (\(done)/\(total)回)" : "\(percent)% (\(done)/\(total))" // 文言はユーザー添削待ち
    }

    /// 順位の詳細行の値 (例: "3位 / 128人中")
    static func statInfoRankRow(_ rank: Int, _ total: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(rank)位 / \(total)人中" : "#\(rank) of \(total)" // 文言はユーザー添削待ち
    }

    // MARK: - 統計シート v2 (2026-07-30 実機FB「説明が足りない」)

    /// 統計シートの完遂率行ラベル (直近30日)。
    /// 2026-07-31 実機FB「何の完遂率か分からない」→「ロック完遂率」に
    static func statSheetCompletion30(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ロック完遂率 (直近30日)" : "Lock completion (last 30 days)" // 文言はユーザー添削待ち
    }

    /// 統計シートの完遂率行ラベル (全期間)
    static func statSheetCompletionAll(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ロック完遂率 (全期間)" : "Lock completion (all time)" // 文言はユーザー添削待ち
    }

    /// セッション終了確認での完遂率への影響の告知 (2026-07-31 実機FB:
    /// 「知らないうちに完遂率が下がっていた」というUXを避ける)。
    /// 予定10分以上のタイマーだけが完遂率の対象なので、呼び出し側で条件を絞ること
    static func stopConfirmCompletionWarning(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "ここでやめると、ロック完遂率が下がります" // 文言はユーザー添削待ち
            : "Quitting now will lower your lock completion rate"
    }

    /// 統計シート (上位%フォーカス) の最上部見出し。「上位3%って何が?」に答える説明を
    /// ヒーローの上に置く (2026-07-30 実機FB: 下のキャプションでなく一番上に書く)
    static func statSheetTopPercentHeader(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "全ユーザーの中での累計ロック時間の順位" // 文言はユーザー添削待ち
            : "Total lock time rank among all users"
    }

    // 🔴 2026-08-08: 旧・名言SNS期の残骸「いいねした名言がありません」を撤去。
    // 同日、いいねタブが投稿も出すようになったので「投稿」で言い切ってよい
    static func profileNoLikes(_ lang: AppLanguage) -> String {
        lang == .japanese ? "いいねした投稿がありません" : "No liked posts yet"
    }

    static func profileNoLikesSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿にいいねするとここに表示されます" : "Posts you like will appear here"
    }

    static func profileUnlike(_ lang: AppLanguage) -> String {
        lang == .japanese ? "いいね解除" : "Unlike"
    }

    // 「偉人」表記は旧・名言SNS期の残骸 (2026-07-30 実機FBで発見→中立な文言へ)
    static func profileNoFollows(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだ誰もフォローしていません" : "Not following anyone yet"
    }

    static func profileNoFollowsSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントをフォローするとここに表示されます" : "Accounts you follow will appear here"
    }

    static func profileUnfollow(_ lang: AppLanguage) -> String {
        lang == .japanese ? "解除" : "Unfollow"
    }

    // MARK: - AuthorProfileView

    // 🔴 2026-08-08: 「名言」→「投稿」。旧・名言SNS期の残骸。
    // 呼び出し元は UserProfileView (他人のプロフィール) / OfficialProfileView (公式アカウント) /
    // AuthorProfileView (フロー除外・残置)。公式が出しているのも画面上は投稿なので投稿で統一する
    static func authorQuotes(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Posts"
    }

    static func authorFollowers(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フォロワー" : "Followers"
    }

    static func authorFollowButton(_ isFollowing: Bool, _ lang: AppLanguage) -> String {
        if isFollowing {
            return lang == .japanese ? "フォロー中" : "Following"
        } else {
            return lang == .japanese ? "フォローする" : "Follow"
        }
    }

    static func authorFollowShort(_ isFollowing: Bool, _ lang: AppLanguage) -> String {
        if isFollowing {
            return lang == .japanese ? "フォロー中" : "Following"
        } else {
            return lang == .japanese ? "フォロー" : "Follow"
        }
    }

    static func authorNoQuotes(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿がありません" : "No posts yet"  // 2026-08-08: 「名言」から変更
    }

    static func authorShowMore(_ lang: AppLanguage) -> String {
        lang == .japanese ? "もっと見る" : "Show more"
    }

    static func authorShowLess(_ lang: AppLanguage) -> String {
        lang == .japanese ? "閉じる" : "Show less"
    }

    // MARK: - Feed

    static func feedLoading(_ lang: AppLanguage) -> String {
        lang == .japanese ? "読み込み中..." : "Loading..."
    }

    /// おすすめ/タグ別フィードが空のとき (フィードは投稿主体になったため「名言」とは言わない)
    static func feedPostsEmpty(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだ投稿がありません" : "No posts yet"
    }

    static func feedRecommended(_ lang: AppLanguage) -> String {
        lang == .japanese ? "おすすめ" : "For You"
    }

    static func feedFollowing(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フォロー中" : "Following"
    }

    static func feedFollowingEmpty(_ lang: AppLanguage) -> String {
        lang == .japanese ? "フォロー中の投稿はまだありません" : "No posts from people you follow yet"
    }

    static func feedFollowingEmptySubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "気になる人をフォローしてみよう" : "Follow people whose posts you want to see"
    }

    /// FeedCardListView 共通の空状態 (いいね一覧の最後の1件を解除した時など)
    static func feedEmptyGeneric(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだ何もありません" : "Nothing here yet"
    }

    /// カード下部の「N件のコメントをすべて表示」(FeedListCard)
    static func feedCommentsViewAll(_ count: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(count)件のコメントをすべて表示" : "View all \(count) comments"
    }

    /// 公式チェックマークバッジの VoiceOver ラベル (FeedListCard / ProfileHero)
    static func feedOfficialBadgeLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "公式" : "Official"
    }

    /// いいねした人一覧シート (LikersSheet): まだいいねがない時
    static func feedLikersEmpty(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだいいねがありません" : "No likes yet"
    }

    // MARK: - Posts (UGC)

    static func postsTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Posts"
    }

    static func postsCreate(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿する" : "Post"
    }

    static func postsComposerTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "新規投稿" : "New Post"
    }

    static func postsComposerPlaceholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "今、心に響いた言葉は？" : "What's on your mind?"
    }

    static func postsComposerTags(_ lang: AppLanguage) -> String {
        lang == .japanese ? "タグ (最大3個)" : "Tags (up to 3)"
    }

    static func postsComposerSubmit(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Post"
    }

    static func postsComposerCancel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "キャンセル" : "Cancel"
    }

    static func postsComposerNext(_ lang: AppLanguage) -> String {
        lang == .japanese ? "続ける" : "Continue"
    }

    static func postsComposerBackgroundTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "背景を選ぶ" : "Choose background"
    }

    static func postsComposerBack(_ lang: AppLanguage) -> String {
        lang == .japanese ? "戻る" : "Back"
    }

    static func postsComposerCharCount(_ current: Int, _ max: Int) -> String {
        "\(current) / \(max)"
    }

    static func postsMy(_ lang: AppLanguage) -> String {
        lang == .japanese ? "自分の投稿" : "My Posts"
    }

    static func postsNone(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだ投稿がありません" : "No posts yet"
    }

    static func postsNoneSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "「+」をタップして最初の投稿をしよう" : "Tap + to create your first post"
    }

    static func postsDelete(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿を削除" : "Delete Post"
    }

    static func postsDeleteConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "この投稿を削除しますか？" : "Delete this post?"
    }

    static func postsDeleteConfirmMessage(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除すると元に戻せません" : "This cannot be undone"
    }

    static func postsDeleteAction(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除する" : "Delete"
    }

    /// AI モデレーション (027 SQL): rejected (層1安全性NG) の投稿に本人の投稿一覧でのみ表示するバッジ。
    /// flagged (層2エトスNG/shadow) は何も表示しない (シャドウの意味を保つ、design doc 参照)
    static func postsModerationRejectedBadge(_ lang: AppLanguage) -> String {
        lang == .japanese ? "審査により非公開" : "Hidden after review"
    }

    // MARK: - UserProfile (一般ユーザー)

    static func userProfilePosts(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿" : "Posts"
    }

    static func userProfileSignInRequired(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿するにはサインインが必要です" : "Sign in to post"
    }

    // MARK: - Moderation (Report / Block / Account Deletion)

    static func moderationReport(_ lang: AppLanguage) -> String {
        lang == .japanese ? "通報" : "Report"
    }

    static func moderationBlock(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック" : "Block"
    }

    static func moderationUnblock(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック解除" : "Unblock"
    }

    static func moderationReportTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "投稿を通報" : "Report Post"
    }

    static func moderationReportReason(_ lang: AppLanguage) -> String {
        lang == .japanese ? "理由を選択" : "Reason"
    }

    static func moderationReportDetail(_ lang: AppLanguage) -> String {
        lang == .japanese ? "詳細 (任意)" : "Details (optional)"
    }

    static func moderationReportSubmit(_ lang: AppLanguage) -> String {
        lang == .japanese ? "送信" : "Submit"
    }

    static func moderationReportCancel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "キャンセル" : "Cancel"
    }

    static func moderationReportThanks(_ lang: AppLanguage) -> String {
        lang == .japanese ? "通報を受け付けました" : "Report submitted"
    }

    static func moderationReportReasonSpam(_ lang: AppLanguage) -> String {
        lang == .japanese ? "スパム" : "Spam"
    }

    static func moderationReportReasonHarassment(_ lang: AppLanguage) -> String {
        lang == .japanese ? "嫌がらせ" : "Harassment"
    }

    static func moderationReportReasonHate(_ lang: AppLanguage) -> String {
        lang == .japanese ? "差別・ヘイト" : "Hate speech"
    }

    static func moderationReportReasonNudity(_ lang: AppLanguage) -> String {
        lang == .japanese ? "わいせつ" : "Nudity / sexual"
    }

    static func moderationReportReasonViolence(_ lang: AppLanguage) -> String {
        lang == .japanese ? "暴力・危険" : "Violence / danger"
    }

    static func moderationReportReasonOther(_ lang: AppLanguage) -> String {
        lang == .japanese ? "その他" : "Other"
    }

    /// 067 #9: エトス専用の通報理由。文言はユーザー添削待ち (設計書 追補 #9 の指定文言をそのまま使用)
    static func moderationReportReasonOffTopic(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アプリの趣旨に合わない" : "Doesn't fit this app"  // 文言はユーザー添削待ち
    }

    static func moderationBlockConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "このユーザーをブロックしますか？" : "Block this user?"
    }

    static func moderationBlockConfirmMessage(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "相手の投稿があなたのフィードに表示されなくなります。お互いのフォロー関係も解除されます。"
            : "Their posts will no longer appear in your feed. Any follow relationships will be removed."
    }

    static func moderationBlockedListTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック中のユーザー" : "Blocked Users"
    }

    static func moderationBlockedListEmpty(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック中のユーザーはいません" : "No blocked users"
    }

    static func settingsBlockedAccounts(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック中のユーザー" : "Blocked Users"
    }

    static func settingsEditProfile(_ lang: AppLanguage) -> String {
        lang == .japanese ? "プロフィールを編集" : "Edit Profile"
    }

    static func settingsDeleteAccount(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントを削除" : "Delete Account"
    }

    static func settingsDeleteAccountConfirm1Title(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アカウントを削除しますか？" : "Delete account?"
    }

    static func settingsDeleteAccountConfirm1Message(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "投稿・いいね・フォロー関係・累計ロック時間など、すべてのデータが削除されます。"
            : "All your data — posts, likes, follows, and total lock time — will be permanently deleted."
    }

    static func settingsDeleteAccountConfirm2Title(_ lang: AppLanguage) -> String {
        lang == .japanese ? "本当に削除しますか？" : "Are you sure?"
    }

    static func settingsDeleteAccountConfirm2Message(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "この操作は取り消せません。"
            : "This action cannot be undone."
    }

    static func settingsDeleteAccountAction(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除する" : "Delete"
    }

    static func settingsDeleteAccountFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除に失敗しました" : "Failed to delete account"
    }

    // MARK: - Feed Item Menu

    static func feedMenuShare(_ lang: AppLanguage) -> String {
        lang == .japanese ? "共有" : "Share"
    }

    static func feedMenuDownload(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像を保存" : "Save Image"
    }

    static func feedMenuDownloadSuccess(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像を保存しました" : "Saved to Photos"
    }

    static func feedMenuDownloadFailedTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "保存に失敗しました" : "Failed to save"
    }

    static func feedMenuDownloadPermissionMessage(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "写真への追加権限がありません。設定から「写真」のアクセスを許可してください。"
            : "Photo access permission is required. Please allow it in Settings."
    }

    static func feedMenuDownloadGenericMessage(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "画像の保存中にエラーが発生しました。時間をおいて再度お試しください。"
            : "An error occurred while saving the image. Please try again."
    }

    static func feedMenuOpenSettings(_ lang: AppLanguage) -> String {
        lang == .japanese ? "設定を開く" : "Open Settings"
    }

    static func feedMenuAddWidget(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ウィジェットに追加" : "Add to Widget"
    }

    static func feedMenuAddWidgetInstructionTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ウィジェットの追加方法" : "How to add the widget"
    }

    static func feedMenuAddWidgetInstructionMessage(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "1% アプリのアイコンを長押し → 表示されたウィジェットのアイコンをタップ → 好きなサイズを追加してください。"
            : "Touch and hold the 1% app icon, tap the widget icon that appears, then pick a size."
    }

    // MARK: - Onboarding (Name Input)

    static func onboardingNameTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "あなたの名前を教えてください" : "What should we call you?"
    }

    static func onboardingNameSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "投稿やプロフィールに表示されます。後から変更できます。"
            : "Shown on your posts and profile. You can change it later."
    }

    static func onboardingNamePlaceholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "名前を入力" : "Enter your name"
    }

    static func onboardingNameNext(_ lang: AppLanguage) -> String {
        lang == .japanese ? "次へ" : "Next"
    }

    // MARK: - Profile Edit

    static func profileEditTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "プロフィールを編集" : "Edit Profile"
    }

    static func profileEditDisplayNameLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "表示名" : "Display Name"
    }

    static func profileEditDisplayNamePlaceholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "名前" : "Name"
    }

    static func profileEditAvatarLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "プロフィール画像" : "Profile Picture"
    }

    static func profileEditAvatarChange(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像を変更" : "Change Photo"
    }

    static func profileEditAvatarRemove(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像を削除" : "Remove Photo"
    }

    static func profileEditSave(_ lang: AppLanguage) -> String {
        lang == .japanese ? "保存" : "Save"
    }

    static func profileEditCancel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "キャンセル" : "Cancel"
    }

    static func profileEditSaving(_ lang: AppLanguage) -> String {
        lang == .japanese ? "保存中..." : "Saving..."
    }

    static func profileEditUploading(_ lang: AppLanguage) -> String {
        lang == .japanese ? "アップロード中..." : "Uploading..."
    }

    static func profileEditSaveFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "保存に失敗しました" : "Failed to save"
    }

    static func profileEditAvatarUploadFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像のアップロードに失敗しました" : "Failed to upload photo"
    }

    static func profileEditAvatarRemoveFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "画像の削除に失敗しました" : "Failed to remove photo"
    }

    static func profileEditNameTooLong(_ lang: AppLanguage) -> String {
        lang == .japanese ? "名前は30文字以内で入力してください" : "Please use 30 characters or fewer"
    }

    static func profileEditNameEmpty(_ lang: AppLanguage) -> String {
        lang == .japanese ? "名前を入力してください" : "Please enter a name"
    }

    static func profileEditNameCharCount(_ current: Int) -> String {
        "\(current) / 30"
    }

    // MARK: - Comments

    static func commentsTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コメント" : "Comments"
    }

    static func commentsCountLabel(_ count: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(count) 件のコメント" : "\(count) comments"
    }

    static func commentsNone(_ lang: AppLanguage) -> String {
        lang == .japanese ? "まだコメントはありません" : "No comments yet"
    }

    static func commentsNoneSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "最初のコメントを残そう" : "Be the first to comment"
    }

    static func commentsPlaceholder(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コメントを追加..." : "Add a comment..."
    }

    static func commentsReplyPlaceholder(_ name: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "@\(name) に返信..." : "Reply to @\(name)..."
    }

    static func commentsReply(_ lang: AppLanguage) -> String {
        lang == .japanese ? "返信" : "Reply"
    }

    static func commentsReplyingTo(_ name: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "@\(name) への返信" : "Replying to @\(name)"
    }

    static func commentsSend(_ lang: AppLanguage) -> String {
        lang == .japanese ? "送信" : "Send"
    }

    static func commentsCharCount(_ current: Int) -> String {
        "\(current) / 500"
    }

    static func commentsDelete(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除" : "Delete"
    }

    static func commentsDeleteConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "このコメントを削除しますか？" : "Delete this comment?"
    }

    static func commentsDeleteConfirmMessage(_ lang: AppLanguage) -> String {
        lang == .japanese ? "削除すると元に戻せません" : "This cannot be undone"
    }

    static func commentsDeleteAll(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コメントを全削除" : "Delete All Comments"
    }

    static func commentsDeleteAllConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コメントを全削除しますか？" : "Delete all comments?"
    }

    static func commentsDeleteAllConfirmMessage(_ lang: AppLanguage) -> String {
        lang == .japanese ? "この投稿に付いた全てのコメントが削除されます。元に戻せません。" : "All comments on this post will be permanently deleted."
    }

    static func commentsLoginRequired(_ lang: AppLanguage) -> String {
        lang == .japanese ? "コメントするにはサインインが必要です" : "Sign in to comment"
    }

    static func commentsCancelReply(_ lang: AppLanguage) -> String {
        lang == .japanese ? "返信をキャンセル" : "Cancel reply"
    }

    // MARK: - Time formatting (相対時間: 通知 / コメント表示用)

    static func timeJustNow(_ lang: AppLanguage) -> String {
        lang == .japanese ? "たった今" : "just now"
    }

    static func timeMinutesAgo(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(n)分前" : "\(n)m"
    }

    static func timeHoursAgo(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(n)時間前" : "\(n)h"
    }

    static func timeDaysAgo(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(n)日前" : "\(n)d"
    }

    static func timeWeeksAgo(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(n)週間前" : "\(n)w"
    }

    // MARK: - Notifications

    static func notificationsTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "通知" : "Notifications"
    }

    static func notificationsNone(_ lang: AppLanguage) -> String {
        lang == .japanese ? "通知はまだありません" : "No notifications yet"
    }

    static func notificationsNoneSubtitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "いいねやフォロー、コメントがあると表示されます" : "You'll see likes, follows, and comments here"
    }

    static func notificationLikeMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんがあなたの投稿にいいねしました" : "\(actor) liked your post"
    }

    static func notificationFollowMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんがフォローしました" : "\(actor) started following you"
    }

    static func notificationCommentMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんがコメントしました" : "\(actor) commented on your post"
    }

    static func notificationReplyMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんが返信しました" : "\(actor) replied to your comment"
    }

    static func notificationCommentLikeMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんがあなたのコメントにいいねしました" : "\(actor) liked your comment"
    }

    static func notificationNewPostMessage(_ actor: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "\(actor) さんが投稿しました" : "\(actor) shared a new post"
    }

    static func notificationsAnonymous(_ lang: AppLanguage) -> String {
        lang == .japanese ? "誰か" : "Someone"
    }

    // MARK: - Feed Item Menu

    static func feedMenuShareText(_ item: FeedItem, _ lang: AppLanguage, _ showOriginal: Bool) -> String {
        var text = "\"\(item.displayPrimary(lang: lang, showOriginal: showOriginal))\""
        if let secondary = item.displaySecondary(lang: lang, showOriginal: showOriginal) {
            text += "\n\(secondary)"
        }
        if let name = item.authorName, !Quote.isAnonymousAuthor(name) {
            text += "\n— \(name)"
        }
        return text
    }

    // MARK: - Block Views (Schedule / Location) — 監査 copy high 2件対応 (2026-07-22)

    static func scheduleSectionLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "スケジュール" : "Schedules" // 文言はユーザー添削待ち
    }

    static func scheduleTimeSectionLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ブロック時間" : "Block hours" // 文言はユーザー添削待ち
    }

    static func scheduleRepeatSectionLabel(_ lang: AppLanguage) -> String {
        lang == .japanese ? "繰り返し" : "Repeat" // 文言はユーザー添削待ち
    }

    /// 曜日ボタン用の1文字ラベル (1=日〜7=土)
    static func weekdayInitial(_ weekday: Int, _ lang: AppLanguage) -> String {
        // 文言はユーザー添削待ち
        switch weekday {
        case 1: return lang == .japanese ? "日" : "S"
        case 2: return lang == .japanese ? "月" : "M"
        case 3: return lang == .japanese ? "火" : "T"
        case 4: return lang == .japanese ? "水" : "W"
        case 5: return lang == .japanese ? "木" : "T"
        case 6: return lang == .japanese ? "金" : "F"
        case 7: return lang == .japanese ? "土" : "S"
        default: return ""
        }
    }

    /// サマリー表示用の短縮曜日名 (1=日〜7=土)
    static func weekdayShortName(_ weekday: Int, _ lang: AppLanguage) -> String {
        // 文言はユーザー添削待ち
        switch weekday {
        case 1: return lang == .japanese ? "日" : "Sun"
        case 2: return lang == .japanese ? "月" : "Mon"
        case 3: return lang == .japanese ? "火" : "Tue"
        case 4: return lang == .japanese ? "水" : "Wed"
        case 5: return lang == .japanese ? "木" : "Thu"
        case 6: return lang == .japanese ? "金" : "Fri"
        case 7: return lang == .japanese ? "土" : "Sat"
        default: return ""
        }
    }

    static func weekdaySummaryWeekdays(_ lang: AppLanguage) -> String {
        lang == .japanese ? "平日" : "Weekdays" // 文言はユーザー添削待ち
    }

    static func weekdaySummaryEveryday(_ lang: AppLanguage) -> String {
        lang == .japanese ? "毎日" : "Every day" // 文言はユーザー添削待ち
    }

    static func weekdaySummaryWeekend(_ lang: AppLanguage) -> String {
        lang == .japanese ? "週末" : "Weekends" // 文言はユーザー添削待ち
    }

    /// カスタム曜日サマリー (例: "日・水・金" / "Sun, Wed, Fri") の区切り文字
    static func weekdaySummarySeparator(_ lang: AppLanguage) -> String {
        lang == .japanese ? "・" : ", " // 文言はユーザー添削待ち
    }

    static func timeEditStart(_ lang: AppLanguage) -> String {
        lang == .japanese ? "開始時刻" : "Start time" // 文言はユーザー添削待ち
    }

    static func timeEditEnd(_ lang: AppLanguage) -> String {
        lang == .japanese ? "終了時刻" : "End time" // 文言はユーザー添削待ち
    }

    static func timeEditDone(_ lang: AppLanguage) -> String {
        lang == .japanese ? "完了" : "Done" // 文言はユーザー添削待ち
    }

    static func locationPermissionTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "位置情報の権限が必要です" : "Location access needed" // 文言はユーザー添削待ち
    }

    static func locationPermissionBody(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "バックグラウンドでも位置情報を取得するため、「常に許可」を選択してください" // 文言はユーザー添削待ち
            : "Choose \"Always Allow\" so location works in the background" // 文言はユーザー添削待ち
    }

    static func locationPermissionAllow(_ lang: AppLanguage) -> String {
        lang == .japanese ? "位置情報を許可" : "Allow location access" // 文言はユーザー添削待ち
    }

    static func locationPermissionOpenSettings(_ lang: AppLanguage) -> String {
        lang == .japanese ? "設定アプリで許可する" : "Allow in Settings" // 文言はユーザー添削待ち
    }

    static func locationBgWarningTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "バックグラウンドで動作しません" : "Won't work in the background" // 文言はユーザー添削待ち
    }

    static func locationBgWarningBody(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "\"常に許可\" にしないとバックグラウンドで動作しません" // 文言はユーザー添削待ち
            : "Location must be set to \"Always Allow\" to work in the background" // 文言はユーザー添削待ち
    }

    static func locationBgWarningOpenSettings(_ lang: AppLanguage) -> String {
        lang == .japanese ? "設定アプリで\"常に許可\"にする" : "Set to \"Always Allow\" in Settings" // 文言はユーザー添削待ち
    }

    static func locationRegisteredSection(_ lang: AppLanguage) -> String {
        lang == .japanese ? "登録済みの場所" : "Saved places" // 文言はユーザー添削待ち
    }

    static func locationNoneRegistered(_ lang: AppLanguage) -> String {
        lang == .japanese ? "場所が登録されていません" : "No places saved yet" // 文言はユーザー添削待ち
    }

    static func locationRadiusText(_ meters: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "半径 \(meters)m" : "\(meters)m radius" // 文言はユーザー添削待ち
    }

    static func locationRadiusHereText(_ meters: Int, _ lang: AppLanguage) -> String {
        lang == .japanese ? "半径 \(meters)m ・ 現在ここ" : "\(meters)m radius ・ You're here" // 文言はユーザー添削待ち
    }

    static func locationDeleteTitle(_ lang: AppLanguage) -> String {
        lang == .japanese ? "場所を削除" : "Delete place" // 文言はユーザー添削待ち
    }

    static func locationDeleteConfirmMessage(_ name: String, _ lang: AppLanguage) -> String {
        lang == .japanese ? "「\(name)」を削除しますか？" : "Delete \"\(name)\"?" // 文言はユーザー添削待ち
    }

    /// B-4: iOS のジオフェンス同時監視上限に達した場合の注記
    static func locationLimitNote(_ lang: AppLanguage) -> String {
        lang == .japanese ? "iOS 制限で 20 箇所まで" : "Up to 20 places (iOS limit)" // 文言はユーザー添削待ち
    }

    /// FB#11: 無課金ロックカード下端の全幅タップ可アクセントストリップ
    static func blockLockedStripText(_ lang: AppLanguage) -> String {
        lang == .japanese ? "実行には 1% エリートが必要" : "1% Elite is required to run this" // 文言はユーザー添削待ち
    }

    static func blockLockedSeeElite(_ lang: AppLanguage) -> String {
        lang == .japanese ? "1% エリートを見る" : "See 1% Elite" // 文言はユーザー添削待ち
    }
}
