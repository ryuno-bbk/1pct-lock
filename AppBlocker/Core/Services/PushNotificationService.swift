//
//  PushNotificationService.swift
//  AppBlocker
//
//  プッシュ通知 (APNs) の許可取得・端末トークン登録・受信ハンドリング。
//
//  背景:
//    user_notifications は動いているのに配信手段が無く、
//    通知の大半が未読のまま死んでいた。新機能ではなく「切れていた配線」。
//
//  配信の流れ:
//    user_notifications へ INSERT
//      → Supabase Database Webhook
//      → Edge Function `send-push` (Supabase/functions/send-push/index.ts)
//      → APNs → 端末
//
//  🔴 サンドボックス / 本番 APNs:
//    開発ビルド (Xcode から直接インストール) はサンドボックス、TestFlight と
//    App Store は本番。ホストが別物なので、どちらで取得したトークンかを
//    サーバーに申告する (078 の user_push_tokens.environment)。
//    ここを誤ると「開発では届くが本番で無音」を踏む。
//    ⚠️ 必ず TestFlight で1回実機確認すること。Xcode 実行だけでは本番経路を検証できない。
//

import Foundation
import Combine
import UIKit
import UserNotifications
import Supabase

@MainActor
final class PushNotificationService: NSObject, ObservableObject {

    static let shared = PushNotificationService()

    /// システムの許可状態。UI から「まだ聞いていない / 拒否された」を見分けるのに使う
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// 通知をタップして起動/復帰したときに立つ。MainTabView が拾って通知一覧を開く
    @Published var shouldOpenNotificationList: Bool = false

    /// APNs から受け取った端末トークン (16進文字列)。
    /// サインインより先に届くことがあるので保持しておき、サインイン後に登録する
    private var deviceToken: String?

    private let client: SupabaseClient

    /// このビルドがどちらの APNs に紐づくか。
    /// Debug = Xcode 直接インストール = サンドボックス、
    /// Release = TestFlight / App Store = 本番。
    private var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
        super.init()
    }

    // MARK: - 起動時

    /// アプリ起動時に呼ぶ。既に許可済みなら黙って登録し直すだけ (トークンは変わりうるため)。
    /// 🔴 ここで許可ダイアログは出さない。起動直後の「唐突な許可要求」は拒否されやすく、
    ///    一度拒否されるとアプリ内から復帰できない (設定アプリに行かせるしかない)
    func refreshOnLaunch() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - 許可取得

    /// 許可ダイアログを出す。既に決定済みなら何もしない (再表示はできない)。
    /// 呼ぶ場所は「通知に意味が出た瞬間」に限ること (下記 2箇所)。
    /// - 通知一覧を開いたとき (まさに通知を見に来ている)
    /// - 投稿を公開した直後 (いいね/コメントが届く理由ができた)
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard settings.authorizationStatus == .notDetermined else {
            // 既に許可済みなら登録だけ念のため走らせる
            if settings.authorizationStatus == .authorized {
                UNUserNotificationCenter.current().delegate = self
                UIApplication.shared.registerForRemoteNotifications()
            }
            return settings.authorizationStatus == .authorized
        }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                UNUserNotificationCenter.current().delegate = self
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            print("⚠️ Push authorization failed: \(error)")
            return false
        }
    }

    // MARK: - 端末トークン

    /// AppDelegate の didRegisterForRemoteNotificationsWithDeviceToken から呼ぶ
    func handleDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await syncTokenToServer() }
    }

    /// AppDelegate の didFailToRegisterForRemoteNotifications から呼ぶ。
    /// シミュレータや機内モードでは普通に失敗するので、握りつぶしてログだけ残す
    func handleRegistrationFailure(_ error: Error) {
        print("⚠️ Failed to register for remote notifications: \(error)")
    }

    /// トークンをサーバーに登録する。サインイン直後にも呼ぶ
    /// (トークンがサインインより先に届いているケースを拾うため)
    func syncTokenToServer() async {
        guard let token = deviceToken else { return }
        guard UserAuthService.shared.userId != nil else { return }

        let params: [String: AnyJSON] = [
            "p_token": .string(token),
            "p_environment": .string(apnsEnvironment)
        ]

        do {
            _ = try await client.rpc("upsert_push_token", params: params).execute()
        } catch {
            print("⚠️ Failed to register push token: \(error)")
        }
    }

    /// サインアウト時に呼ぶ。
    /// 残したままにすると、次にその端末を使う人に前の持ち主宛ての通知が飛ぶ
    func removeTokenFromServer() async {
        guard let token = deviceToken else { return }

        let params: [String: AnyJSON] = ["p_token": .string(token)]
        do {
            _ = try await client.rpc("delete_push_token", params: params).execute()
        } catch {
            print("⚠️ Failed to remove push token: \(error)")
        }
        clearBadge()
    }

    // MARK: - バッジ

    /// アプリアイコンのバッジを未読件数に合わせる。
    /// 一覧を開いて既読化したら 0 にする (数字が残り続けると信用を失う)
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { error in
            if let error { print("⚠️ Failed to set badge: \(error)") }
        }
    }

    func clearBadge() {
        setBadge(0)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationService: UNUserNotificationCenterDelegate {

    /// アプリを開いている最中に届いた通知。黙って捨てず、バナーで出す
    /// (アプリ内ベルの未読数も一緒に更新する)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await NotificationService.shared.refreshUnreadCount()
        return [.banner, .list, .sound, .badge]
    }

    /// 通知をタップした。通知一覧へ送る
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            shouldOpenNotificationList = true
        }
        await NotificationService.shared.refreshUnreadCount()
    }
}
