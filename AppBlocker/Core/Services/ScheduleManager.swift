//
//  ScheduleManager.swift
//  AppBlocker
//
//  Schedule management using DeviceActivitySchedule (multiple schedules supported 2026-07-15)
//

import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import Combine

enum ScheduleError: LocalizedError {
    case limitReached
    /// L14: extremely short/invalid schedule such as start=end (under ScheduleManager.minScheduleDurationMinutes)
    case tooShort

    var errorDescription: String? {
        // This is the service layer, so @AppStorage cannot be used. Read the in-app language setting
        // directly from UserDefaults
        let currentLang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue) ?? .english
        switch self {
        case .limitReached:
            // Wording is waiting for the user's review
            return currentLang == .japanese
                ? "スケジュールは最大 \(ScheduleManager.maxSchedules) 個までです"
                : "You can have up to \(ScheduleManager.maxSchedules) schedules"
        case .tooShort:
            return L.scheduleTooShort(ScheduleManager.minScheduleDurationMinutes, currentLang)
        }
    }
}

/// Schedule management service
///
/// Multiple schedule design (limit maxSchedules, app selection shared by all schedules):
/// - Each schedule issues DeviceActivityName("AppBlocker.Schedule.<uuid>") and registers it with the OS
/// - The shield is still one named store "schedule" as before. Applied if any schedule is inside its
///   time window, removed if all are outside (= union). The removal check must always confirm that
///   "no other schedule is active"
/// - iOS DeviceActivity allows about 20 activities per app. maxSchedules = 5 is well within that
final class ScheduleManager: ObservableObject {

    @MainActor static let shared = ScheduleManager()

    private let center = DeviceActivityCenter()
    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.schedule))
    private let storage = AppGroupStorage.shared

    /// Timer for periodic checks
    private var scheduleCheckTimer: Timer?

    /// Maximum number of schedules. Leaves room under the ~20 activity limit of DeviceActivity
    /// and keeps the list UI from breaking (confirmed by the user 2026-07-15)
    static let maxSchedules = 5

    /// L14: minimum length (minutes) accepted for a schedule. Rejects effectively zero or extremely
    /// short settings such as start=end
    static let minScheduleDurationMinutes = 15

    /// Monitoring identifier from the old single-schedule era. After migration, reconcileMonitoring stops it
    static let legacyActivityName = DeviceActivityName("AppBlocker.Schedule")

    /// Per-schedule monitoring identifier. Keep this prefix check in sync with DeviceActivityMonitorExtension
    static func activityName(for id: UUID) -> DeviceActivityName {
        DeviceActivityName("AppBlocker.Schedule.\(id.uuidString)")
    }

    /// Current list of schedule settings (Published)
    @Published private(set) var configs: [ScheduleConfig] = []

    /// Whether at least one schedule is registered
    @Published private(set) var isMonitoring: Bool = false

    /// Whether the Shield is currently applied
    @Published private(set) var isShieldActive: Bool = false

    @MainActor
    private init() {
        // Load the saved settings (the old single format is migrated to the array format here)
        configs = storage.getScheduleConfigs()

        // If there are saved schedules, restore the state
        restoreScheduleState()
    }

    /// Restore the schedule state at app launch
    private func restoreScheduleState() {
        restoreSkippedOccurrences()
        guard !configs.isEmpty else { return }

        isMonitoring = true

        // Reconcile the OS-side monitoring registrations with the desired state
        // (also stops the old "AppBlocker.Schedule" and self-heals registrations lost after a BG relaunch etc.)
        reconcileMonitoring()

        // Check whether the current time is inside any schedule and apply/remove the Shield
        // A-4/A-5: decide isShieldActive from the return value of applyShield (do not claim true when it bails)
        reconcileShieldNow()
        print("🔄 Schedule restored - \(configs.count) config(s), shield active: \(isShieldActive)")

        // Start the timer
        startScheduleCheckTimer()
    }

    // MARK: - Monitoring Reconcile

    /// Idempotent step that reconciles the OS DeviceActivity registrations with configs (enabled ones).
    /// - Stop extras (deleted/disabled/the legacy name of the old single format)
    /// - Register missing ones (enabled schedules whose registration has disappeared)
    /// Only touches names with the prefix "AppBlocker.Schedule" and leaves activities of other modes alone
    private func reconcileMonitoring() {
        let desiredByName = Dictionary(
            uniqueKeysWithValues: configs.filter(\.isEnabled)
                .map { (Self.activityName(for: $0.id).rawValue, $0) }
        )

        let currentScheduleActivities = center.activities
            .filter { $0.rawValue.hasPrefix("AppBlocker.Schedule") }

        // Stop extras (the legacy name is also dropped here)
        let extras = currentScheduleActivities.filter { desiredByName[$0.rawValue] == nil }
        if !extras.isEmpty {
            center.stopMonitoring(extras)
            print("🧹 Stopped stale schedule activities: \(extras.map(\.rawValue))")
        }

        // Register missing ones
        let currentNames = Set(currentScheduleActivities.map(\.rawValue))
        for (name, config) in desiredByName where !currentNames.contains(name) {
            do {
                try center.startMonitoring(DeviceActivityName(name), during: deviceActivitySchedule(for: config))
                print("✅ (Re)registered schedule activity: \(name)")
            } catch {
                print("❌ Failed to register schedule activity \(name): \(error)")
            }
        }
    }

    /// L14: actual length of the schedule (minutes). Takes crossing midnight into account (same idea as
    /// isWithinSchedule, already handled in 32e04ef).
    /// start == end is treated as effectively zero length (an invalid setting), not "24 hours".
    /// internal access because the UI side (ScheduleBlockView) also uses it.
    static func durationMinutes(for config: ScheduleConfig) -> Int {
        let start = config.startHour * 60 + config.startMinute
        let end = config.endHour * 60 + config.endMinute
        if start == end { return 0 }
        if start < end { return end - start }
        return (24 * 60 - start) + end
    }

    private func deviceActivitySchedule(for config: ScheduleConfig) -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(
                hour: config.startHour,
                minute: config.startMinute
            ),
            intervalEnd: DateComponents(
                hour: config.endHour,
                minute: config.endMinute
            ),
            repeats: true,
            warningTime: nil
        )
    }

    // MARK: - Public Methods (add/update/delete/toggle enabled)

    /// Add a schedule and start monitoring
    func addSchedule(
        config: ScheduleConfig,
        apps: FamilyActivitySelection
    ) throws {
        guard configs.count < Self.maxSchedules else {
            throw ScheduleError.limitReached
        }

        // L14: do not let extremely short/invalid schedules such as start=end be saved
        guard Self.durationMinutes(for: config) >= Self.minScheduleDurationMinutes else {
            throw ScheduleError.tooShort
        }

        // Save the selected apps (shared by all schedules, used in DeviceActivityMonitorExtension)
        saveSelectionToAppGroup(apps)

        // L10: configs with isEnabled=false do not register OS monitoring.
        // If they did, suppressing execution would depend on the mirror decode on the Extension side
        // (fail-open when it cannot decode), and blocking could run even for a disabled config.
        // Reflect into the array only after OS registration succeeds (do not leave a ghost config on failure)
        if config.isEnabled {
            try center.startMonitoring(
                Self.activityName(for: config.id),
                during: deviceActivitySchedule(for: config)
            )
        }

        configs.append(config)
        storage.saveScheduleConfigs(configs)
        isMonitoring = true

        // 🔥 Important: if the current time is inside a schedule, apply the Shield immediately
        reconcileShieldNow()

        // Start the periodic check timer (checks the schedule state every 15 seconds)
        startScheduleCheckTimer()

        print("✅ Schedule added (\(configs.count)/\(Self.maxSchedules)): \(config.startHour):\(config.startMinute) - \(config.endHour):\(config.endMinute)")
    }

    /// Update a schedule (live edit). Finds the target by id and re-registers only that activity
    func updateSchedule(
        config: ScheduleConfig,
        apps: FamilyActivitySelection
    ) throws {
        // L14: do not let extremely short/invalid schedules such as start=end be saved.
        // Validate before touching the existing monitoring, so invalid content does not break the existing
        // state
        guard Self.durationMinutes(for: config) >= Self.minScheduleDurationMinutes else {
            throw ScheduleError.tooShort
        }

        // L14b: keep the values before the change so we can roll back to
        // "original config + original monitoring state" on failure
        let previousConfig = configs.first(where: { $0.id == config.id })

        // A-6: before editing cuts monitoring, if a session is in progress, finalize it and queue it
        // (if it is missed, it disappears from the total lock time)
        flushActiveScheduleSession(id: config.id)

        // Stop monitoring only for the target schedule for now (does not remove the Shield)
        center.stopMonitoring([Self.activityName(for: config.id)])

        // Update the selected apps (shared by all schedules)
        saveSelectionToAppGroup(apps)

        if config.isEnabled {
            do {
                try center.startMonitoring(
                    Self.activityName(for: config.id),
                    during: deviceActivitySchedule(for: config)
                )
            } catch {
                // L14b: registering monitoring for the new config failed. The configs array has not been rewritten
                // yet, so if we restore monitoring for the original config and then rethrow, we end up with
                // "config unchanged, monitoring unchanged" (monitoring was stopped just before, so without restoring
                // here it becomes "config remains but monitoring stays stopped")
                if let previousConfig, previousConfig.isEnabled {
                    try? center.startMonitoring(
                        Self.activityName(for: previousConfig.id),
                        during: deviceActivitySchedule(for: previousConfig)
                    )
                }
                print("❌ Failed to register updated schedule activity, restored previous state: \(error)")
                throw error
            }
        }

        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        storage.saveScheduleConfigs(configs)
        isMonitoring = true

        // 🔥 Important: apply/remove the Shield to match the current time
        reconcileShieldNow()

        // Restart the timer if it was stopped
        if scheduleCheckTimer == nil {
            startScheduleCheckTimer()
        }

        print("✅ Schedule updated: \(config.startHour):\(config.startMinute) - \(config.endHour):\(config.endMinute)")
    }

    /// Delete one schedule
    func removeSchedule(id: UUID) {
        // A-6: before stopping monitoring, if a session is in progress, finalize it and queue it
        flushActiveScheduleSession(id: id)

        center.stopMonitoring([Self.activityName(for: id)])

        configs.removeAll { $0.id == id }
        storage.saveScheduleConfigs(configs)

        if configs.isEmpty {
            storage.removeScheduleConfigs()
            scheduleCheckTimer?.invalidate()
            scheduleCheckTimer = nil
            isMonitoring = false
        }

        // Apply/remove the Shield to match the remaining schedules
        reconcileShieldNow()

        print("✅ Schedule removed (\(configs.count)/\(Self.maxSchedules) remaining)")
    }

    /// Toggle a schedule enabled/disabled (keeps the config and only stops monitoring)
    func setScheduleEnabled(id: UUID, isEnabled: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        guard configs[index].isEnabled != isEnabled else { return }

        configs[index].isEnabled = isEnabled
        storage.saveScheduleConfigs(configs)

        // 🔴 Turning it back ON = a signal of "I want to block right now", so always discard the skip.
        //    Without this, even after "今日の分を終える" ("End today's session") → toggle ON,
        //    isWithinAnySchedule stays false and blocking does not start (real device report 2026-08-28)
        if isEnabled, skippedOccurrences.removeValue(forKey: id) != nil {
            persistSkippedOccurrences()
        }

        if isEnabled {
            do {
                try center.startMonitoring(
                    Self.activityName(for: id),
                    during: deviceActivitySchedule(for: configs[index])
                )
            } catch {
                print("❌ Failed to re-enable schedule: \(error)")
            }
        } else {
            flushActiveScheduleSession(id: id)
            center.stopMonitoring([Self.activityName(for: id)])
        }

        reconcileShieldNow()
        print("✅ Schedule \(id) enabled=\(isEnabled)")
    }

    /// Delete all schedules and stop monitoring (for wiping everything, e.g. on sign-out)
    func stopMonitoring() {
        // A-6: before stopping monitoring, if a session is in progress, finalize it and queue it
        for config in configs {
            flushActiveScheduleSession(id: config.id)
        }

        let names = configs.map { Self.activityName(for: $0.id) } + [Self.legacyActivityName]
        center.stopMonitoring(names)

        // Stop the timer
        scheduleCheckTimer?.invalidate()
        scheduleCheckTimer = nil

        // Remove the Shield
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        // Delete the settings
        storage.removeScheduleConfigs()
        configs = []
        isMonitoring = false
        isShieldActive = false

        print("✅ Schedule monitoring stopped (all)")
    }

    // MARK: - Shield Reconcile

    /// Start the periodic check timer
    private func startScheduleCheckTimer() {
        // Stop the existing timer
        scheduleCheckTimer?.invalidate()

        // Check the schedule state every 15 seconds (A-3: with the reconcile approach there is no risk of
        // flapping, and 5 seconds was wasteful, so the interval was relaxed to this for battery)
        scheduleCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkScheduleState()
            }
        }

        // Add to the RunLoop
        if let timer = scheduleCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Run the first check immediately
        DispatchQueue.main.async { [weak self] in
            self?.checkScheduleState()
        }
    }

    /// Check the schedule state and apply/remove the Shield as needed
    ///
    /// A-3: idempotent reconcile against the actual state of the store, not a diff against the in-memory
    /// isShieldActive flag. The flag-diff approach had a defect: right after a cold launch (isShieldActive
    /// initialized to false), it could not detect the case where only the store still had the previous
    /// shield, and left it as is.
    func checkScheduleState() {
        reconcileShieldNow()
    }

    /// Idempotent reconcile of the store's actual state against
    /// "is any enabled schedule inside its time window"
    private func reconcileShieldNow() {
        pruneSkippedOccurrences()
        // C1: while a purchase expiry is confirmed by a fresh fetch, do not run schedule blocking.
        // Do not touch isEnabled or the OS monitoring registration (if the mirror goes back to true, the next
        // reconcile restores it automatically).
        // If the mirror is undetermined (no key), lean to "allowed" to avoid wrongly unblocking on an
        // offline launch
        let desired = storage.isProBlockingEntitled() && isWithinAnySchedule()
        // Treat the actual state of the store (not the in-memory flag) as the truth
        let actuallyApplied = store.shield.applications != nil || store.shield.applicationCategories != nil

        if desired && !actuallyApplied {
            // Inside the schedule time but the store has no shield → apply
            print("⏰ Entering schedule time - Applying shield...")
            isShieldActive = applyShield()
            // Fix the unlock method at the moment blocking starts (it does not get looser after this)
            if isShieldActive { UnlockChallengeService.shared.beginSessionIfNeeded() }
            print("✅ Schedule check: Shield apply attempted (active: \(isShieldActive))")
            return
        }

        if !desired && actuallyApplied {
            // Outside the schedule time but a shield is still in the store → remove
            print("⏰ Leaving schedule time - Removing shield...")
            removeShield()
            isShieldActive = false
            // If a timer is running in parallel, do not erase the unlock method that one fixed
            if !TimerManager.shared.isRunning {
                UnlockChallengeService.shared.endSession()
            }
            print("✅ Schedule check: Shield removed")
            return
        }

        // They match → do not write, only align the flag with the actual state.
        // L3: assigning unconditionally every 15 seconds fires @Published even when the value has not
        // changed, and makes views that observe isShieldActive re-evaluate for nothing, so
        // a guard assigns only when the value actually changes
        if isShieldActive != actuallyApplied {
            isShieldActive = actuallyApplied
        }
    }

    /// Whether any enabled schedule is currently inside its time window
    func isWithinAnySchedule() -> Bool {
        // Schedules skipped with "今日の分を終える" ("End today's session") are excluded from blocking.
        // 🔴 Do not mix the skip into isWithinSchedule (the time check).
        //    That one must keep the same logic as the Extension, so the skip is layered on top
        configs.contains { $0.isEnabled && isWithinSchedule(config: $0) && !isSkipped(config: $0) }
    }

    // MARK: - End today's session (skip)
    //
    // End only the currently running occurrence without deleting the schedule itself.
    // Turning the toggle off also stops future occurrences, so these two are separate actions.
    //
    // 🔴 No conflict with the Extension:
    //   DeviceActivityMonitorExtension only touches the shield at the intervalDidStart /
    //   intervalDidEnd boundaries. Only the app's 15-second reconcile removes it in the middle of an
    //   interval, so as long as that reconcile looks at the skip, blocking does not come back.

    /// Skipped schedules (id → time of the skip). A concept that exists only inside the app
    private var skippedOccurrences: [UUID: Date] = [:]

    private static let skippedOccurrencesKey = "schedule.skippedOccurrences"

    /// End only the running occurrence. The schedule stays enabled and runs again next time
    func skipCurrentOccurrence(id: UUID) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        guard isWithinSchedule(config: config) else { return }

        // Finalize the running session first so the stats do not drift
        flushActiveScheduleSession(id: id)

        skippedOccurrences[id] = Date()
        persistSkippedOccurrences()
        reconcileShieldNow()
        print("⏭️ Schedule \(id) skipped for this occurrence")
    }

    /// Whether any schedule is blocking right now (skipped ones excluded)
    var hasRunningOccurrence: Bool {
        isShieldActive && isWithinAnySchedule()
    }

    /// Whether this schedule has skipped its current occurrence.
    /// It clears automatically when the interval ends (does not prevent the next start)
    func isSkipped(config: ScheduleConfig) -> Bool {
        guard let skippedAt = skippedOccurrences[config.id] else { return false }
        // Clear it once outside the interval. isWithinSchedule also handles crossing midnight
        guard isWithinSchedule(config: config) else { return false }
        // 🔴 For a schedule close to 24 hours, the condition above alone would keep it skipped forever,
        //    so also cap it by the schedule's length
        let duration = TimeInterval(Self.durationMinutes(for: config) * 60)
        guard duration > 0 else { return false }
        return Date().timeIntervalSince(skippedAt) < duration
    }

    /// Drop expired skips (so the dictionary does not keep growing)
    private func pruneSkippedOccurrences() {
        let before = skippedOccurrences.count
        skippedOccurrences = skippedOccurrences.filter { id, _ in
            guard let config = configs.first(where: { $0.id == id }) else { return false }
            return isSkipped(config: config)
        }
        if skippedOccurrences.count != before { persistSkippedOccurrences() }
    }

    private func persistSkippedOccurrences() {
        let raw = skippedOccurrences.reduce(into: [String: Double]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: Self.skippedOccurrencesKey)
    }

    /// 🔴 Restoring is required. If skips disappeared when the app restarts,
    ///    just killing and reopening the app would bring blocking back
    private func restoreSkippedOccurrences() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.skippedOccurrencesKey) as? [String: Double] else { return }
        skippedOccurrences = raw.reduce(into: [UUID: Date]()) { acc, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            acc[id] = Date(timeIntervalSince1970: entry.value)
        }
    }

    /// Check whether we are inside the current schedule time
    ///
    /// ⚠️ This check logic must be kept in sync with DeviceActivityMonitorExtension's isWithinSchedule /
    /// isIntervalStartWeekdayAllowed (DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.swift)
    /// Keep them in sync. If only one side is fixed, the main app and the extension disagree on schedules
    /// that cross midnight, and the flapping "the app shows inside the time window but the OS Shield is not
    /// applied (or the reverse)" comes back.
    func isWithinSchedule(config: ScheduleConfig) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let currentComponents = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let currentHour = currentComponents.hour,
              let currentMinute = currentComponents.minute,
              let weekday = currentComponents.weekday else {
            return false
        }

        let currentTime = currentHour * 60 + currentMinute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute

        if startTime < endTime {
            // Schedule within the same day (e.g. 09:00 - 17:00) → check with today's weekday
            guard config.weekdays.contains(weekday) else { return false }
            return currentTime >= startTime && currentTime < endTime
        } else {
            // Schedule that crosses midnight (e.g. 22:00 - 07:00)
            // currentTime >= startTime: tonight, still in today's weekday interval → check with today's weekday
            // currentTime < endTime: the date has changed, but the interval started "yesterday" → check with
            // yesterday's weekday
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

    /// Apply the Shield
    /// Set the Shield directly using ManagedSettingsStore
    /// - Returns: true if the shield was actually written. false if it bailed (permission not approved,
    ///   nothing selected, etc.)
    ///   (Callers must set isShieldActive from this return value. A-4: fixes the bug that treated a bail
    ///   as true)
    @discardableResult
    func applyShield() -> Bool {
        print("🔒 applyShield() called")

        // C1: do not write while an expiry is confirmed (covers call paths other than reconcileShieldNow)
        guard storage.isProBlockingEntitled() else {
            print("⚠️ applyShield: Pro entitlement lapsed - Shield not applied")
            return false
        }

        // If the Screen Time permission has expired or is not approved, writing to the store is not enforced.
        // Return false early to prevent "active only in appearance" (A-5)
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            print("⚠️ applyShield: Family Controls not approved - Shield not applied")
            return false
        }

        guard let selection = loadSelectionFromAppGroup() else {
            print("⚠️ No saved selection found in App Group (key: \(selectionKey))")
            return false
        }

        let appCount = selection.applicationTokens.count
        let categoryCount = selection.categoryTokens.count

        print("🔍 Applying shield - Apps: \(appCount), Categories: \(categoryCount)")

        if appCount == 0 && categoryCount == 0 {
            print("⚠️ No apps or categories selected - Shield not applied")
            return false
        }

        // Categories and individual apps can be combined (union). The old "category first" branch
        // was a hole where individual apps were not blocked when both were selected (2026-07-16 Fable review)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        print("✅ Shield set for \(categoryCount) categories, \(appCount) applications")

        print("🔒 Shield applied successfully!")
        return true
    }

    /// Remove the Shield
    func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        print("✅ Shield removed")
    }

    // MARK: - Session Recording (A-6: prevent losing sessions on edit/stop)

    /// If scheduleActiveStart_<uuid> in the App Group (the start time the Extension writes in
    /// intervalDidStart) is still there, queue [start, now) as a completed session so it is not lost.
    /// Call this at the start of updateSchedule / removeSchedule / disabling (always finalize before
    /// cutting monitoring).
    /// The "scheduleActiveStart" key from the old single-format era is also flushed along with it, as
    /// migration care
    private func flushActiveScheduleSession(id: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        let keys = [
            AppGroupConstants.Keys.scheduleActiveStartPrefix + id.uuidString,
            AppGroupConstants.Keys.scheduleActiveStart // legacy
        ]

        for key in keys {
            guard let startTs = defaults.object(forKey: key) as? TimeInterval else { continue }
            BlockSessionTracker.enqueueSession(
                mode: "schedule",
                startedAt: Date(timeIntervalSince1970: startTs),
                endedAt: Date(),
                status: "completed"
            )
            defaults.removeObject(forKey: key)
            print("📥 Flushed in-flight schedule session (\(key)) before edit/stop")
        }
    }

    // MARK: - App Group Storage

    private let appGroupID = AppGroupConstants.identifier
    private let selectionKey = AppGroupConstants.Keys.scheduleSelection

    /// Apply a change to the app selection (shared by all schedules).
    /// If the shield is active, also rewrite the store's contents with the new selection (reconcile only
    /// looks at on/off, so when only the selection changes, it stays on the old app set unless it is
    /// re-applied here explicitly)
    func updateSharedSelection(_ selection: FamilyActivitySelection) {
        saveSelectionToAppGroup(selection)
        if isShieldActive {
            isShieldActive = applyShield()
        }
    }

    /// Save the app selection (shared by all schedules). Public so that selection changes from the UI
    /// apply immediately
    func saveSelectionToAppGroup(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: selectionKey)
            defaults.synchronize()
        } catch {
            print("❌ Failed to save selection: \(error)")
        }
    }

    func loadSelectionFromAppGroup() -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else {
            return nil
        }

        do {
            return try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("❌ Failed to load selection: \(error)")
            return nil
        }
    }
}
