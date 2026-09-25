//
//  AppBlockerApp.swift
//  AppBlocker
//
//  Created by Ryunosuke Ishigami on 2026/01/31.
//

import SwiftUI
import UIKit
import FamilyControls

/// B-1: バックグラウンド再起動時に CLLocationManager を即座に再構築するための AppDelegate。
/// iOS がジオフェンスイベント（region entry/exit）でアプリをバックグラウンド再起動した場合、
/// LocationManager.shared を明示的に生成して CLLocationManager を再構築しないと、
/// システムが配送しようとしていた region イベントが受信されずに破棄されてしまう（機能の根幹）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // didFinishLaunching は main スレッドで呼ばれるため、
        // @MainActor な LocationManager.shared への同期アクセスが安全であることをコンパイラに伝える
        MainActor.assumeIsolated {
            _ = LocationManager.shared
        }
        return true
    }

    // MARK: - プッシュ通知 (APNs)
    //
    // 端末トークンは起動のたびに変わりうるので、受け取ったら毎回サーバーへ入れ直す。
    // 🔴 ここで許可ダイアログは出さない (PushNotificationService の設計コメント参照)

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
    /// 073: 設定の言語 Picker も同じキーの @AppStorage に書き込むため、App 側に持たせておけば
    /// どこが書き換えても .onChange(of: mainLanguageRaw) が飛ぶ (users.lang の追随に使う)
    @AppStorage("mainLanguage") private var mainLanguageRaw: String = AppLanguage.deviceDefault.rawValue
    /// M8 (2026-07-22 監査): 再サインインの瞬間に (hasCompletedOnboarding=true のまま)
    /// ルートを即 MainTabView へ切り替えてしまうと、返却フロー (paywall/appSelect/rating) が
    /// 実行されないままオンボが完了扱いになる。OnboardingView が滞在中は true にして
    /// MainTabView への切り替えを止める。
    @State private var onboardingActive = false
    /// 起動直後のブートゲート (2026-07-30 実機FB: オンボの「始める」画面が一瞬見える)。
    /// isSignedIn は毎起動 false から始まり restoreSession() で復元されるため、復元が終わる
    /// までルート判定は必ず「オンボ側」に倒れる。旧スプラッシュ廃止 (2026-07-29) でこの
    /// 空白を覆うものが無くなった → オンボ完了済み端末では復元が終わるまで背景色だけを出す
    /// (ローンチ画面の延長に見える)。安全弁: 3秒で必ず開く (復元が固まっても黒画面で詰まない)
    @State private var bootGateActive = true
    /// スプラッシュを閉じる条件の2つ (両方揃ってから閉じる)
    @State private var sessionRestored = false
    @State private var splashMinElapsed = false
    @Environment(\.scenePhase) private var scenePhase

    /// 復元完了 + 最短表示時間の両方が揃ったらスプラッシュを畳む
    private func closeBootGateIfReady() {
        guard sessionRestored, splashMinElapsed else { return }
        closeBootGate()
    }

    private func closeBootGate() {
        guard bootGateActive else { return }
        withAnimation(.easeOut(duration: 0.28)) { bootGateActive = false }
    }

    init() {
        // 言語設定の一回きり移行 (2026-07-25 実機FB: 端末言語を変えてもUIが日本語のまま)。
        // 過去ビルドの設定Pickerが書き込んだ mainLanguage が残っていると、以後は端末言語に
        // 一切追従しなくなる。既定を「端末に従う (キー無し)」へ戻すため保存値を一度だけ破棄する。
        // 以後にユーザーが設定Pickerで明示選択した値 (=このフラグより後の書き込み) は尊重される
        let langMigrationKey = "langFollowSystemMigration_2026_07_25"
        if !UserDefaults.standard.bool(forKey: langMigrationKey) {
            UserDefaults.standard.removeObject(forKey: "mainLanguage")
            UserDefaults.standard.set(true, forKey: langMigrationKey)
        }

        // M18a: フィード画像のスクロール往復での再ダウンロード (Storage egress浪費) を減らすため、
        // 既定容量から拡張 (最初のネットワークリクエストより前に設定する必要がある)
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)

        // 初回起動時: 端末言語からメイン言語の初期値を決定
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "mainLanguage") == nil {
            let lang = AppLanguage.deviceDefault
            defaults.set(lang.rawValue, forKey: "mainLanguage")
        }

        // 原文併記は既定OFF (2026-08-01 ユーザー決定 / 実機FBで発覚)。
        // 旧実装はここで「日本語端末なら showOriginal=true」を書いていたが、この分岐は
        // mainLanguage が未設定のとき = 新規インストール時にしか通らない。結果、
        // 開発者の端末 (キーが既にある) では一度も再現せず、App Store から入れた
        // 新規ユーザーだけが「英語を主役・日本語訳を下に小さく」の表示になっていた。
        // 設定トグルは 2026-07-19 に撤去済みでユーザーが自力でOFFにする手段が無いため、
        // 既に true が書き込まれている端末も一度だけ false へ戻す。
        let showOriginalResetKey = "showOriginalDefaultOff_2026_08_01"
        if !defaults.bool(forKey: showOriginalResetKey) {
            defaults.set(false, forKey: "showOriginal")
            defaults.set(true, forKey: showOriginalResetKey)
        }

        // RevenueCat SDK 初期化 (多重呼び出しは PurchaseService.configure() 内でガード済み)。
        // App.init() は main スレッドで呼ばれることが保証されているため、@MainActor への同期アクセスは安全
        MainActor.assumeIsolated {
            PurchaseService.configure()
        }
    }

    /// 累計ロック時間 + 統計: pending キューを Supabase へ同期 → 統計取得
    /// (033 で loadTotal は loadStats に統合。累計/上位%/連続日数/完遂率をまとめて取得)
    /// flushQueue (キュー反映) → loadStats (統計取得) の順を必ず守る。
    /// 逆にするとキュー未反映分を含まない統計を読んでしまう
    private func flushQueueThenLoadStats() async {
        await BlockSessionTracker.shared.flushQueue()
        await BlockSessionTracker.shared.loadStats()
    }

    /// 073: 現在の mainLanguage (UserDefaults) を AppLanguage として読む。
    /// 起動 .task 内 (223行目付近) の Shield 用ミラー処理と同じ「未設定なら端末既定言語」の
    /// 読み方 + 不正値フォールバック (.japanese) に揃える
    private func currentMainLanguage() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
        return AppLanguage(rawValue: raw) ?? .japanese
    }

    /// サインイン直後は未読通知数取得 + RevenueCat ログイン、サインアウト時は通知クリア + ログアウト。
    /// (他の並列タスクとは独立なので、呼び出し側では async let の1本としてまとめて扱う)
    private func syncSignInState(signedIn: Bool) async {
        if signedIn {
            await NotificationService.shared.refreshUnreadCount()
            if let uid = userAuth.userId {
                await PurchaseService.shared.logIn(userId: uid)
            }
            // 073: サインイン時に閲覧者の端末言語 (users.lang) をサーバーへ同期する
            // (フィードの同一言語優先スコアリングの判定材料)。失敗は userAuth.syncLanguage 内で握りつぶす
            await userAuth.syncLanguage(currentMainLanguage())
        } else {
            NotificationService.shared.clear()
            await PurchaseService.shared.logOut()
        }
    }

    /// M20 (2026-07-22 監査): サインイン時のみフィードを再ロードする。サインアウト時は
    /// 何もしない (クリアは .onChange 側で同じ Task 内の先頭にて同期的に行う)。
    /// syncSignInState と同じ「async let 群に無条件で1本追加し、内部で signedIn 分岐する」形。
    private func syncFeedState(signedIn: Bool) async {
        guard signedIn else { return }
        async let recommendedTask: Void = FeedService.shared.loadRecommended()
        async let followingTask: Void = FeedService.shared.loadFollowing()
        await recommendedTask
        await followingTask
    }

    /// 070 (anon から public.quotes/public.authors を読めなくする SQL) 適用後、
    /// 未サインインのまま QuoteService.shared.loadQuotes() を叩くと必ず 401 になる無駄な
    /// リクエストになるため、サインイン時のみ Supabase プロバイダへ切り替えて読み込む。
    /// flushQueueThenLoadStats と同じく、起動時 .task と .onChange(of: userAuth.isSignedIn)
    /// の両方から呼ばれる private helper。
    /// LikeService.loadLikedQuotes → loadLikedQuoteObjects は QuoteService.shared.quotes
    /// (メモリキャッシュ) を同期的に見にいく実装なので、呼び出し側は本関数を await し終えてから
    /// loadLikedQuotes を含む async let 群を開始すること
    private func loadQuotesIfSignedIn(signedIn: Bool) async {
        guard signedIn else { return }
        QuoteService.shared.enableSupabase()
        await QuoteService.shared.loadQuotes()
    }

    /// 起動 .task 専用。サインイン済みなら Supabase へ切り替えて読み、
    /// 未サインインなら LocalQuoteProvider (バンドルの Quotes.json 68件 = 060 適用後の
    /// 本番 quotes と同一内容) のまま読む。
    /// ⚠️ 未サインインでも「読むこと自体」を省略しないこと。省略すると
    /// QuoteService.shared.quotes が空配列のままになり、この .task 末尾の
    /// WidgetCacheService.refreshAll() → writeRandomPool() (WidgetCacheService.swift:57)
    /// が空のプールを App Group に書き出してしまう = 一度もサインインしていない端末で
    /// ウィジェットが無表示になる。070 適用前は anon 読みが通っていたため気付けない退行。
    /// (サインアウト時の再読み込みは不要なので .onChange 側は loadQuotesIfSignedIn のまま)
    private func loadQuotesForLaunch(signedIn: Bool) async {
        if signedIn { QuoteService.shared.enableSupabase() }
        await QuoteService.shared.loadQuotes()
    }

    /// 070 適用後、未サインインで loadAuthors() を叩くと 401 になるだけなのでガードする。
    /// syncSignInState / syncFeedState と同じ「async let は無条件に1本、内部で signedIn 分岐」
    /// の形にすることで、呼び出し側の async let 群の本数 (構造) を変えずに済ませる
    private func loadAuthorsIfSignedIn(signedIn: Bool) async {
        guard signedIn else { return }
        await QuoteService.shared.loadAuthors()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // M8: onboardingActive が true の間は OnboardingView 側が返却フロー
                // (paywall/appSelect/rating 等) を実行中なので、条件が揃っていても
                // MainTabView へ切り替えない
                if hasCompletedOnboarding && authService.isAuthorized && userAuth.isSignedIn && !onboardingActive {
                    MainTabView()
                } else if bootGateActive && hasCompletedOnboarding {
                    // セッション復元待ち = スプラッシュ (2026-07-31 ユーザー要望で復活)。
                    // 新規インストール (hasCompletedOnboarding=false) では出さない —
                    // 待つものが無いうえ、直後のオンボ冒頭が同じ「1%」の大型ワードマークで
                    // ブランド提示が二重になるため
                    SplashView()
                        .transition(.opacity)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding, onboardingActive: $onboardingActive)
                }
            }
            .preferredColorScheme(.dark)
            // アプリ全域: テキスト入力以外をタップしたらキーボードを閉じる (2026-07-25 実機FB)
            .onAppear { KeyboardDismissTap.installIfNeeded() }
            // ブートゲートの安全弁: restoreSession が異常に長引いてもスプラッシュで詰まない
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                closeBootGate()
            }
            // スプラッシュの最短表示時間。復元が一瞬で終わってもロゴが点滅して見えないようにする
            .task {
                try? await Task.sleep(nanoseconds: 750_000_000)
                splashMinElapsed = true
                closeBootGateIfReady()
            }
            .task {
                // 起動時に認証状態を確認
                authService.checkCurrentStatus()
                await userAuth.restoreSession()
                // 復元完了 = ルート判定の材料が揃った (isAuthorized は上で同期更新済み)
                sessionRestored = true
                closeBootGateIfReady()
                if let uid = userAuth.userId {
                    await PurchaseService.shared.logIn(userId: uid)
                }

                // Shield (案A) が表示言語を読めるよう、現在の mainLanguage を App Group へミラー
                // (設定画面での変更はここを経由しない限り Extension 側には反映されない既知の制約)
                let currentLangRaw = UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue
                AppGroupStorage.shared.syncCurrentLanguage(isJapanese: (AppLanguage(rawValue: currentLangRaw) ?? .japanese) == .japanese)

                // Supabase初期化 + データロード。
                // 070 (anon から public.quotes/public.authors を読めなくする SQL) 適用後は、
                // 未サインインで Supabase を叩いても必ず権限エラーになるため、Supabase への
                // 切り替えはサインイン済みのときだけ行う。未サインイン時は LocalQuoteProvider
                // (バンドル 68件) から読む — 読むこと自体は省略しない (理由は
                // loadQuotesForLaunch のコメント: ウィジェットのプールが空になる)。
                // サインイン後の読み直しは .onChange(of: userAuth.isSignedIn) 側が担当する。
                //
                // LikeService.loadLikedQuotes → loadLikedQuoteObjects が QuoteService.shared.quotes
                // (メモリキャッシュ) に依存するため、quotes だけは単独で await してから残りを並列化する
                await loadQuotesForLaunch(signedIn: userAuth.isSignedIn)

                // 以下は quotes 読了後なら互いに独立 (順序自由) なので async let で同時開始し、まとめて合流する
                // (直列だと初回データ到達が RTT × 本数ぶん積み上がるため)。
                // C1: 課金失効リコンサイル — 新鮮なフェッチで非 Pro が確定した場合のみ
                // スケジュール/位置遮断の実行ゲート (App Group ミラー) を閉じる
                async let reconcileTask: Void = ProAccess.shared.reconcileEntitlementMirror()
                // authorsTask も quotes と同じ理由 (070) でガードする。他の async let は無条件のまま
                async let authorsTask: Void = loadAuthorsIfSignedIn(signedIn: userAuth.isSignedIn)
                async let likedQuotesTask: Void = LikeService.shared.loadLikedQuotes()
                async let followedAuthorsTask: Void = FollowService.shared.loadFollowedAuthors()
                async let myBlocksTask: Void = BlockService.shared.loadMyBlocks()
                async let unreadCountTask: Void = NotificationService.shared.refreshUnreadCount()
                async let statsTask: Void = flushQueueThenLoadStats()
                // 許可済みの端末だけ黙って再登録する (ここでダイアログは出さない)。
                // サインインより先にトークンが届いていた場合の取りこぼしもここで拾う
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

                // Shield用に名言を保存（タブ切り替え前でも確実に保存）
                if let quote = QuoteService.shared.currentQuote {
                    BlockingService.shared.saveQuoteForShield(quote)
                }
                // Shield ローテーション用プールも起動時に用意（スケジュール/位置ブロックや
                // フレッシュインストール直後の初回ブロックでも Extension が重い JSON パースを
                // せずに済むよう、事前に App Group へ書き出しておく）
                BlockingService.shared.saveQuotePoolForShield()

                // ウィジェット用キャッシュを App Group に書き出し
                WidgetCacheService.shared.refreshAll()
            }
            .onChange(of: userAuth.isSignedIn) { _, signedIn in
                // サインイン直後 (初回) / サインアウト時に quotes/authors/like/follow/block/notif を再ロード
                // (互いに独立なので async let で並列化。flushQueue→loadStats のペアのみ順序維持)
                Task {
                    // M20/L11: サインアウトの瞬間にフィード/自分の投稿一覧をクリアする。
                    // 後続の再ロード (syncFeedState) より前に、Task の先頭で同期的に行うことで
                    // 「クリアより前に別アカウントの再ロードが割り込む」順序崩れを避ける。
                    if !signedIn {
                        FeedService.shared.clear()
                        UserPostService.shared.clearAllForSignOut()
                    }
                    // サインアップ/サインイン直後は QuoteService.shared.authors が空のまま
                    // (再起動するまで is_official バッジが付かない) だったバグの修正。
                    // LikeService.loadLikedQuotes → loadLikedQuoteObjects が QuoteService.shared.quotes
                    // (メモリキャッシュ) を同期的に見にいく実装のため、起動時 .task と同じ順序で
                    // quotes だけ単独で await してから、下の async let 群 (loadLikedQuotes 含む) を開始する
                    await loadQuotesIfSignedIn(signedIn: signedIn)
                    async let likedQuotesTask: Void = LikeService.shared.loadLikedQuotes()
                    async let followedAuthorsTask: Void = FollowService.shared.loadFollowedAuthors()
                    async let myBlocksTask: Void = BlockService.shared.loadMyBlocks()
                    async let statsTask: Void = flushQueueThenLoadStats()
                    async let signInStateTask: Void = syncSignInState(signedIn: signedIn)
                    // M20: サインイン時はフィードも無条件で再ロード (新ユーザー視点のフィードにする)
                    async let feedStateTask: Void = syncFeedState(signedIn: signedIn)
                    // quotes 読了後なので authors は他の async let と同じく並列でよい
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
            // 073: 設定の言語 Picker は @AppStorage("mainLanguage") へ直接書き込むため、
            // App 側の同じキーの @AppStorage を監視して users.lang を追随させる。
            // ⚠️ UserDefaults.didChangeNotification の購読で代用しないこと —
            // あの通知は App Group スイートを含む全 UserDefaults の全書き込みで発火するので、
            // 言語と無関係な書き込み (ブロックセッション同期 / ウィジェットキャッシュ更新など) の
            // たびに Task を1個生成することになる。syncLanguage 側の重複ガードは
            // 通信を止めるだけで、Task 生成自体は止められない
            .onChange(of: mainLanguageRaw) { _, _ in
                let lang = currentMainLanguage()
                // 2026-08-04: Shield / UsageReport 拡張が読む App Group ミラーもここで更新する。
                // これまで syncCurrentLanguage は起動 .task (238行目) からしか呼ばれておらず、
                // 設定の言語 Picker で切り替えても次のコールドスタートまで拡張側は旧言語のままだった
                // (=「アプリは英語なのに Shield が日本語」)。
                // ⚠️ 遮断はサインアウト状態でも動くので、下の isSignedIn ガードより必ず前に置く
                AppGroupStorage.shared.syncCurrentLanguage(isJapanese: lang == .japanese)
                guard userAuth.isSignedIn else { return }
                Task { await userAuth.syncLanguage(lang) }
            }
            .onChange(of: scenePhase) { _, phase in
                // C1: フォアグラウンド復帰時にも失効リコンサイル (1時間スロットルは ProAccess 側)
                guard phase == .active else { return }
                Task { await ProAccess.shared.reconcileEntitlementMirror() }
                // H6: オフライン起動等でサーバー未検証のままローカル信頼サインインしている場合、
                // フォアグラウンド復帰のたびに再検証を試みる (成功すれば refreshProfile まで走る)。
                // restoreSession() 側に多重実行ガードがあるので、ここでの Task 生成が重なっても安全。
                if userAuth.isSignedIn && !userAuth.isSessionServerVerified {
                    Task { await userAuth.restoreSession() }
                }
            }
        }
    }
}
