//
//  AppBlockerApp.swift
//  AppBlocker
//
//  Created by Ryunosuke Ishigami on 2026/01/31.
//

import SwiftUI
import UIKit
import FamilyControls

/// B-1: AppDelegate to rebuild CLLocationManager right away on a background relaunch.
/// When iOS relaunches the app in the background for a geofence event (region entry/exit),
/// if we do not explicitly create LocationManager.shared and rebuild CLLocationManager,
/// the region event the system was trying to deliver is not received and gets discarded (core of the
/// feature).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // didFinishLaunching is called on the main thread, so
        // tell the compiler that synchronous access to the @MainActor LocationManager.shared is safe
        MainActor.assumeIsolated {
            _ = LocationManager.shared
        }
        return true
    }

    // MARK: - Push notifications (APNs)
    //
    // The device token can change on every launch, so send it to the server again every time we receive it.
    // 🔴 Do not show the permission dialog here (see the design comment in PushNotificationService)

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            PushNotificationService.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            PushNotificationService.shared.handleRegistrationFailure(error)
        }
    }
}

@main
struct AppBlockerApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var authService = AuthorizationService.shared
    @StateObject private var userAuth = UserAuthService.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// 073: The language Picker in settings also writes to @AppStorage with the same key, so if the App
    /// holds it, .onChange(of: mainLanguageRaw) fires no matter who changes it (used to keep users.lang in
    /// sync)
    @AppStorage("mainLanguage") private var mainLanguageRaw: String = AppLanguage.deviceDefault.rawValue
    /// M8 (2026-07-22 audit): If, at the moment of signing in again (with hasCompletedOnboarding=true),
    /// the root switches to MainTabView right away, onboarding is treated as finished without running
    /// the return flow (paywall/appSelect/rating). Set this to true while OnboardingView is shown to stop
    /// the switch to MainTabView.
    @State private var onboardingActive = false
    /// Boot gate right after launch (2026-07-30 real device feedback: the onboarding "始める" ("Start") screen
    /// flashes briefly). isSignedIn starts as false on every launch and is restored by restoreSession(), so
    /// until the restore finishes the root decision always falls to the "onboarding side". Since the old
    /// splash was removed (2026-07-29), nothing covered this gap → on devices that finished onboarding,
    /// show only the background color until the restore finishes (looks like a continuation of the launch
    /// screen). Safety valve: always open within 3 seconds (no stuck black screen even if the restore
    /// hangs)
    @State private var bootGateActive = true
    /// The 2 conditions for closing the splash (close only when both are met)
    @State private var sessionRestored = false
    @State private var splashMinElapsed = false
    @Environment(\.scenePhase) private var scenePhase

    /// Fold the splash once both are met: restore finished + minimum display time
    private func closeBootGateIfReady() {
        guard sessionRestored, splashMinElapsed else { return }
        closeBootGate()
    }

    private func closeBootGate() {
        guard bootGateActive else { return }
        withAnimation(.easeOut(duration: 0.28)) { bootGateActive = false }
    }

    init() {
        // One-time migration of the language setting (2026-07-25 real device feedback: changing the device
        // language left the UI in Japanese). If a mainLanguage written by the settings Picker of a past build
        // remains, the app never follows the device language again. To bring the default back to "follow the
        // device (no key)", discard the saved value once. Values the user explicitly picks in the settings
        // Picker after that (= writes after this flag) are respected
        let langMigrationKey = "langFollowSystemMigration_2026_07_25"
        if !UserDefaults.standard.bool(forKey: langMigrationKey) {
            UserDefaults.standard.removeObject(forKey: "mainLanguage")
            UserDefaults.standard.set(true, forKey: langMigrationKey)
        }

        // M18a: Raise the capacity from the default to reduce re-downloads of feed images when scrolling back
        // and forth (wasted Storage egress) (must be set before the first network request)
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)

        // On first launch: decide the initial main language from the device language
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "mainLanguage") == nil {
            let lang = AppLanguage.deviceDefault
            defaults.set(lang.rawValue, forKey: "mainLanguage")
        }

        // Showing the original text alongside is OFF by default (user decision 2026-08-01 / found through real
        // device feedback). The old implementation wrote "showOriginal=true if the device is Japanese" here,
        // but this branch only runs when mainLanguage is unset = on a fresh install. As a result,
        // it never reproduced on the developer's device (the key already exists), and only new users who
        // installed from the App Store got the "English as the main text, small Japanese translation below"
        // display. The settings toggle was removed on 2026-07-19 and users have no way to turn it OFF
        // themselves, so devices where true was already written are also set back to false once.
        let showOriginalResetKey = "showOriginalDefaultOff_2026_08_01"
        if !defaults.bool(forKey: showOriginalResetKey) {
            defaults.set(false, forKey: "showOriginal")
            defaults.set(true, forKey: showOriginalResetKey)
        }

        // Initialize the RevenueCat SDK (repeated calls are guarded inside PurchaseService.configure()).
        // App.init() is guaranteed to be called on the main thread, so synchronous access to @MainActor is safe
        MainActor.assumeIsolated {
            PurchaseService.configure()
        }
    }

    /// Total lock time + stats: sync the pending queue to Supabase → fetch stats
    /// (in 033 loadTotal was merged into loadStats. Fetches total/top percentile/streak days/completion
    /// rate together) Always keep the order flushQueue (apply queue) → loadStats (fetch stats).
    /// If reversed, you read stats that do not include what is still in the queue
    private func flushQueueThenLoadStats() async {
        await BlockSessionTracker.shared.flushQueue()
        await BlockSessionTracker.shared.loadStats()
    }

    /// 073: Read the current mainLanguage (UserDefaults) as AppLanguage.
    /// Matches the Shield mirror logic in the launch .task (around line 223): the same "device default
    /// language if unset" reading + fallback for invalid values (.japanese)
    private func currentMainLanguage() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
        return AppLanguage(rawValue: raw) ?? .japanese
    }

    /// Right after sign-in: fetch the unread notification count + RevenueCat login. On sign-out: clear
    /// notifications + logout. (Independent from the other parallel tasks, so the caller handles it as one
    /// of the async lets)
    private func syncSignInState(signedIn: Bool) async {
        if signedIn {
            await NotificationService.shared.refreshUnreadCount()
            if let uid = userAuth.userId {
                await PurchaseService.shared.logIn(userId: uid)
            }
            // 073: On sign-in, sync the viewer's device language (users.lang) to the server
            // (input for the same-language priority scoring of the feed). Failures are swallowed inside
            // userAuth.syncLanguage
            await userAuth.syncLanguage(currentMainLanguage())
        } else {
            NotificationService.shared.clear()
            await PurchaseService.shared.logOut()
        }
    }

    /// M20 (2026-07-22 audit): Reload the feed only on sign-in. On sign-out,
    /// do nothing (clearing is done synchronously at the start of the same Task on the .onChange side).
    /// Same shape as syncSignInState: "always add one to the async let group, branch on signedIn inside".
    private func syncFeedState(signedIn: Bool) async {
        guard signedIn else { return }
        async let recommendedTask: Void = FeedService.shared.loadRecommended()
        async let followingTask: Void = FeedService.shared.loadFollowing()
        await recommendedTask
        await followingTask
    }

    /// After 070 (the SQL that stops anon from reading public.quotes/public.authors) is applied,
    /// calling QuoteService.shared.loadQuotes() while signed out is a wasted request that always
    /// returns 401, so switch to the Supabase provider and load only when signed in.
    /// Like flushQueueThenLoadStats, this is a private helper called from both the launch .task and
    /// .onChange(of: userAuth.isSignedIn).
    /// LikeService.loadLikedQuotes → loadLikedQuoteObjects reads QuoteService.shared.quotes
    /// (in-memory cache) synchronously, so the caller must finish awaiting this function before
    /// starting the async let group that includes loadLikedQuotes
    private func loadQuotesIfSignedIn(signedIn: Bool) async {
        guard signedIn else { return }
        QuoteService.shared.enableSupabase()
        await QuoteService.shared.loadQuotes()
    }

    /// Only for the launch .task. If signed in, switch to Supabase and load;
    /// if signed out, load with LocalQuoteProvider as is (the bundled Quotes.json, 68 items = same content as
    /// the production quotes after 060 is applied).
    /// ⚠️ Even when signed out, do not skip "the loading itself". If skipped,
    /// QuoteService.shared.quotes stays an empty array, and at the end of this .task
    /// WidgetCacheService.refreshAll() → writeRandomPool() (WidgetCacheService.swift:57)
    /// writes an empty pool to the App Group = on a device that has never signed in,
    /// the widget shows nothing. Before 070 was applied, anon reads worked, so this regression is easy to miss.
    /// (No reload is needed on sign-out, so the .onChange side keeps using loadQuotesIfSignedIn)
    private func loadQuotesForLaunch(signedIn: Bool) async {
        if signedIn { QuoteService.shared.enableSupabase() }
        await QuoteService.shared.loadQuotes()
    }

    /// After 070 is applied, calling loadAuthors() while signed out only returns 401, so guard it.
    /// By using the same shape as syncSignInState / syncFeedState ("always one async let, branch on
    /// signedIn inside"), the number of async lets (the structure) on the caller side does not have to change
    private func loadAuthorsIfSignedIn(signedIn: Bool) async {
        guard signedIn else { return }
        await QuoteService.shared.loadAuthors()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // M8: While onboardingActive is true, OnboardingView is running the return flow
                // (paywall/appSelect/rating etc.), so even if the conditions are met,
                // do not switch to MainTabView
                if hasCompletedOnboarding && authService.isAuthorized && userAuth.isSignedIn && !onboardingActive {
                    MainTabView()
                } else if bootGateActive && hasCompletedOnboarding {
                    // Waiting for session restore = splash (brought back on 2026-07-31 at the user's request).
                    // Not shown on a fresh install (hasCompletedOnboarding=false):
                    // there is nothing to wait for, and the start of the onboarding right after uses the same large "1%"
                    // wordmark, so the brand would be shown twice
                    SplashView()
                        .transition(.opacity)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding, onboardingActive: $onboardingActive)
                }
            }
            .preferredColorScheme(.dark)
            // App-wide: tapping anything other than a text input closes the keyboard (2026-07-25 real device feedback)
            .onAppear { KeyboardDismissTap.installIfNeeded() }
            // Safety valve for the boot gate: do not get stuck on the splash even if restoreSession takes
            // abnormally long
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                closeBootGate()
            }
            // Minimum display time of the splash. So the logo does not look like it blinks even if the restore
            // finishes instantly
            .task {
                try? await Task.sleep(nanoseconds: 750_000_000)
                splashMinElapsed = true
                closeBootGateIfReady()
            }
            .task {
                // Check the auth status at launch
                authService.checkCurrentStatus()
                await userAuth.restoreSession()
                // Restore finished = we have everything for the root decision (isAuthorized was updated synchronously
                // above)
                sessionRestored = true
                closeBootGateIfReady()
                if let uid = userAuth.userId {
                    await PurchaseService.shared.logIn(userId: uid)
                }

                // Mirror the current mainLanguage to the App Group so the Shield (option A) can read the display language
                // (known limitation: changes in the settings screen are not reflected on the Extension side unless
                // they go through here)
                let currentLangRaw = UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
                AppGroupStorage.shared.syncCurrentLanguage(isJapanese: (AppLanguage(rawValue: currentLangRaw) ?? .japanese) == .japanese)

                // Supabase init + data loading.
                // After 070 (the SQL that stops anon from reading public.quotes/public.authors) is applied,
                // hitting Supabase while signed out always gives a permission error, so the switch to
                // Supabase happens only when signed in. When signed out, read from LocalQuoteProvider
                // (68 bundled items). Do not skip the loading itself (the reason is in the
                // loadQuotesForLaunch comment: the widget pool would become empty).
                // Reloading after sign-in is handled by .onChange(of: userAuth.isSignedIn).
                //
                // LikeService.loadLikedQuotes → loadLikedQuoteObjects depends on QuoteService.shared.quotes
                // (in-memory cache), so await quotes alone first, then run the rest in parallel
                await loadQuotesForLaunch(signedIn: userAuth.isSignedIn)

                // Once quotes are loaded, the following are independent of each other (any order), so start them
                // together with async let and join them (done serially, the time to first data piles up as RTT ×
                // number of calls). C1: purchase expiry reconcile. Only when a fresh fetch confirms non-Pro,
                // close the execution gate for schedule/location blocking (App Group mirror)
                async let reconcileTask: Void = ProAccess.shared.reconcileEntitlementMirror()
                // authorsTask is guarded for the same reason as quotes (070). The other async lets stay unconditional
                async let authorsTask: Void = loadAuthorsIfSignedIn(signedIn: userAuth.isSignedIn)
                async let likedQuotesTask: Void = LikeService.shared.loadLikedQuotes()
                async let followedAuthorsTask: Void = FollowService.shared.loadFollowedAuthors()
                async let myBlocksTask: Void = BlockService.shared.loadMyBlocks()
                async let unreadCountTask: Void = NotificationService.shared.refreshUnreadCount()
                async let statsTask: Void = flushQueueThenLoadStats()
                // Silently re-register only devices that already granted permission (no dialog here).
                // This also catches the case where the token arrived before sign-in and was missed
                async let pushTask: Void = PushNotificationService.shared.refreshOnLaunch()
                await reconcileTask
                await authorsTask
                await likedQuotesTask
                await followedAuthorsTask
                await myBlocksTask
                await unreadCountTask
                await statsTask
                await pushTask
                await PushNotificationService.shared.syncTokenToServer()

                // Save the quote for the Shield (reliably saved even before a tab switch)
                if let quote = QuoteService.shared.currentQuote {
                    BlockingService.shared.saveQuoteForShield(quote)
                }
                // Also prepare the pool for Shield rotation at launch (write it to the App Group in advance so the
                // Extension does not have to do heavy JSON parsing, even for schedule/location blocks or the first
                // block right after a fresh install)
                BlockingService.shared.saveQuotePoolForShield()

                // Write the widget cache to the App Group
                WidgetCacheService.shared.refreshAll()
            }
            .onChange(of: userAuth.isSignedIn) { _, signedIn in
                // Right after sign-in (first time) / on sign-out, reload quotes/authors/like/follow/block/notif
                // (they are independent, so parallelized with async let. Only the flushQueue→loadStats pair keeps its
                // order)
                Task {
                    // M20/L11: Clear the feed / my post list at the moment of sign-out.
                    // Doing it synchronously at the start of the Task, before the later reload (syncFeedState),
                    // avoids the ordering bug where "another account's reload cuts in before the clear".
                    if !signedIn {
                        FeedService.shared.clear()
                        UserPostService.shared.clearAllForSignOut()
                    }
                    // Fix for the bug where QuoteService.shared.authors stayed empty right after sign-up/sign-in
                    // (no is_official badge until restart).
                    // LikeService.loadLikedQuotes → loadLikedQuoteObjects reads QuoteService.shared.quotes
                    // (in-memory cache) synchronously, so in the same order as the launch .task,
                    // await quotes alone first, then start the async let group below (including loadLikedQuotes)
                    await loadQuotesIfSignedIn(signedIn: signedIn)
                    async let likedQuotesTask: Void = LikeService.shared.loadLikedQuotes()
                    async let followedAuthorsTask: Void = FollowService.shared.loadFollowedAuthors()
                    async let myBlocksTask: Void = BlockService.shared.loadMyBlocks()
                    async let statsTask: Void = flushQueueThenLoadStats()
                    async let signInStateTask: Void = syncSignInState(signedIn: signedIn)
                    // M20: On sign-in, also reload the feed unconditionally (make it the feed from the new user's point of
                    // view)
                    async let feedStateTask: Void = syncFeedState(signedIn: signedIn)
                    // Quotes are already loaded, so authors can run in parallel like the other async lets
                    async let authorsTask: Void = loadAuthorsIfSignedIn(signedIn: signedIn)
                    await likedQuotesTask
                    await followedAuthorsTask
                    await myBlocksTask
                    await statsTask
                    await signInStateTask
                    await feedStateTask
                    await authorsTask
                    WidgetCacheService.shared.refreshAll()
                }
            }
            // 073: The language Picker in settings writes directly to @AppStorage("mainLanguage"), so
            // we watch @AppStorage with the same key on the App side and keep users.lang in sync.
            // ⚠️ Do not substitute a subscription to UserDefaults.didChangeNotification:
            // that notification fires on every write to every UserDefaults, including the App Group suite, so
            // it would create one Task for every write unrelated to language (block session sync / widget cache
            // update etc.). The duplicate guard in syncLanguage only stops the network call,
            // it cannot stop the Task creation itself
            .onChange(of: mainLanguageRaw) { _, _ in
                let lang = currentMainLanguage()
                // 2026-08-04: Also update the App Group mirror read by the Shield / UsageReport extensions here.
                // Until now syncCurrentLanguage was only called from the launch .task (line 238), so
                // switching with the language Picker in settings left the extensions on the old language until the
                // next cold start (= "the app is in English but the Shield is in Japanese").
                // ⚠️ Blocking works even while signed out, so always put this before the isSignedIn guard below
                AppGroupStorage.shared.syncCurrentLanguage(isJapanese: lang == .japanese)
                guard userAuth.isSignedIn else { return }
                Task { await userAuth.syncLanguage(lang) }
            }
            .onChange(of: scenePhase) { _, phase in
                // C1: Also reconcile expiry when returning to the foreground (the 1-hour throttle is in ProAccess)
                guard phase == .active else { return }
                Task { await ProAccess.shared.reconcileEntitlementMirror() }
                // H6: If we are signed in with local trust and no server verification (e.g. launched offline),
                // try to re-verify every time we return to the foreground (on success it runs through refreshProfile).
                // restoreSession() has a guard against concurrent runs, so overlapping Task creation here is safe.
                if userAuth.isSignedIn && !userAuth.isSessionServerVerified {
                    Task { await userAuth.restoreSession() }
                }
            }
        }
    }
}
