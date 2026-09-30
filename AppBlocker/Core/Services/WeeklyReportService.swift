//
//  WeeklyReportService.swift
//  AppBlocker
//
//  Fetching the weekly report (080_weekly_report.sql)
//
//  🔴 Zero new data collection. It only aggregates the existing block_sessions on the server side and
//     returns the result. Reports are not stored, so past ones are fetched again by changing weekOffset.
//
//  🔴 The report itself is not held in @Published.
//     This is a screen where several can be opened by push (history list → past report), so if it
//     were written back into one shared instance, the one opened later would overwrite the content of
//     the previous screen. The fetch result is kept in the caller's (View's) local state.
//     Only the list (history) has a single screen, so it can stay @Published.
//

import Foundation
import Combine
import Supabase

@MainActor
final class WeeklyReportService: ObservableObject {

    static let shared = WeeklyReportService()

    /// List of past reports (newest first, completed weeks only)
    @Published private(set) var history: [WeeklyReportSummary] = []
    @Published private(set) var isLoadingHistory = false

    private let client: SupabaseClient

    /// Have the server cut the week boundaries in the device's time zone.
    /// ⚠️ Passed the same way as get_streak_days in 016 (an invalid identifier falls back to UTC on the
    /// server side)
    private var timeZoneID: String { TimeZone.current.identifier }

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Fetch

    /// - Parameter weekOffset: how many weeks ago. 0 = the current week in progress, 1 = last week (default).
    ///   Both opening from a notification and the report screen default to 1 (the most recent completed week).
    /// - Returns: nil if it cannot be fetched (not signed in / network failure / 080 not applied)
    func fetchReport(weekOffset: Int = 1) async -> WeeklyReport? {
        guard UserAuthService.shared.userId != nil else { return nil }

        let params: [String: AnyJSON] = [
            "p_week_offset": .integer(max(0, weekOffset)),
            "p_tz": .string(timeZoneID)
        ]

        do {
            return try await client
                .rpc("get_weekly_report", params: params)
                .execute()
                .value
        } catch {
            print("⚠️ Failed to load weekly report: \(error)")
            return nil
        }
    }

    /// For the list in Settings → Weekly report
    func loadHistory(limit: Int = 12) async {
        guard UserAuthService.shared.userId != nil else {
            history = []
            return
        }

        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let params: [String: AnyJSON] = [
            "p_limit": .integer(limit),
            "p_tz": .string(timeZoneID)
        ]

        do {
            history = try await client
                .rpc("get_weekly_report_list", params: params)
                .execute()
                .value
        } catch {
            print("⚠️ Failed to load weekly report history: \(error)")
        }
    }

    /// Call on sign-out. Do not show the previous owner's reports to the next person who uses the device
    func clear() {
        history = []
    }
}
