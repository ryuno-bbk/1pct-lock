//
//  BlockingService.swift
//  AppBlocker
//
//  Service that coordinates the 3 modes (timer / schedule / location)
//  Each Manager has its own named store, so do not touch the store directly here
//

import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity

/// App block management service
final class BlockingService: ObservableObject {

    @MainActor static let shared = BlockingService()

    // MARK: - Published Properties

    /// Timer session (runs independently)
    @Published private(set) var timerSession: BlockSession?

    /// Schedule session (resident type)
    @Published private(set) var scheduleSession: BlockSession?

    /// Selected apps (shared by timer/schedule, location is managed separately inside LocationManager)
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection()

    /// Error message
    @Published var errorMessage: String?

    /// Flag for showing the "準備中" ("Preparing") overlay right after a lock starts.
    /// Mitigates the freeze when moving to the Home screen right after applying the shield (a heavy
    /// synchronous write on the main thread).
    /// User input is blocked during this time to give the system time to bring up enforcement.
    /// See startTimerBlockingWithSettle.
    @Published var isPreparingLock = false

    /// Whether any restriction is active
    var isBlocking: Bool {
        isTimerActive || isScheduleActive || isLocationActive
    }

    /// Whether the timer is active
    var isTimerActive: Bool {
        TimerManager.shared.isRunning
    }

    /// Whether the schedule is active (inside its time window and restricting)
    var isScheduleActive: Bool {
        ScheduleManager.shared.isShieldActive
    }

    /// Whether a schedule is configured (even outside its time window)
    var isScheduleConfigured: Bool {
        ScheduleManager.shared.isMonitoring
    }

    /// Whether the location lock is active (inside the geofence and restricting)
    var isLocationActive: Bool {
        LocationManager.shared.isShieldActive
    }

    // MARK: - Dependencies

    private let storage = AppGroupStorage.shared

    // MARK: - Init

    @MainActor
    private init() {
        restoreState()
    }

    // MARK: - Timer Methods (independent session)

    /// Start timer blocking
    @MainActor
    func startTimerBlocking(durationMinutes: Int) {
        guard !selectedApps.applicationTokens.isEmpty ||
              !selectedApps.categoryTokens.isEmpty else {
            errorMessage = "ブロックするアプリを選択してください"
            return
        }

        errorMessage = nil

        // Rotate to a new quote every time blocking starts
        QuoteService.shared.shuffleQuote()
        if let quote = QuoteService.shared.currentQuote {
            saveQuoteForShield(quote)
        }
        // Also update the pool for rotating quotes on every Shield display (avoids heavy JSON parsing in the
        // Extension)
        saveQuotePoolForShield()

        // Start the timer (TimerManager sets the shield on the timer named store)
        TimerManager.shared.startTimer(
            durationMinutes: durationMinutes,
            apps: selectedApps
        )

        // Save the session
        let config = TimerConfig(durationMinutes: durationMinutes)
        let session = BlockSession(mode: .timer, timerConfig: config)
        timerSession = session
        storage.saveTimerSession(session)

        // 🔴 Fix the unlock challenge with the settings at this point. Until this session ends,
        //    loosening the settings has no effect (prevents escaping by lowering the settings during a lock)
        UnlockChallengeService.shared.beginSession(id: session.id)

        print("⏱️ Timer blocking started: \(durationMinutes) minutes")
    }

    /// Version of lock start with a settling grace period using the "準備中" ("Preparing") overlay.
    ///
    /// Background: applying the shield inside startTimerBlocking (`store.shield.applications = tokens`) is
    /// a heavy synchronous write on the main thread. If the user moves to the Home screen or backgrounds the
    /// app right after it is applied, it races with the system while the system brings up enforcement,
    /// and the app freezes.
    /// Mitigated by showing the spinner for ~3s, blocking input, and not letting the user cross that
    /// volatile window.
    ///
    /// Note: this does not help the Apple Extension cold-start freeze (= the Shield extension cold starts
    /// and freezes for a few seconds the moment a blocked app is opened, project_known_issues.md item B).
    /// That is an Apple structural limit in a different process at a different timing, and the main app's
    /// spinner cannot prevent it.
    /// If this function helps, it is evidence that we were looking at the "main thread hitch/spin-up
    /// race" (freeze ②).
    @MainActor
    func startTimerBlockingWithSettle(durationMinutes: Int) async {
        // Check preconditions before showing the spinner (if no apps are selected, exit with an error
        // immediately)
        guard !selectedApps.applicationTokens.isEmpty ||
              !selectedApps.categoryTokens.isEmpty else {
            errorMessage = "ブロックするアプリを選択してください"
            return
        }

        isPreparingLock = true
        // Yield one frame so the spinner is drawn first, then go into the heavy shield write
        await Task.yield()

        startTimerBlocking(durationMinutes: durationMinutes)

        // Hold until enforcement settles. Input is blocked by the overlay during this time to prevent the
        // transition race.
        // 3 seconds = the value where users feel "waiting this long does not freeze" (2026-07-07 real device
        // feedback)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        isPreparingLock = false
    }

    /// Stop timer blocking
    @MainActor
    func stopTimerBlocking() {
        TimerManager.shared.stopTimer()
        timerSession = nil
        storage.saveTimerSession(nil)
        UnlockChallengeService.shared.endSession()

        print("⏱️ Timer blocking stopped")
    }

    // MARK: - Schedule Methods (resident type)

    /// Add a schedule (multiple supported, the limit is ScheduleManager.maxSchedules)
    /// apps is a local selection only for schedules (2026-07-16 Fable review: stopped reusing the timer's
    /// selectedApps)
    @MainActor
    func startScheduleBlocking(config: ScheduleConfig, apps: FamilyActivitySelection) {
        // Rotate to a new quote every time blocking starts
        QuoteService.shared.shuffleQuote()
        if let quote = QuoteService.shared.currentQuote {
            saveQuoteForShield(quote)
        }
        // Also update the pool for rotating quotes on every Shield display (avoids heavy JSON parsing in the
        // Extension)
        saveQuotePoolForShield()

        do {
            try ScheduleManager.shared.addSchedule(
                config: config,
                apps: apps
            )

            // Save the session
            let session = BlockSession(mode: .schedule, scheduleConfig: config)
            scheduleSession = session
            storage.saveScheduleSession(session)

            print("📅 Schedule blocking started")
        } catch {
            errorMessage = error.localizedDescription
            print("❌ Schedule blocking failed: \(error)")
        }
    }

    /// Version of lock start with a settling grace period using the "準備中" ("Preparing") overlay (A-7).
    ///
    /// Same shape as startTimerBlockingWithSettle. Only when the Shield is applied immediately inside the
    /// time window do we hold until enforcement settles. A start outside the time window (only monitoring
    /// is registered, no shield is applied) has no heavy synchronous write, so a short wait is enough.
    @MainActor
    func startScheduleBlockingWithSettle(config: ScheduleConfig, apps: FamilyActivitySelection) async {
        isPreparingLock = true
        // Yield one frame so the spinner is drawn first, then go into the heavy shield write
        await Task.yield()

        startScheduleBlocking(config: config, apps: apps)

        if ScheduleManager.shared.isShieldActive {
            // Only when the shield was applied immediately inside the time window, hold for 3 seconds like the
            // timer to avoid the race
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        } else {
            // A start outside the time window only registers monitoring (no heavy shield write), so a short wait
            // is enough
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        isPreparingLock = false
    }

    /// Update schedule settings (target found by id)
    /// apps is a local selection only for schedules (2026-07-16 Fable review: stopped reusing the timer's
    /// selectedApps)
    @MainActor
    func updateScheduleBlocking(config: ScheduleConfig, apps: FamilyActivitySelection) {
        do {
            try ScheduleManager.shared.updateSchedule(
                config: config,
                apps: apps
            )

            // Update the session
            let session = BlockSession(mode: .schedule, scheduleConfig: config)
            scheduleSession = session
            storage.saveScheduleSession(session)

            print("📅 Schedule blocking updated")
        } catch {
            errorMessage = "スケジュールの更新に失敗しました: \(error.localizedDescription)"
            print("❌ Schedule update failed: \(error)")
        }
    }

    /// Delete one schedule
    @MainActor
    func removeScheduleBlocking(id: UUID) {
        ScheduleManager.shared.removeSchedule(id: id)

        if ScheduleManager.shared.configs.isEmpty {
            scheduleSession = nil
            storage.saveScheduleSession(nil)
        }

        print("📅 Schedule removed")
    }

    /// Stop all schedule blocking (for wiping everything, e.g. on sign-out)
    @MainActor
    func stopScheduleBlocking() {
        ScheduleManager.shared.stopMonitoring()
        scheduleSession = nil
        storage.saveScheduleSession(nil)

        print("📅 Schedule blocking stopped")
    }

    // MARK: - Location Methods

    /// The location lock is applied/removed automatically by LocationManager on CLLocationManager
    /// geofence events. This only provides the entry point to "save the selection of apps to lock".
    @MainActor
    func saveLocationApps(_ selection: FamilyActivitySelection) {
        LocationManager.shared.saveSelection(selection)
    }

    // MARK: - Location Methods (wrappers with settle, from the freeze investigation 2026-07-15)
    //
    // Toggling/adding inside a geofence ran a heavy synchronous write to the store in the same runloop
    // tick as the tap, ran straight into the enforcement start-up race that the timer avoids with settle
    // (A-7), and caused a freeze + the default Shield being shown. Apply the same protection as
    // timer/schedule

    /// Toggle a place enabled/disabled (with settle)
    @MainActor
    func toggleLocationWithSettle(_ location: RegisteredLocation) async {
        // Wait for the in-region evaluation only when turning it ON. toggleLocation flips isEnabled, so
        // a location that is still OFF when passed in = the case of turning it ON
        await runLocationMutationWithSettle(waitsForEvaluation: !location.isEnabled) {
            LocationManager.shared.toggleLocation(location)
        }
    }

    /// Add a place (with settle, because being inside the added place's region applies the Shield
    /// immediately)
    @MainActor
    func addLocationWithSettle(_ location: RegisteredLocation) async {
        await runLocationMutationWithSettle {
            LocationManager.shared.addLocation(location)
        }
    }

    /// Update a place (with settle)
    @MainActor
    func updateLocationWithSettle(_ location: RegisteredLocation) async {
        // updateLocation does not request an in-region evaluation (it only re-registers the geofence), so do
        // not wait
        await runLocationMutationWithSettle(waitsForEvaluation: false) {
            LocationManager.shared.updateLocation(location)
        }
    }

    @MainActor
    private func runLocationMutationWithSettle(waitsForEvaluation: Bool = true, _ mutation: () -> Void) async {
        // So the quote pool always exists when the Shield extension cold starts (same as at timer/schedule
        // start. Only location was not doing it)
        saveQuotePoolForShield()

        isPreparingLock = true
        // Yield one frame so the spinner is drawn first, then go into the heavy shield write
        await Task.yield()

        mutation()

        // The in-region evaluation is async and driven by a location fix arriving (up to ~12 seconds with
        // retries), so the isShieldActive sync check right after always looked "not applied" and the spinner
        // vanished instantly.
        // Stop waiting when the evaluation resolves or when the Shield gets applied first through requestState.
        // OFF/edit (waitsForEvaluation: false) are actions that do not request an evaluation, so
        // they inherit the resolution of the preceding chain and do not wait.
        //
        // ⚠️ The limit is 6 seconds. PreparingLockOverlay takes all taps on the full screen, so waiting the
        // full retry length (12 seconds) cannot be told apart from a freeze (turning ON a lock for "a place you
        // are not at now" while indoors = a very normal action hits this). Even if we stop at 6 seconds,
        // applying the Shield itself still runs asynchronously when the evaluation resolves, so the lock does
        // not fail to apply
        if waitsForEvaluation {
            let deadline = Date().addingTimeInterval(6)
            while LocationManager.shared.isEvaluatingRegion
                  && !LocationManager.shared.isShieldActive
                  && Date() < deadline {
                if Task.isCancelled { break }   // Prevents try? from swallowing the error on cancel and turning this into a busy loop
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if LocationManager.shared.isShieldActive {
            // When the Shield was applied immediately, hold until enforcement settles (3 seconds, same as timer A-7)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        isPreparingLock = false
    }

    // MARK: - Utility Methods

    /// Reset the selection
    func resetSelection() {
        selectedApps = FamilyActivitySelection()
    }

    /// Save the current quote for the Shield
    func saveQuoteForShield(_ quote: Quote) {
        let sharedQuote = SharedQuote(from: quote)
        storage.saveCurrentQuote(sharedQuote)
    }

    /// Write a quote pool to the App Group so the Shield can pick one at random on every display.
    /// With this the Extension never has to parse the 175-item JSON (the main cause of the 11-second cold
    /// start freeze), and the quote rotates every time the lock screen appears.
    /// Call it when any timer/schedule/location block starts, and also at launch
    func saveQuotePoolForShield() {
        // Shield UI upgrade (confirmed by the user 2026-07-16): the pool prefers "quotes the user liked".
        // Personal quotes appear under the dream. If there are no likes at all, use the old overall random
        // pool
        let liked = LikeService.shared.likedQuotes
        let pool: [SharedQuote]
        if liked.isEmpty {
            pool = QuoteService.shared.randomPool(count: 40).map { SharedQuote(from: $0) }
        } else {
            pool = liked.shuffled().prefix(40).map { SharedQuote(from: $0) }
        }
        storage.saveQuotePool(pool)
    }

    // MARK: - Private: Restore State

    @MainActor
    private func restoreState() {
        // Restore the timer session
        //
        // Note: referencing TimerManager.shared here is the trigger that first runs TimerManager's init
        // (= restoreTimerState, including expiry handling).
        // BlockingService.init → restoreState() is @MainActor and TimerManager.shared is also
        // @MainActor, so at the point of this reference, TimerManager's restore (if expired, including
        // removing the shield + storage.saveTimerSession(nil)) finishes first, and only then do
        // the checks below run. This order is intentional, do not change it.
        if let session = storage.getTimerSession(), session.isActive {
            // Reject a "ghost active session" where only the timerSession key remains even though TimerManager
            // is not actually running (= ended naturally/expired/stopped).
            // C-2 (a) made the expiry branches of timerCompleted() / restoreTimerState() call
            // saveTimerSession(nil), but as insurance in case it remains through an unexpected path,
            // cross-check here too.
            if TimerManager.shared.isRunning {
                timerSession = session
            } else {
                storage.saveTimerSession(nil)
            }
        }

        // Restore the schedule session
        if let session = storage.getScheduleSession(), session.isActive {
            scheduleSession = session
        }

        // Prefill the app selection used last time for the timer (2026-07-15: so the app selection at the end
        // of onboarding carries over to the next launch. Previously it was empty on every launch and had to be
        // picked again each time)
        if selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty,
           let defaults = UserDefaults(suiteName: AppGroupConstants.identifier),
           let data = defaults.data(forKey: AppGroupConstants.Keys.timerSelection),
           let saved = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = saved
        }
    }

    // MARK: - Initial Shared Selection (app selection at the end of onboarding)

    /// Save the apps chosen at the end of onboarding as the shared initial value for all 3 modes.
    /// After that, each mode's screen can change it separately (same as the old behavior)
    @MainActor
    func saveInitialSharedSelection(_ selection: FamilyActivitySelection) {
        selectedApps = selection

        // Timer: write directly to the timerSelection key (same encoding as TimerManager).
        // On the next launch the restoreState prefill above picks it up
        if let defaults = UserDefaults(suiteName: AppGroupConstants.identifier),
           let data = try? PropertyListEncoder().encode(selection) {
            defaults.set(data, forKey: AppGroupConstants.Keys.timerSelection)
            defaults.synchronize()
        }

        ScheduleManager.shared.saveSelectionToAppGroup(selection)
        LocationManager.shared.saveSelection(selection)

        print("✅ Initial shared selection saved to all 3 modes")
    }
}
