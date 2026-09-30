//
//  WeeklyReport.swift
//  AppBlocker
//
//  Weekly report (return values of get_weekly_report / get_weekly_report_list in 080_weekly_report.sql)
//
//  🔴 The server does not store reports. They are recalculated from block_sessions every time.
//     Past reports are also produced just by calling the same RPC with a different weekOffset.
//

import Foundation

// MARK: - Decoding dates (date type)

/// The RPC returns Postgres `date` as a string like "2026-08-24" (no time and no time zone).
/// Supabase's default decoder expects an ISO8601 date-time, so it fails as is.
/// Here we receive it as a string and interpret it as a calendar date when displaying it.
enum WeekDay {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        // The week boundaries are cut on the server side using the device's time zone, so
        // interpret it as device local here too (interpreting it as UTC shifts it by one day)
        f.timeZone = TimeZone.current
        return f
    }()

    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        return parser.date(from: raw)
    }
}

// MARK: - The report itself

struct WeeklyReport: Decodable, Equatable {

    /// Whether the user has ever locked. If false, every item in the report is zero and the screen does
    /// not work
    let hasHistory: Bool

    /// "2026-08-24" format. Weeks start on Monday
    let weekStartRaw: String
    /// "2026-08-30" format. Sunday
    let weekEndRaw: String

    /// Whether the week is in progress. When true, the screen shows that it is an "interim result"
    let isCurrentWeek: Bool

    /// Lock seconds for that week
    let seconds: Int
    /// Number of sessions for that week
    let sessions: Int
    /// Lock seconds for the previous week
    let prevSeconds: Int
    /// Change vs last week (%). It cannot be defined if the previous week is 0 seconds, so nil
    let deltaPercent: Double?

    /// Rank for that week. nil for weeks where the population is below the threshold (hidden on the
    /// server side)
    let rank: Int?
    /// Top percentile for that week. Same as above
    let topPercent: Double?
    /// Number of people who locked for at least 1 second that week
    let activeUsers: Int

    /// Total lock seconds as of the end of that week
    let totalSeconds: Int
    /// Average of the last 4 weeks (weeks before the first session are excluded)
    let avg4Seconds: Int
    /// Seconds if the pace above continued for 1 year
    let projectionYearSeconds: Int

    /// Breakdown by mode ("timer" / "schedule" / "location").
    /// ❌ A per-app breakdown cannot be made (the Screen Time API does not give measured values to the app
    /// itself)
    let byMode: [String: Int]

    /// Seconds per weekday. Always 7 elements (Mon=0 to Sun=6)
    let days: [Int]

    var weekStart: Date? { WeekDay.date(from: weekStartRaw) }
    var weekEnd: Date? { WeekDay.date(from: weekEndRaw) }

    enum CodingKeys: String, CodingKey {
        case hasHistory            = "has_history"
        case weekStartRaw          = "week_start"
        case weekEndRaw            = "week_end"
        case isCurrentWeek         = "is_current_week"
        case seconds, sessions, rank, days
        case prevSeconds           = "prev_seconds"
        case deltaPercent          = "delta_percent"
        case topPercent            = "top_percent"
        case activeUsers           = "active_users"
        case totalSeconds          = "total_seconds"
        case avg4Seconds           = "avg4_seconds"
        case projectionYearSeconds = "projection_year_seconds"
        case byMode                = "by_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasHistory            = try c.decodeIfPresent(Bool.self, forKey: .hasHistory) ?? false
        weekStartRaw          = try c.decode(String.self, forKey: .weekStartRaw)
        weekEndRaw            = try c.decode(String.self, forKey: .weekEndRaw)
        isCurrentWeek         = try c.decodeIfPresent(Bool.self, forKey: .isCurrentWeek) ?? false
        seconds               = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        sessions              = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        prevSeconds           = try c.decodeIfPresent(Int.self, forKey: .prevSeconds) ?? 0
        deltaPercent          = try c.decodeIfPresent(Double.self, forKey: .deltaPercent)
        rank                  = try c.decodeIfPresent(Int.self, forKey: .rank)
        topPercent            = try c.decodeIfPresent(Double.self, forKey: .topPercent)
        activeUsers           = try c.decodeIfPresent(Int.self, forKey: .activeUsers) ?? 0
        totalSeconds          = try c.decodeIfPresent(Int.self, forKey: .totalSeconds) ?? 0
        avg4Seconds           = try c.decodeIfPresent(Int.self, forKey: .avg4Seconds) ?? 0
        projectionYearSeconds = try c.decodeIfPresent(Int.self, forKey: .projectionYearSeconds) ?? 0
        byMode                = try c.decodeIfPresent([String: Int].self, forKey: .byMode) ?? [:]
        let rawDays           = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        // The display side touches index 0..6 unconditionally, so always shape it into 7 elements here
        days = rawDays.count == 7 ? rawDays : Array(repeating: 0, count: 7)
    }

    // MARK: - Display rules

    /// 🔴 Whether the change vs last week may be shown as %.
    ///
    /// Production data really does have a case that returns **+6603.1%** (last week 2 hours → this week
    /// 133 hours). The number is correct, but it looks broken on screen, so show % only when both of these
    /// hold:
    ///   - The previous week has 10 minutes or more (no comparisons with too small a base)
    ///   - The change rate is under ±1000%
    /// Otherwise, fall back to comparing actual values ("last week 2 hours → this week 133 hours").
    var showsDeltaPercent: Bool {
        guard let d = deltaPercent else { return false }
        return prevSeconds >= 600 && abs(d) < 1000
    }

    /// Whether the previous week also has activity, so that the comparison itself is meaningful
    var hasComparison: Bool { prevSeconds > 0 }
}

// MARK: - One row of the history list

struct WeeklyReportSummary: Decodable, Equatable, Identifiable {
    /// How many weeks before this week. Passed to the RPC as is when reopening the report
    let weekOffset: Int
    let weekStartRaw: String
    let weekEndRaw: String
    let seconds: Int
    let sessions: Int

    var id: String { weekStartRaw }
    var weekStart: Date? { WeekDay.date(from: weekStartRaw) }
    var weekEnd: Date? { WeekDay.date(from: weekEndRaw) }

    enum CodingKeys: String, CodingKey {
        case weekOffset   = "week_offset"
        case weekStartRaw = "week_start"
        case weekEndRaw   = "week_end"
        case seconds, sessions
    }
}
