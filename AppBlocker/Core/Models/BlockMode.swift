//
//  BlockMode.swift
//  AppBlocker
//
//  Restriction mode definitions - the 3 block modes
//

import Foundation
import SwiftUI

// MARK: - Block Mode

/// The 3 restriction modes
enum BlockMode: String, CaseIterable, Identifiable {
    /// Timer block - blocks for a set time (countdown)
    case timer = "timer"

    /// Schedule - blocks during time windows set with DeviceActivitySchedule
    case schedule = "schedule"

    /// Location lock - blocks when the user enters a specific place
    case location = "location"

    var id: String { rawValue }

    /// Display name (Japanese fallback)
    var displayName: String {
        L.blockModeDisplayName(self, .japanese)
    }

    /// Localized display name
    func displayName(lang: AppLanguage) -> String {
        L.blockModeDisplayName(self, lang)
    }

    /// Description (Japanese fallback)
    var description: String {
        L.blockModeDescription(self, .japanese)
    }

    /// Localized description
    func description(lang: AppLanguage) -> String {
        L.blockModeDescription(self, lang)
    }

    /// Detailed description (Japanese fallback)
    var detailDescription: String {
        L.blockModeDetail(self, .japanese)
    }

    /// Localized detailed description
    func detailDescription(lang: AppLanguage) -> String {
        L.blockModeDetail(self, lang)
    }

    /// Icon name (SF Symbols)
    var iconName: String {
        switch self {
        case .timer: return "stopwatch.fill"
        case .schedule: return "calendar.badge.clock"
        case .location: return "location.fill"
        }
    }

    /// Card background color (the brand is monochrome, so all 3 modes use a shared token)
    var accentColor: Color {
        switch self {
        case .timer: return AppColors.modeTimer
        case .schedule: return AppColors.modeSchedule
        case .location: return AppColors.modeLocation
        }
    }
}

// MARK: - Block Session

/// State of a block session
struct BlockSession: Identifiable, Codable {
    let id: UUID
    let mode: String
    let startDate: Date
    let endDate: Date?
    let isActive: Bool

    // For timer mode
    let timerConfig: TimerConfig?

    // For schedule mode
    let scheduleConfig: ScheduleConfig?

    init(
        id: UUID = UUID(),
        mode: BlockMode,
        startDate: Date = Date(),
        endDate: Date? = nil,
        isActive: Bool = true,
        timerConfig: TimerConfig? = nil,
        scheduleConfig: ScheduleConfig? = nil
    ) {
        self.id = id
        self.mode = mode.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
        self.timerConfig = timerConfig
        self.scheduleConfig = scheduleConfig
    }

    var blockMode: BlockMode? {
        BlockMode(rawValue: mode)
    }
}

// MARK: - Timer Config

/// Timer mode settings
struct TimerConfig: Codable {
    let durationMinutes: Int  // Block duration (minutes)
    let endTime: Date         // Scheduled end time

    init(durationMinutes: Int) {
        self.durationMinutes = durationMinutes
        self.endTime = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    init(durationMinutes: Int, endTime: Date) {
        self.durationMinutes = durationMinutes
        self.endTime = endTime
    }

    /// Remaining time (seconds)
    var remainingSeconds: Int {
        let remaining = Int(endTime.timeIntervalSinceNow)
        return max(0, remaining)
    }

    /// Whether the timer has finished
    var isExpired: Bool {
        remainingSeconds <= 0
    }
}

// MARK: - Schedule Config (Phase 4)

/// Schedule mode settings (several can be kept, the limit is ScheduleManager.maxSchedules)
///
/// ⚠️ Keep the fields in sync by hand with DeviceActivityMonitorExtension.ScheduleConfigMirror
/// (the Extension is a separate target and cannot import this type).
/// id/isEnabled were added with multi-schedule support (2026-07-15). They do not exist in data saved in
/// the old single format, so decodeIfPresent falls back (the id is assigned on migration, and
/// AppGroupStorage.getScheduleConfigs persists it right away in array form, so it is stable after that)
struct ScheduleConfig: Codable, Identifiable, Equatable {
    let id: UUID
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    let weekdays: [Int] // 1=Sunday, 2=Monday, ... 7=Saturday
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        weekdays: [Int] = [2, 3, 4, 5, 6], // Default: weekdays
        isEnabled: Bool = true
    ) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startHour = try container.decode(Int.self, forKey: .startHour)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endHour = try container.decode(Int.self, forKey: .endHour)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
        weekdays = try container.decode([Int].self, forKey: .weekdays)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

