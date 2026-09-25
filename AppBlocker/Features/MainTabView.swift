//
//  MainTabView.swift
//  AppBlocker
//
//  メインタブバー（フィード / 検索 / ＋投稿 / タイマー / マイページ）
//  ＋はページではなく「アクションタブ」(TikTok/IG 式、2026-07-11 ユーザー確定):
//  選択された瞬間に元のタブへ戻し、投稿フロー (PostFlowView) をシートで開く。
//  検索タブは 2026-07-15 追加 (アカウント/投稿検索)。実ページは実質 4 つ。
//

import SwiftUI
// @Environment(\.requestReview) の実体 (RequestReviewAction) は StoreKit 側にあるため必須。
// import が無いと "callAsFunction() is not available due to missing import of defining
// module 'StoreKit'" でコンパイルが落ちる (2026-08-06)
import StoreKit

struct MainTabView: View {
    @State private var selectedTab: Tab = .feed
    @State private var showComposer = false
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    /// 評価依頼 (2026-08-06)。判断は ReviewPrompt が持つ。
    /// MainTabView はオンボ完了後にしか表示されないので、ここで数える限り
    /// 「初回起動時/オンボ中に聞く」(Guideline 5.6.3 違反) は構造的に起きない
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var reviewScenePhase
    /// プッシュ通知タップでマイページタブへ寄せるために監視する。
    /// 一覧を実際に開くのは MyProfileView 側 (タブが未生成でも取りこぼさないため)
    @ObservedObject private var pushService = PushNotificationService.shared
    @ObservedObject private var notifService = NotificationService.shared

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    enum Tab: Hashable {
        case feed
        case search
        case compose   // アクションタブ (ページなし)
        case home
        case settings
    }

    var body: some View {
        // 選択中のタブをもう一度タップした時の追加動作:
        //   検索 → 検索フィールドへフォーカス (2026-07-25 実機FB)
        //   フィード → 引っ張って更新と同じリロード (2026-08-04 ユーザー要望)
        // どちらも同値セットなので onChange では拾えない。カスタム Binding で検知する
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .search && selectedTab == .search {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
                if newValue == .feed && selectedTab == .feed {
                    NotificationCenter.default.post(name: .reloadFeedTab, object: nil)
                }
                selectedTab = newValue
            }
        )) {
            MixedFeedView()
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text(L.tabFeed(lang))
                }
                .tag(Tab.feed)

            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text(L.tabSearch(lang))
                }
                .tag(Tab.search)

            // ＋ 投稿 (ダミーページ。選択を検知したら即座に元のタブへ戻してシートを開く)
            Color.black.ignoresSafeArea()
                .tabItem {
                    Image(systemName: "plus.circle.fill")
                    Text(L.tabPost(lang))
                }
                .tag(Tab.compose)

            HomeView()
                .tabItem {
                    // 3モードを束ねる画面なのでタイマーの砂時計でなく錠アイコン (2026-07-15 実機FB)
                    Image(systemName: "lock.fill")
                    Text(L.tabTimer(lang))
                }
                .tag(Tab.home)

            MyProfileView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text(L.tabMyPage(lang))
                }
                // 未読通知の赤い数字をマイページのタブアイコンに出す。
                // 🔴 ナビバーのベルではなくタブバー側 (2026-08-28 ユーザー指摘)。
                //    タブを開かないと未読に気づけないのが元の問題なので、
                //    タブバーに出ていないと意味がない
                .badge(notifService.unreadCount)
                .tag(Tab.settings)
        }
        .tint(AppColors.accent)
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .compose {
                selectedTab = oldValue   // ページは切り替えない
                showComposer = true
            }
        }
        // プッシュ通知をタップして起動/復帰した。まずマイページタブへ寄せる。
        // 一覧を開くのは MyProfileView 側が同じフラグを見て行う
        // (タブがまだ生成されていない瞬間に post しても届かないため、
        //  フラグを立てたままにして受け手側に拾わせる)
        .onChange(of: pushService.shouldOpenNotificationList) { _, shouldOpen in
            if shouldOpen { selectedTab = .settings }
        }
        // 終了確認 (StopConfirmationView) の「ライバルの進捗を見る」からフィードタブへ飛ばす (2026-07-16)
        .onReceive(NotificationCenter.default.publisher(for: .switchToFeedTab)) { _ in
            selectedTab = .feed
        }
        .sheet(isPresented: $showComposer) {
            PostFlowView()
        }
        // 🔴 2026-08-06 (Guideline 5.6.3 リジェクト対応) の評価依頼・起動回数側。
        // スケジュール/位置ロックはバックグラウンドで完遂するため、その利用者は
        // 完遂画面 (SessionCompleteView) を一度も見ない。こちらが無いと永久に聞けない。
        // 発火条件は ReviewPrompt が持つ (完遂1回以上が前提)。
        // 前面に出た直後に被せると鬱陶しいので少し置いてから出す
        .onChange(of: reviewScenePhase) { _, phase in
            guard phase == .active else { return }
            ReviewPrompt.recordAppOpen()
            guard ReviewPrompt.shouldAskOnAppOpen() else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                requestReview()
            }
        }
        .onAppear {
            // タブバーのダーク背景
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(AppColors.background)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Cross-tab Navigation

extension Notification.Name {
    /// 他画面 (終了確認など) からフィードタブへ遷移させるためのクロスタブ通知。
    /// MainTabView.selectedTab はローカル @State のため、外部からは通知経由で切り替える
    static let switchToFeedTab = Notification.Name("switchToFeedTab")
    /// 選択中の検索タブを再タップ → SearchView の検索フィールドにフォーカス (2026-07-25)
    static let focusSearchField = Notification.Name("focusSearchField")
    /// 選択中のフィードタブを再タップ → 表示中セグメントを引っ張って更新と同じ内容で再取得 (2026-08-04)
    static let reloadFeedTab = Notification.Name("reloadFeedTab")
}

#Preview {
    MainTabView()
}
