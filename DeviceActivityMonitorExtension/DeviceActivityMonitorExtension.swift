//
//  DeviceActivityMonitorExtension.swift
//  DeviceActivityMonitorExtension
//
//  Schedule-based shield control (multiple schedules supported since 2026-07-15)
//
//  activity name format:
//  - "AppBlocker.Schedule.<uuid>": per-schedule monitoring after multi-schedule support
//    (ScheduleManager.activityName(for:))
//  - "AppBlocker.Schedule"       : old single format (kept for backward compatibility, because it
//    can fire before migration)
//  The shield is the union in one named store, "schedule". On end, always check "whether another
//  enabled schedule is currently within its time window" before removing it (the one that ends first
//  must not clear the shield of a later one)
//

import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    /// Named store only for schedule mode
    /// ⚠️ The name must exactly match AppGroupConstants.Stores.schedule
    /// (hardcoded because the Extension is a separate target and may not be able to access AppGroupConstants)
    private let store = ManagedSettingsStore(named: .init("schedule"))

    /// H5: named store for the timer's OS backstop.
    /// ⚠️ The name must exactly match AppGroupConstants.Stores.timer / TimerManager.store
    private let timerStore = ManagedSettingsStore(named: .init("timer"))

    /// H5: activity name of the one-shot monitoring registered by TimerManager.
    /// ⚠️ Must exactly match TimerManager.timerActivityName ("AppBlocker.Timer")
    private let timerActivityRawValue = "AppBlocker.Timer"

    private let appGroupID = "group.com.ryunosuke.appblocker.shared"

    // Keep App Group keys in sync with AppGroupConstants (hardcoded because the Extension is a separate
    // target)
    private let scheduleActiveStartKey = "scheduleActiveStart"          // old single format
    private let scheduleActiveStartPrefix = "scheduleActiveStart_"     // after multi-schedule support: + <uuid>
    private let pendingBlockSessionsKey = "pendingBlockSessions"
    private let currentUserIdKey = "currentUserId"                      // mirror of the currently signed-in user UUID (lowercased) (H3)
    private let scheduleConfigKey = "scheduleConfig"                    // old single format
    private let scheduleConfigsKey = "scheduleConfigs"                  // after multi-schedule support (JSON array)

    /// C1: mirror of whether Pro blocking may run. Keep in sync with
    /// AppGroupConstants.Keys.proBlockingEntitled
    private let proBlockingEntitledKey = "proBlockingEntitled"

    private let legacyActivityRawValue = "AppBlocker.Schedule"
    private let activityRawValuePrefix = "AppBlocker.Schedule."

    // MARK: - Schedule Events

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        // H5: nothing is done here for the timer's OS backstop activity ("AppBlocker.Timer").
        // The timer's shield is already applied in-app by TimerManager (main app),
        // so the processing here is limited to schedule-only logic
        // (isScheduleActivity only targets the "AppBlocker.Schedule" prefix, so
        // "AppBlocker.Timer" never matches anyway, but this comment is kept to make the intent explicit)
        guard isScheduleActivity(activity) else { return }

        let id = scheduleId(from: activity)
        let configs = loadScheduleConfigs()

        // M27: if the previous intervalDidEnd was missing (because of the OS, etc.) and the previous day's
        // start key is still there, overwriting it with this new start key would erase that session from the
        // records entirely. Always fill it in before overwriting. Even if the start of this occurrence itself is
        // skipped by the later C1/weekday guards, cleaning up the previous day is needed independently, so it
        // is done here unconditionally
        flushDanglingSessionIfNeeded(id: id, configs: configs)

        // C1: if a fresh fetch has confirmed that the purchase has expired, do not apply the shield.
        // Also skip recording the session start (nothing is blocked, so it is not counted in the total time)
        guard isProBlockingEntitled() else {
            print("📅 Schedule interval started but Pro entitlement lapsed — skipping shield")
            return
        }

        // Weekday guard: the OS DeviceActivitySchedule cannot filter by weekday, so
        // do not apply the shield for occurrences whose interval start weekday is not in config.weekdays.
        // If the config cannot be read, apply it as before (a "schedule that silently does not run" goes
        // unnoticed by the user and is more dangerous than over-blocking, so the fail-safe leans to "apply")
        if !configs.isEmpty {
            if let id {
                guard let config = configs.first(where: { $0.id == id }) else {
                    // The array can be read but the id is not in it = a leftover event of a deleted schedule.
                    // This is not covered by the fail-safe (applying it would bring back a lock that should be deleted)
                    print("📅 Schedule interval started for unknown id \(id) — skipping shield")
                    return
                }
                if config.isEnabled == false {
                    // Disabled (safety net in case stopping monitoring was missed)
                    print("📅 Schedule interval started but config disabled — skipping shield")
                    return
                }
                if !isIntervalStartWeekdayAllowed(config: config) {
                    print("📅 Schedule interval started but weekday not in config.weekdays — skipping shield")
                    return
                }
            } else if let legacy = configs.first {
                // Old single-format activity name (before migration). Weekday guard with the first config, as before
                if !isIntervalStartWeekdayAllowed(config: legacy) {
                    print("📅 Legacy schedule interval started but weekday not allowed — skipping shield")
                    return
                }
            }
        }

        // Quote rotation now only uses the quote pool approach (21c76d1). The old rotateShieldQuote did
        // nothing because Quotes.json is not bundled, so it was dead code and was deleted (2026-07-16)
        applyShieldForSchedule()

        // Record the session start time (for the total lock time, per-schedule key)
        recordSessionStart(id: id)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // H5: the timer's OS backstop. If TimerManager finished naturally/was stopped manually while its
        // process was alive, the shield should already be removed and stopMonitoring done, but if the
        // deadline came while the process was dead, this is the last line of defense. Only clear the timer
        // named store, and never touch the schedule side's session records or union check (it is another mode).
        // The session record is written by TimerManager.restoreTimerState (the expired-restore path) on the
        // next app launch
        if activity.rawValue == timerActivityRawValue {
            clearTimerShield()
            return
        }

        guard isScheduleActivity(activity) else { return }

        let id = scheduleId(from: activity)

        // Add the session to the queue (Supabase sync happens when the main app launches)
        recordSessionEnd(id: id)

        // 🔥 Union of multiple schedules: if another enabled schedule is currently within its time window, keep
        // the shield.
        // (e.g. when 9-12 and 11-13 overlap, the end event at 12:00 must not clear the shield of 11-13)
        let configs = loadScheduleConfigs()
        let othersStillActive = configs.contains { config in
            config.isEnabled != false && config.id != id && isWithinSchedule(config: config)
        }
        if othersStillActive {
            print("📅 Schedule interval ended but another schedule is active — keeping shield")
            return
        }

        // Only clear the schedule named store (do not touch the timer/location stores)
        removeScheduleShield()
    }

    // MARK: - Activity Name Resolution

    private func isScheduleActivity(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue == legacyActivityRawValue || activity.rawValue.hasPrefix(activityRawValuePrefix)
    }

    /// Extract the uuid from "AppBlocker.Schedule.<uuid>". The old format ("AppBlocker.Schedule") gives nil
    private func scheduleId(from activity: DeviceActivityName) -> UUID? {
        let raw = activity.rawValue
        guard raw.hasPrefix(activityRawValuePrefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(activityRawValuePrefix.count)))
    }

    private func sessionStartKey(for id: UUID?) -> String {
        if let id {
            return scheduleActiveStartPrefix + id.uuidString
        }
        return scheduleActiveStartKey
    }

    // MARK: - Session Recording (total time aggregation)

    private func recordSessionStart(id: UUID?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: sessionStartKey(for: id))
    }

    /// - Parameter endedAt: end time of the session. Usually the time of the call (Date()), but
    ///   when filling in the missed previous day for M27 (flushDanglingSessionIfNeeded),
    ///   "the expected end time of that schedule" is passed explicitly
    private func recordSessionEnd(id: UUID?, endedAt: Date = Date()) {
        let key = sessionStartKey(for: id)
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let startTs = defaults.object(forKey: key) as? TimeInterval else {
            return
        }

        let endTs = endedAt.timeIntervalSince1970
        // Anything over 7 days (e.g. a leftover start key) is permanently rejected by validate_block_session
        // in 015, so the started_at side is trimmed to clamp both duration and timestamp.
        // ⚠️ Same correction as BlockSessionTracker.repairedInterval. Do not fix only one of them
        var clampedStartTs = startTs
        if endTs - clampedStartTs > 604800 {
            clampedStartTs = endTs - 604800
        }
        let duration = max(0, Int(endTs - clampedStartTs))
        guard duration > 0 else {
            defaults.removeObject(forKey: key)
            return
        }

        var entry: [String: Any] = [
            "entry_id": UUID().uuidString,   // for individual deletion after flush (in sync with BlockSessionTracker, H2/H3)
            "mode": "schedule",
            "started_at": clampedStartTs,
            "ended_at": endTs,
            "duration_seconds": duration,
            "status": "completed"
        ]
        // H3: stamp the currently signed-in user (the main app has mirrored it to the currentUserId key).
        // If there is no mirror (signed out), it is queued without user_id and discarded on flush
        if let uid = defaults.string(forKey: currentUserIdKey) {
            entry["user_id"] = uid
        }

        var queue = defaults.array(forKey: pendingBlockSessionsKey) as? [[String: Any]] ?? []
        queue.append(entry)
        defaults.set(queue, forKey: pendingBlockSessionsKey)
        defaults.removeObject(forKey: key)
    }

    // MARK: - M27: prevent losing the previous day's session

    /// Called before writing a new start key in intervalDidStart. If the start key of a previous occurrence
    /// that was not closed (= intervalDidEnd was missing) is still there, fill it in as a completed session
    /// with "the expected end time of that schedule" and queue it (reusing recordSessionEnd as is, so the
    /// entry_id/user_id stamp pattern and the 7-day clamp are followed exactly).
    /// If no start key is left, do nothing (the normal path returns here immediately)
    private func flushDanglingSessionIfNeeded(id: UUID?, configs: [ScheduleConfigMirror]) {
        let key = sessionStartKey(for: id)
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let startTs = defaults.object(forKey: key) as? TimeInterval else {
            return
        }

        let startedAt = Date(timeIntervalSince1970: startTs)
        let config = id != nil ? configs.first(where: { $0.id == id }) : configs.first
        let expectedEnd = expectedEndDate(startedAt: startedAt, config: config)

        print("⚠️ M27: dangling schedule session found (\(key)) at new intervalDidStart — flushing as completed before overwrite")
        recordSessionEnd(id: id, endedAt: expectedEnd)
    }

    /// Calculates the expected end time of the occurrence from the start time + the length of the schedule
    /// window (endHour:endMinute - startHour:startMinute. +24h if it crosses midnight and end <= start).
    /// If the config is not found / the window length is abnormal, clamp to start + 24h on the safe side.
    /// Also clamp so it is never later than "now" (when a new intervalDidStart fires, the previous day should
    /// always be in the past, but this guards against abnormal cases such as a corrupted config)
    private func expectedEndDate(startedAt: Date, config: ScheduleConfigMirror?) -> Date {
        let fallback = startedAt.addingTimeInterval(86400) // safe-side clamp (24h)
        guard let config else { return min(fallback, Date()) }

        let startMinutes = config.startHour * 60 + config.startMinute
        let endMinutes = config.endHour * 60 + config.endMinute
        let windowMinutes = endMinutes > startMinutes
            ? (endMinutes - startMinutes)
            : (endMinutes + 24 * 60 - startMinutes)

        guard windowMinutes > 0 else { return min(fallback, Date()) }

        let candidate = startedAt.addingTimeInterval(TimeInterval(windowMinutes * 60))
        return min(candidate, Date(), fallback)
    }

    // MARK: - Shield Methods

    private func applyShieldForSchedule() {
        guard let selection = loadSelection(forKey: "scheduleSelection") else { return }
        applyShield(selection: selection)
    }

    private func applyShield(selection: FamilyActivitySelection) {
        // Categories and individual apps can be used together (union). The old "category first" branch was a
        // hole where individual apps were not blocked when both were selected (2026-07-16 Fable review)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    /// Remove the shield only from the schedule named store.
    /// timer/location are separate named stores and are not affected (prevents unlocking the timer as
    /// collateral)
    private func removeScheduleShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    /// H5: clear only the timer-only named store ("timer").
    /// Do not touch the schedule/location named stores (prevents collateral unlocks across modes).
    /// Can be called idempotently even when TimerManager already did removeShield (assigning nil is harmless)
    private func clearTimerShield() {
        timerStore.shield.applications = nil
        timerStore.shield.applicationCategories = nil
        print("⏱️ Timer OS backstop fired — timer shield cleared")
    }

    // MARK: - Storage

    private func loadSelection(forKey key: String) -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    /// C1: whether Pro blocking may run, mirrored to the App Group by the main app.
    /// Key not set = not confirmed, which falls to "allowed" (so Pro users launching offline are not
    /// unlocked by mistake).
    /// When the user purchases again, the main app sets the mirror back to true, so it comes back
    /// automatically from the next interval
    private func isProBlockingEntitled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return true }
        return (defaults.object(forKey: proBlockingEntitledKey) as? Bool) ?? true
    }

    // MARK: - Schedule Config Mirror (for the weekday guard / union check)

    /// Codable struct that is a minimal mirror of the main app's ScheduleConfig (Core/Models/BlockMode.swift).
    /// The Extension is a separate target and cannot access the ScheduleConfig type directly, so
    /// the fields (id/startHour/startMinute/endHour/endMinute/weekdays/isEnabled) are synced by hand.
    /// id/isEnabled do not exist in data saved in the old single format, so they are Optional.
    /// ⚠️ Importing SwiftUI is forbidden (Extension memory budget), so use only Foundation's Codable
    private struct ScheduleConfigMirror: Codable {
        let id: UUID?
        let startHour: Int
        let startMinute: Int
        let endHour: Int
        let endMinute: Int
        let weekdays: [Int] // 1=Sunday, 2=Monday, ... 7=Saturday
        let isEnabled: Bool?
    }

    /// Decode the schedule settings in the App Group.
    /// Prefer the multi format (scheduleConfigs, JSON array), fall back to the old single format
    /// (scheduleConfig)
    private func loadScheduleConfigs() -> [ScheduleConfigMirror] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }

        if let data = defaults.data(forKey: scheduleConfigsKey),
           let configs = try? JSONDecoder().decode([ScheduleConfigMirror].self, from: data) {
            return configs
        }

        if let data = defaults.data(forKey: scheduleConfigKey),
           let legacy = try? JSONDecoder().decode(ScheduleConfigMirror.self, from: data) {
            return [legacy]
        }

        return []
    }

    /// Whether the weekday of the interval start date is in config.weekdays.
    /// If it crosses midnight (start > end) and the current time is before endTime, this interval
    /// started "yesterday", so check with yesterday's weekday.
    /// ⚠️ Keep this check logic aligned with the same idea as ScheduleManager.isWithinSchedule
    /// (AppBlocker/Core/Services/ScheduleManager.swift). If only one side is fixed, the extension and the
    /// main app disagree on schedules that cross midnight
    private func isIntervalStartWeekdayAllowed(config: ScheduleConfigMirror) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday else {
            // Cannot determine (abnormal case) → fail-safe leans to applying
            return true
        }

        let currentTime = hour * 60 + minute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute
        let isOvernight = startTime > endTime

        if isOvernight && currentTime < endTime {
            // This interval started on the previous day → check with yesterday's weekday
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                return config.weekdays.contains(weekday)
            }
            let yesterdayWeekday = calendar.component(.weekday, from: yesterday)
            return config.weekdays.contains(yesterdayWeekday)
        } else {
            return config.weekdays.contains(weekday)
        }
    }

    /// Whether the current time is within the config's time window (including weekday).
    /// ⚠️ Same algorithm as ScheduleManager.isWithinSchedule. Do not fix only one of them
    private func isWithinSchedule(config: ScheduleConfigMirror) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday else {
            return false
        }

        let currentTime = hour * 60 + minute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute

        if startTime < endTime {
            // Schedule within one day (e.g. 09:00 - 17:00) → check with today's weekday
            guard config.weekdays.contains(weekday) else { return false }
            return currentTime >= startTime && currentTime < endTime
        } else {
            // Schedule that crosses midnight (e.g. 22:00 - 07:00)
            if currentTime >= startTime {
                return config.weekdays.contains(weekday)
            } else if currentTime < endTime {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                    return config.weekdays.contains(weekday)
                }
                let yesterdayWeekday = calendar.component(.weekday, from: yesterday)
                return config.weekdays.contains(yesterdayWeekday)
            } else {
                return false
            }
        }
    }
}
