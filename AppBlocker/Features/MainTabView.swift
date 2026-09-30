//
//  MainTabView.swift
//  AppBlocker
//
//  Main tab bar (Feed / Search / + Post / Timer / My page)
//  + is not a page but an "action tab" (TikTok/IG style, user decision 2026-07-11):
//  the moment it is selected, it switches back to the previous tab and opens the post flow
//  (PostFlowView) in a sheet.
//  The search tab was added 2026-07-15 (account/post search). In practice there are 4 real pages.
//

import SwiftUI
// Required because the implementation of @Environment(\.requestReview) (RequestReviewAction) is in
// StoreKit. Without the import, compilation fails with "callAsFunction() is not available due to
// missing import of defining module 'StoreKit'" (2026-08-06)
import StoreKit

struct MainTabView: View {
    @State private var selectedTab: Tab = .feed
    @State private var showComposer = false
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    /// Rating request (2026-08-06). ReviewPrompt owns the decision.
    /// MainTabView is shown only after onboarding finishes, so as long as counting happens here,
    /// "asking on first launch / during onboarding" (a Guideline 5.6.3 violation) cannot happen by
    /// structure
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var reviewScenePhase
    /// Observed so a push notification tap can switch to the My page tab.
    /// The list is actually opened by MyProfileView (so it is not missed even if the tab is not created
    /// yet)
    @ObservedObject private var pushService = PushNotificationService.shared
    @ObservedObject private var notifService = NotificationService.shared

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    enum Tab: Hashable {
        case feed
        case search
        case compose   // Action tab (no page)
        case home
        case settings
    }

    var body: some View {
        // Extra behavior when the already selected tab is tapped again:
        //   Search → focus the search field (2026-07-25 real device feedback)
        //   Feed → same reload as pull-to-refresh (2026-08-04 user request)
        // Both set the same value, so onChange cannot catch them. Detected with a custom Binding
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

            // + Post (dummy page. When selection is detected, switch back to the previous tab right away and
            // open the sheet)
            Color.black.ignoresSafeArea()
                .tabItem {
                    Image(systemName: "plus.circle.fill")
                    Text(L.tabPost(lang))
                }
                .tag(Tab.compose)

            HomeView()
                .tabItem {
                    // This screen groups the 3 modes, so it uses a lock icon instead of the timer hourglass (2026-07-15
                    // real device feedback)
                    Image(systemName: "lock.fill")
                    Text(L.tabTimer(lang))
                }
                .tag(Tab.home)

            MyProfileView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text(L.tabMyPage(lang))
                }
                // Show the red unread notification count on the My page tab icon.
                // 🔴 On the tab bar, not the bell in the nav bar (2026-08-28 user feedback).
                //    The original problem was that you cannot notice unread items without opening the tab, so
                //    it is pointless unless it shows on the tab bar
                .badge(notifService.unreadCount)
                .tag(Tab.settings)
        }
        .tint(AppColors.accent)
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .compose {
                selectedTab = oldValue   // Do not switch the page
                showComposer = true
            }
        }
        // Launched/resumed by tapping a push notification. First switch to the My page tab.
        // Opening the list is done by MyProfileView, which watches the same flag
        // (posting at a moment when the tab is not created yet would not arrive, so
        //  the flag stays set and the receiver picks it up)
        .onChange(of: pushService.shouldOpenNotificationList) { _, shouldOpen in
            if shouldOpen { selectedTab = .settings }
        }
        // Jump to the feed tab from "ライバルの進捗を見る" ("See your rivals' progress") in the stop
        // confirmation (StopConfirmationView) (2026-07-16)
        .onReceive(NotificationCenter.default.publisher(for: .switchToFeedTab)) { _ in
            selectedTab = .feed
        }
        .sheet(isPresented: $showComposer) {
            PostFlowView()
        }
        // 🔴 The open count side of the rating request from 2026-08-06 (fix for the Guideline 5.6.3
        // rejection). Schedule/location locks complete in the background, so their users
        // never see the completion screen (SessionCompleteView). Without this they would never be asked.
        // ReviewPrompt owns the firing condition (at least 1 completion is required).
        // Showing it right after coming to the foreground is annoying, so wait a little before showing it
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
            // Dark background for the tab bar
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
    /// Cross-tab notification for moving to the feed tab from other screens (stop confirmation etc.).
    /// MainTabView.selectedTab is a local @State, so from outside it is switched via a notification
    static let switchToFeedTab = Notification.Name("switchToFeedTab")
    /// Tapping the selected search tab again → focus the search field in SearchView (2026-07-25)
    static let focusSearchField = Notification.Name("focusSearchField")
    /// Tapping the selected feed tab again → refetch the visible segment, same as pull-to-refresh
    /// (2026-08-04)
    static let reloadFeedTab = Notification.Name("reloadFeedTab")
}

#Preview {
    MainTabView()
}
