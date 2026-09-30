//
//  AppGroupStorage.swift
//  AppBlocker
//
//  Save and load data through the App Group
//

import Foundation

/// App Group UserDefaults wrapper
final class AppGroupStorage {

    static let shared = AppGroupStorage()

    private let userDefaults: UserDefaults?

    private init() {
        userDefaults = UserDefaults(suiteName: AppGroupConstants.identifier)
    }

    // MARK: - Quote

    /// Save the current quote
    /// Also writes an update timestamp for invalidating the Shield Extension's cache
    func saveCurrentQuote(_ quote: SharedQuote) {
        guard let data = try? JSONEncoder().encode(quote) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.currentQuote)
        userDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.Keys.quoteUpdatedAt)
        userDefaults?.synchronize()
    }

    /// Get the current quote
    func getCurrentQuote() -> SharedQuote? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.currentQuote),
              let quote = try? JSONDecoder().decode(SharedQuote.self, from: data) else {
            return nil
        }
        return quote
    }

    /// Save the quote pool for the Shield (the Extension picks 1 at random from it each time it is
    /// shown). This lets the Extension skip parsing the 175-item JSON entirely
    func saveQuotePool(_ quotes: [SharedQuote]) {
        guard !quotes.isEmpty, let data = try? JSONEncoder().encode(quotes) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.quotePool)
        userDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.Keys.quoteUpdatedAt)
        userDefaults?.synchronize()
    }

    // MARK: - Dream (for the Shield plan A subtitle)

    /// Mirror the user's "dream" to the App Group for the Shield Extension.
    /// nil or an empty string counts as not declared and the key itself is removed (the Extension
    /// decides by "no key → quote fallback")
    func saveUserDream(_ dream: String?) {
        let trimmed = dream?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            userDefaults?.set(trimmed, forKey: AppGroupConstants.Keys.userDream)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.userDream)
        }
        userDefaults?.synchronize()
    }

    /// Get the mirrored "dream". nil if not declared
    func getUserDream() -> String? {
        userDefaults?.string(forKey: AppGroupConstants.Keys.userDream)
    }

    // MARK: - Current User ID Mirror (for session attribution, H3)

    /// Mirror the UUID of the currently signed-in user to the App Group.
    /// Read by enqueue (main app / DeviceActivityMonitorExtension) to stamp user_id onto session rows.
    /// Pass nil only when sign-out is confirmed (removes the key). Saved lowercased
    /// (Supabase auth.uid() is lowercase, so this follows the same convention as SessionInsert)
    func saveCurrentUserId(_ userId: UUID?) {
        if let userId {
            userDefaults?.set(userId.uuidString.lowercased(), forKey: AppGroupConstants.Keys.currentUserId)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.currentUserId)
        }
        userDefaults?.synchronize()
    }

    // MARK: - Language Sync (for the Shield display language)

    /// Mirror the main app's display language ("japanese"/"english") so the Shield Extension can read it.
    /// Reuses the onboardingLanguage key that UsageReportExtension already reads, and overwrites it with
    /// the current value on every launch, so even if the language is changed in settings after
    /// onboarding, it reaches the Shield at the next launch (not fully real-time; a known limitation)
    func syncCurrentLanguage(isJapanese: Bool) {
        userDefaults?.set(isJapanese ? "japanese" : "english", forKey: AppGroupConstants.Keys.onboardingLanguage)
        userDefaults?.synchronize()
    }

    // MARK: - Onboarding diagnosis input (handed over to UsageReportExtension)

    /// Write the self-reported value and language before usageReveal is shown.
    /// The Report extension reads them and draws the "estimate vs measured" comparison inside the
    /// extension
    func saveOnboardingRevealInputs(estimateMinutes: Int, languageRaw: String) {
        userDefaults?.set(estimateMinutes, forKey: AppGroupConstants.Keys.onboardingEstimateMinutes)
        userDefaults?.set(languageRaw, forKey: AppGroupConstants.Keys.onboardingLanguage)
        userDefaults?.synchronize()
    }

    /// Write the usageReveal phase ("comparison"/"topApps").
    /// After writing it, slightly changing the filter triggers a re-query, and the extension re-reads
    /// this flag in makeConfiguration and switches the display
    func saveOnboardingRevealPhase(_ phase: String) {
        userDefaults?.set(phase, forKey: AppGroupConstants.Keys.onboardingRevealPhase)
        userDefaults?.synchronize()
    }

    // MARK: - Settings

    /// Save settings
    func saveSettings(_ settings: SharedSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.userSettings)
        userDefaults?.synchronize()
    }

    /// Get settings
    func getSettings() -> SharedSettings {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.userSettings),
              let settings = try? JSONDecoder().decode(SharedSettings.self, from: data) else {
            return SharedSettings()
        }
        return settings
    }

    // MARK: - Background Style

    /// Save the background style
    func saveBackgroundStyle(_ style: BackgroundStyle) {
        userDefaults?.set(style.rawValue, forKey: AppGroupConstants.Keys.backgroundStyle)
        userDefaults?.synchronize()
    }

    /// Get the background style
    func getBackgroundStyle() -> BackgroundStyle {
        guard let rawValue = userDefaults?.string(forKey: AppGroupConstants.Keys.backgroundStyle),
              let style = BackgroundStyle(rawValue: rawValue) else {
            return .solidBlack
        }
        return style
    }

    // MARK: - Block Session (Legacy)

    /// Save the block session (old API compatibility)
    func saveBlockSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.blockSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.blockSession)
        }
        userDefaults?.synchronize()
    }

    /// Get the block session (old API compatibility)
    func getBlockSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.blockSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Timer Session (independent session)

    /// Save the timer session
    func saveTimerSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.timerSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.timerSession)
        }
        userDefaults?.synchronize()
    }

    /// Get the timer session
    func getTimerSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.timerSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Schedule Session (always-on type)

    /// Save the schedule session
    func saveScheduleSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.scheduleSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleSession)
        }
        userDefaults?.synchronize()
    }

    /// Get the schedule session
    func getScheduleSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Schedule Configs (supports multiple, 2026-07-15)

    /// Save the schedule configs (array). The limit is enforced on the ScheduleManager side
    func saveScheduleConfigs(_ configs: [ScheduleConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.scheduleConfigs)
        userDefaults?.synchronize()
    }

    /// Get the schedule configs (array).
    /// If the old single format (scheduleConfig key) remains, wrap it in an array, persist it
    /// immediately, and delete the old key (the old format has no id, so the UUID changes on every
    /// decode. If it is not fixed here, the DeviceActivityName and the session record key drift on
    /// every launch)
    func getScheduleConfigs() -> [ScheduleConfig] {
        if let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleConfigs),
           let configs = try? JSONDecoder().decode([ScheduleConfig].self, from: data) {
            return configs
        }

        // Migration on read from the old single format
        if let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleConfig),
           let legacy = try? JSONDecoder().decode(ScheduleConfig.self, from: data) {
            let migrated = [legacy]
            saveScheduleConfigs(migrated)
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfig)
            userDefaults?.synchronize()
            return migrated
        }

        return []
    }

    /// Delete all schedule configs (also cleans up the old key)
    func removeScheduleConfigs() {
        userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfigs)
        userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfig)
    }

    // MARK: - Pro Blocking Entitlement Mirror (C1)

    /// Write the mirror of whether Pro blocking (schedule/location) may run.
    /// Only ProAccess.reconcileEntitlementMirror (expiry confirmed by a fresh fetch) may write false.
    /// true is also written by the positive direction of ProAccess.recompute (immediate restore right
    /// after purchase)
    func saveProBlockingEntitled(_ entitled: Bool) {
        userDefaults?.set(entitled, forKey: AppGroupConstants.Keys.proBlockingEntitled)
        userDefaults?.synchronize()
    }

    /// Get whether Pro blocking may run. Undetermined (no key) falls to true = allowed
    /// (so that a legitimate Pro user's blocking is not wrongly released on an offline launch or right
    /// after the first update)
    func isProBlockingEntitled() -> Bool {
        (userDefaults?.object(forKey: AppGroupConstants.Keys.proBlockingEntitled) as? Bool) ?? true
    }

    // MARK: - Clear

    /// Clear all data
    /// Also called on logout and account deletion, so it must cover every key left on the App Group side
    func clearAll() {
        let keys = [
            AppGroupConstants.Keys.currentQuote,
            AppGroupConstants.Keys.quotePool,
            AppGroupConstants.Keys.quoteUpdatedAt,
            AppGroupConstants.Keys.selectedQuoteId,
            AppGroupConstants.Keys.userDream,
            AppGroupConstants.Keys.currentUserId,
            AppGroupConstants.Keys.blockSession,
            AppGroupConstants.Keys.userSettings,
            AppGroupConstants.Keys.backgroundStyle,
            // Timer
            AppGroupConstants.Keys.timerConfig,
            AppGroupConstants.Keys.timerSelection,
            AppGroupConstants.Keys.timerSession,
            // Schedule
            AppGroupConstants.Keys.scheduleConfig,
            AppGroupConstants.Keys.scheduleConfigs,
            AppGroupConstants.Keys.scheduleSelection,
            AppGroupConstants.Keys.scheduleSession,
            // Location
            AppGroupConstants.Keys.locationSelection,
            AppGroupConstants.Keys.registeredLocations,
            // Purchase (C1)
            AppGroupConstants.Keys.proBlockingEntitled
        ]
        keys.forEach { userDefaults?.removeObject(forKey: $0) }
        userDefaults?.synchronize()
    }

    /// Clear only user-specific data (on sign-out/account deletion, fix for M16 audit 2026-07-20).
    /// clearAll() wipes everything, including the purchase expiry mirror and the queue, which is too
    /// much for sign-out:
    /// - removing proBlockingEntitled falls to the nil = fail-open (allow) side (C1)
    /// - removing pendingBlockSessions loses unsent sessions already stamped with user_id (H3)
    /// Here the scope is limited to preventing "the previous user's location coordinates / schedule
    /// configs / Shield display cache leaking to the next user when a device is shared".
    ///
    /// Intentionally excluded (kept):
    /// - pendingBlockSessions: each row is stamped with user_id and is flushed correctly when that user
    ///   signs in again
    /// - onboardingLanguage (also used as the currentLanguage mirror) / onboardingEstimateMinutes /
    ///   onboardingRevealPhase: device-level settings / onboarding input that does not assume sign-in
    /// - proBlockingEntitled: setting it to nil makes it fail-open, so do not touch it (M17 stops the
    ///   engine itself)
    /// - userDream / currentUserId: their timing is managed separately inside signOut(), so they are
    ///   removed there individually
    func clearUserSpecificData() {
        let keys = [
            // Shield display cache (quote): prevents the accident where the previous user's selection is
            // briefly visible to the next user
            AppGroupConstants.Keys.currentQuote,
            AppGroupConstants.Keys.quotePool,
            AppGroupConstants.Keys.quoteUpdatedAt,
            AppGroupConstants.Keys.selectedQuoteId,
            // Each session mirror, old and current
            AppGroupConstants.Keys.blockSession,
            // Timer (TimerManager.stopTimer() removes timerConfig, but the selection/session are removed too,
            // just in case)
            AppGroupConstants.Keys.timerConfig,
            AppGroupConstants.Keys.timerSelection,
            AppGroupConstants.Keys.timerSession,
            // Schedule (ScheduleManager.stopMonitoring() removes the configs but not the selection, so this is
            // required)
            AppGroupConstants.Keys.scheduleConfig,
            AppGroupConstants.Keys.scheduleConfigs,
            AppGroupConstants.Keys.scheduleSelection,
            AppGroupConstants.Keys.scheduleSession,
            // Location (coordinates/radius): the LocationManager.removeLocation() loop empties
            // registeredLocations, but the app selection (locationSelection) is a separate key, so this is
            // required
            AppGroupConstants.Keys.locationSelection,
            AppGroupConstants.Keys.registeredLocations
        ]
        keys.forEach { userDefaults?.removeObject(forKey: $0) }

        // scheduleActiveStart_<uuid> / locationActiveStart_<uuid> have dynamic key names per schedule/place
        // (prefix + UUID), so they cannot be listed in the array above.
        // The schedule side is flushed beforehand by ScheduleManager.stopMonitoring(), but
        // LocationManager has no equivalent public flush API, and an in-region session at sign-out time
        // can remain unflushed, so all leftovers are swept by prefix match
        // (in that case the session is not queued as completed and is missing from the stats; a known
        // limitation)
        if let defaults = userDefaults {
            let prefixes = [
                AppGroupConstants.Keys.scheduleActiveStartPrefix,
                AppGroupConstants.Keys.locationActiveStartPrefix
            ]
            for key in defaults.dictionaryRepresentation().keys {
                if key == AppGroupConstants.Keys.scheduleActiveStart || prefixes.contains(where: { key.hasPrefix($0) }) {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        userDefaults?.synchronize()
    }
}
