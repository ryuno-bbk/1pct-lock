//
//  NotificationService.swift
//  AppBlocker
//
//  Fetching in-app notifications (like / follow / comment / reply / comment_like) + unread
//  management. Push notifications are for a future implementation; this only covers the in-app
//  bell + notification list
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

    /// Fetch the notification list (newest first, up to 50)
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

    /// Fetch only the unread count (for updating the bell badge, lightweight)
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
            // Match the app icon badge to the same number. If they drift apart,
            // "the badge is there but opening shows nothing" loses the user's trust
            PushNotificationService.shared.setBadge(count)
        } catch {
            print("⚠️ Failed to refresh unread count: \(error)")
        }
    }

    // MARK: - Mark Read

    /// Call when the notifications tab is opened. Marks everything read + updates local state
    func markAllRead() async {
        guard UserAuthService.shared.userId != nil else { return }

        // Optimistic UI
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

    /// Clear on sign-out
    func clear() {
        notifications = []
        unreadCount = 0
        PushNotificationService.shared.clearBadge()
    }
}
