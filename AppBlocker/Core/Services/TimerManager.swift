//
//  TimerManager.swift
//  AppBlocker
//
//  Timer block management service
//  Blocks only for the specified time, and unlocks automatically when the time is up
//

import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity
import UIKit

/// Timer block management service
final class TimerManager: ObservableObject {

    @MainActor static let shared = TimerManager()

    // MARK: - Published Properties

    /// Remaining time (seconds)
    @Published private(set) var remainingSeconds: Int = 0

    /// Whether the timer is running
    @Published private(set) var isRunning: Bool = false

    /// Current settings
    @Published private(set) var currentConfig: TimerConfig?

    /// Time the timer ended naturally (not updated by a manual stop with stopTimer()).
    /// Views that want to watch the "end event", such as the toast shown during a continued lock,
    /// subscribe to it with onChange.
    @Published private(set) var didCompleteAt: Date?

    /// Actual lock time (seconds) of the most recent naturally completed session. Updated together with
    /// didCompleteAt. SessionCompleteView uses it for the main number. Not updated by a manual stop.
    @Published private(set) var lastCompletedDuration: TimeInterval?

    // MARK: - Private Properties

    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.timer))
    private let storage = AppGroupStorage.shared
    private var timer: Timer?
    private var endTime: Date?
    private var sessionStartedAt: Date?

    private let appGroupID = AppGroupConstants.identifier
    private let selectionKey = AppGroupConstants.Keys.timerSelection

    // MARK: - H5: OS backstop (for expiry while the process is dead)

    /// One-shot (repeats: false) DeviceActivity monitoring only for the timer.
    /// A safety net so that even if the time expires while the app is not running, the Extension's
    /// intervalDidEnd (the branch that clears the timer named store) can remove the shield on the OS side.
    /// ⚠️ This string must be hardcoded and kept in sync in DeviceActivityMonitorExtension.swift
    /// (the Extension is a separate target and cannot access this constant directly)
    private static let timerActivityName = DeviceActivityName("AppBlocker.Timer")
    private let activityCenter = DeviceActivityCenter()

    /// Detect returning to the foreground and compare with endTime immediately, without waiting for the
    /// next Timer tick. Even if the RunLoop was stopped for a long time in the background, expiry can be
    /// detected right after returning (H4)
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Init

    @MainActor
    private init() {
        // Restore the saved timer
        restoreTimerState()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncRemainingFromEndTime()
        }
    }

    // MARK: - Public Methods

    /// Start the timer
    func startTimer(
        durationMinutes: Int,
        apps: FamilyActivitySelection,
        onComplete: (() -> Void)? = nil
    ) {
        // Save the app selection
        saveSelectionToAppGroup(apps)

        // Record the session start time (for the total lock time aggregation)
        sessionStartedAt = Date()

        // Compute the end time (H4: the remaining time is always derived from this endTime with the wall
        // clock. No tick subtraction)
        let plannedEndTime = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        endTime = plannedEndTime
        remainingSeconds = durationMinutes * 60

        // Save the settings
        let config = TimerConfig(durationMinutes: durationMinutes)
        currentConfig = config
        saveTimerConfig(config)

        // Apply the shield
        applyShield(apps: apps)

        // H5: also register a one-shot monitor on the OS side, in case the time expires while the process is dead
        registerOSBackstop(endTime: plannedEndTime)

        // Start the timer
        isRunning = true
        startCountdownTimer(onComplete: onComplete)

        print("⏱️ Timer started: \(durationMinutes) minutes")
    }

    /// Stop the timer (manual stop)
    func stopTimer() {
        timer?.invalidate()
        timer = nil

        // H5: also clean up the OS backstop monitor (if left, it expires naturally with repeats:false, but this
        // avoids it staying alive uselessly for the time cut short by the early stop)
        clearOSBackstop()

        // Remove the shield
        removeShield()

        // Record the session as "aborted".
        // Take plannedSeconds now, before the reset (while currentConfig is still alive)
        if let startedAt = sessionStartedAt {
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: Date(),
                status: "aborted",
                plannedSeconds: (currentConfig?.durationMinutes).map { $0 * 60 }
            )
            sessionStartedAt = nil
        }

        // Reset the state
        isRunning = false
        remainingSeconds = 0
        endTime = nil
        currentConfig = nil

        // Delete the saved data
        clearTimerConfig()

        print("⏱️ Timer stopped manually")
    }

    /// Format the remaining time (MM:SS)
    func formattedRemainingTime() -> String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Format the remaining time (HH:MM:SS)
    func formattedRemainingTimeLong() -> String {
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    // MARK: - Private Methods

    /// Start the countdown timer
    ///
    /// H4: the tick is used only to update the display; the "truth" of the remaining time is derived from
    /// endTime (wall clock) every time.
    /// The old implementation subtracted 1 from remainingSeconds on every tick, so while RunLoop/Timer were
    /// stopped in the background it did not decrease, and the actual unlock time drifted later than planned
    /// by that amount.
    private func startCountdownTimer(onComplete: (() -> Void)? = nil) {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncRemainingFromEndTime(onComplete: onComplete)
        }

        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Align the display to endTime right after start/return (do not wait for the next 1-second tick)
        syncRemainingFromEndTime(onComplete: onComplete)
    }

    /// H4: sync the remaining time with a wall-clock calculation from endTime.
    /// - Shared path, called both from the normal tick and from the return-to-foreground notification.
    /// - If endTime has passed (including the time the tick was stopped in the background), go straight to
    ///   completion.
    private func syncRemainingFromEndTime(onComplete: (() -> Void)? = nil) {
        guard isRunning, let endTime = endTime else { return }

        let remaining = endTime.timeIntervalSinceNow
        if remaining > 0 {
            remainingSeconds = Int(remaining.rounded(.up))
        } else {
            remainingSeconds = 0
            timerCompleted(onComplete: onComplete)
        }
    }

    /// Handling when the timer ends
    private func timerCompleted(onComplete: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil

        // H5: it completed naturally, so also explicitly clean up the one-shot monitor on the OS side
        clearOSBackstop()

        // Remove the shield
        removeShield()

        // Record the session as "completed".
        // H4: endedAt uses the fixed endTime (planned end time), not the detection time (Date()).
        // Even if detection is delayed in the background, the recorded duration is not inflated by that amount
        // (same idea as the expired-restore branch of restoreTimerState: endedAt: config.endTime)
        if let startedAt = sessionStartedAt {
            let endedAt = endTime ?? Date()
            // Fix the actual lock time for SessionCompleteView (set before didCompleteAt fires)
            lastCompletedDuration = endedAt.timeIntervalSince(startedAt)
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: endedAt,
                status: "completed",
                plannedSeconds: (currentConfig?.durationMinutes).map { $0 * 60 }
            )
            sessionStartedAt = nil
        }

        // Reset the state
        isRunning = false
        remainingSeconds = 0
        endTime = nil
        currentConfig = nil

        // Delete the saved data
        clearTimerConfig()

        // Also delete the timerSession key on the BlockingService side.
        // If it is left, on the next launch BlockingService.restoreState restores a ghost state where
        // "the timer is not running but an active session exists".
        storage.saveTimerSession(nil)

        // Fire the natural end event (kept separate from a manual stop)
        didCompleteAt = Date()

        onComplete?()

        print("⏱️ Timer completed - Shield removed")
    }

    /// Apply the shield
    private func applyShield(apps: FamilyActivitySelection) {
        // Categories and individual apps can be used together (union). The old "category first" branch was a
        // hole where individual apps were not blocked when both were selected (2026-07-16 Fable review)
        store.shield.applications = apps.applicationTokens.isEmpty ? nil : apps.applicationTokens
        store.shield.applicationCategories = apps.categoryTokens.isEmpty ? nil : .specific(apps.categoryTokens)

        print("✅ Shield applied: \(apps.applicationTokens.count) apps, \(apps.categoryTokens.count) categories")
    }

    /// Remove the shield
    private func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        print("✅ Timer shield removed")
    }

    /// H5: register the OS-side backstop for expiry while the process is dead.
    /// Register a one-shot (repeats: false) monitor with DeviceActivityCenter, so that the Extension's
    /// intervalDidEnd (the branch that clears the timer named store) can remove the shield on time whether
    /// the app is alive or not.
    /// iOS DeviceActivity monitoring has a minimum interval (15 minutes), and registration can throw for
    /// shorter timers. In that case we only swallow it with a log, and accept the in-app wall-clock
    /// handling (H4) as the main path (the same protection level as now, not a regression).
    private func registerOSBackstop(endTime: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        let endComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: endTime
        )

        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )

        do {
            try activityCenter.startMonitoring(Self.timerActivityName, during: schedule)
            print("✅ Timer OS backstop registered (ends \(endTime))")
        } catch {
            print("⚠️ Timer OS backstop registration failed (falling back to in-app wall clock only): \(error)")
        }
    }

    /// H5: clean up the OS backstop monitor. Call this on every manual stop, natural completion and expired
    /// restore of the timer
    private func clearOSBackstop() {
        activityCenter.stopMonitoring([Self.timerActivityName])
    }

    /// Restore the timer state (on app relaunch)
    private func restoreTimerState() {
        guard let config = loadTimerConfig() else {
            clearTimerConfig()
            return
        }

        // Case where the timer ended while the app was killed/suspended:
        // the shield stays as an OS setting, so if we do not remove it here, it becomes a permanent block
        if config.isExpired {
            removeShield()
            // H5: even on the expired-restore path (= a case where either H4's wall clock or the OS backstop may
            // already have handled it), clean up the one-shot monitor on the OS side if it remains (prevents
            // double registration)
            clearOSBackstop()
            let startedAt = config.endTime.addingTimeInterval(-TimeInterval(config.durationMinutes * 60))
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: config.endTime,
                status: "completed",
                plannedSeconds: config.durationMinutes * 60
            )
            clearTimerConfig()
            // Like timerCompleted(), also delete the timerSession key on the BlockingService side.
            // If this is skipped on the expired-restore path, BlockingService.restoreState restores the session of
            // "a timer that is not actually running" as a ghost.
            storage.saveTimerSession(nil)
            return
        }

        // Resume the timer
        currentConfig = config
        endTime = config.endTime
        remainingSeconds = config.remainingSeconds
        // Restore startedAt for the total record (endTime minus duration)
        sessionStartedAt = config.endTime.addingTimeInterval(-TimeInterval(config.durationMinutes * 60))

        if remainingSeconds > 0 {
            // Re-apply the shield with the saved app selection
            if let apps = loadSelectionFromAppGroup() {
                applyShield(apps: apps)
            }

            isRunning = true
            startCountdownTimer()

            print("⏱️ Timer restored: \(remainingSeconds) seconds remaining")
        }
    }

    // MARK: - App Group Storage

    private func saveSelectionToAppGroup(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: selectionKey)
            defaults.synchronize()
        } catch {
            print("❌ Failed to save timer selection: \(error)")
        }
    }

    private func loadSelectionFromAppGroup() -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else {
            return nil
        }

        do {
            return try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("❌ Failed to load timer selection: \(error)")
            return nil
        }
    }

    private func saveTimerConfig(_ config: TimerConfig) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: AppGroupConstants.Keys.timerConfig)
        defaults.synchronize()
    }

    private func loadTimerConfig() -> TimerConfig? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: AppGroupConstants.Keys.timerConfig),
              let config = try? JSONDecoder().decode(TimerConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func clearTimerConfig() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.removeObject(forKey: AppGroupConstants.Keys.timerConfig)
        defaults.removeObject(forKey: selectionKey)
        defaults.synchronize()
    }
}
