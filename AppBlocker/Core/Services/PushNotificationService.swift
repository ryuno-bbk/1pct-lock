//
//  PushNotificationService.swift
//  AppBlocker
//
//  Push notifications (APNs): getting permission, registering the device token, handling incoming ones.
//
//  Background:
//    user_notifications was working but there was no way to deliver them,
//    and most notifications died unread. Not a new feature, but "wiring that was cut".
//
//  Delivery flow:
//    INSERT into user_notifications
//      → Supabase Database Webhook
//      → Edge Function `send-push` (Supabase/functions/send-push/index.ts)
//      → APNs → device
//
//  🔴 Sandbox / production APNs:
//    Development builds (installed directly from Xcode) use the sandbox, TestFlight and
//    the App Store use production. The hosts are different, so we tell the server which one
//    the token came from (user_push_tokens.environment in 078).
//    Getting this wrong means "delivered in development but silent in production".
//    ⚠️ Always check once on a real device with TestFlight. Running from Xcode alone cannot verify
//    the production path.
//

import Foundation
import Combine
import UIKit
import UserNotifications
import Supabase

@MainActor
final class PushNotificationService: NSObject, ObservableObject {

    static let shared = PushNotificationService()

    /// The system permission state. Used by the UI to tell "not asked yet / denied" apart
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Set when the app is launched/resumed by tapping a notification. MainTabView picks it up and opens the
    /// notification list
    @Published var shouldOpenNotificationList: Bool = false

    /// Device token received from APNs (hex string).
    /// It can arrive before sign-in, so it is kept and registered after sign-in
    private var deviceToken: String?

    private let client: SupabaseClient

    /// Which APNs this build is tied to.
    /// Debug = installed directly from Xcode = sandbox,
    /// Release = TestFlight / App Store = production.
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

    // MARK: - On launch

    /// Called on app launch. If already allowed, just quietly register again (the token can change).
    /// 🔴 No permission dialog here. A "sudden permission request" right after launch tends to be denied,
    ///    and once denied it cannot be recovered from inside the app (we can only send the user to Settings)
    func refreshOnLaunch() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Getting permission

    /// Shows the permission dialog. Does nothing if already decided (it cannot be shown again).
    /// Only call it at "the moment notifications start to mean something" (the 2 places below).
    /// - When the notification list is opened (the user came exactly to look at notifications)
    /// - Right after publishing a post (there is now a reason for likes/comments to arrive)
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard settings.authorizationStatus == .notDetermined else {
            // If already allowed, run only the registration, just in case
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

    // MARK: - Device token

    /// Called from didRegisterForRemoteNotificationsWithDeviceToken in AppDelegate
    func handleDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await syncTokenToServer() }
    }

    /// Called from didFailToRegisterForRemoteNotifications in AppDelegate.
    /// It fails normally on the simulator or in airplane mode, so swallow it and only log it
    func handleRegistrationFailure(_ error: Error) {
        print("⚠️ Failed to register for remote notifications: \(error)")
    }

    /// Registers the token with the server. Also called right after sign-in
    /// (to catch cases where the token arrived before sign-in)
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

    /// Called on sign-out.
    /// If the token were left, the next person using that device would receive notifications meant for the
    /// previous owner
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

    // MARK: - Badge

    /// Set the app icon badge to the unread count.
    /// Set it to 0 when the list is opened and items are marked read (a number that stays forever loses trust)
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

    /// Notification that arrived while the app is open. Do not silently drop it, show it as a banner
    /// (also update the unread count of the in-app bell)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await NotificationService.shared.refreshUnreadCount()
        return [.banner, .list, .sound, .badge]
    }

    /// The notification was tapped. Send the user to the notification list
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
