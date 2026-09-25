//
//  NotificationService.swift
//  AppBlocker
//
//  アプリ内通知 (like / follow / comment / reply / comment_like) の取得 + 未読管理
//  Push 通知は将来実装、ここではアプリ内ベル + 通知一覧のみ
//

import Foundation
import Combine
import Supabase

@MainActor
final class NotificationService: ObservableObject {

    static let shared = NotificationService()

    @Published private(set) var notifications: [UserNotification] = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var isLoading: Bool = false

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Fetch

    /// 通知一覧取得 (新着順、最大 50 件)
    func loadNotifications(limit: Int = 50) async {
        guard UserAuthService.shared.userId != nil else {
            notifications = []
            unreadCount = 0
            return
        }

        isLoading = true
        defer { isLoading = false }

        let params: [String: AnyJSON] = [
            "limit_count": .integer(limit)
        ]

        do {
            let items: [UserNotification] = try await client
                .rpc("fetch_notifications", params: params)
                .execute()
                .value
            notifications = items
            unreadCount = items.filter { $0.isUnread }.count
            PushNotificationService.shared.setBadge(unreadCount)
        } catch {
            print("⚠️ Failed to load notifications: \(error)")
        }
    }

    /// 未読件数のみ取得 (ベルバッジ更新用、軽量)
    func refreshUnreadCount() async {
        guard UserAuthService.shared.userId != nil else {
            unreadCount = 0
            return
        }

        do {
            let count: Int = try await client
                .rpc("fetch_unread_notification_count")
                .execute()
                .value
            unreadCount = count
            // アプリアイコンのバッジも同じ数に合わせる。ここがズレると
            // 「バッジは付いているのに開くと何も無い」で信用を失う
            PushNotificationService.shared.setBadge(count)
        } catch {
            print("⚠️ Failed to refresh unread count: \(error)")
        }
    }

    // MARK: - Mark Read

    /// 通知タブを開いた時に呼ぶ。全件既読化 + ローカル状態反映
    func markAllRead() async {
        guard UserAuthService.shared.userId != nil else { return }

        // 楽観 UI
        unreadCount = 0
        PushNotificationService.shared.clearBadge()

        do {
            _ = try await client
                .rpc("mark_all_notifications_read")
                .execute()
        } catch {
            print("⚠️ Failed to mark all read: \(error)")
        }
    }

    // MARK: - Reset

    /// サインアウト時にクリア
    func clear() {
        notifications = []
        unreadCount = 0
        PushNotificationService.shared.clearBadge()
    }
}
