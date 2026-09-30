//
//  AppGroupIdentifier.swift
//  AppBlocker
//
//  App Group identifier definitions
//

import Foundation

/// App Group related constants
enum AppGroupConstants {
    /// App Group identifier
    /// ⚠️ Set the same value in Xcode's Signing & Capabilities
    static let identifier = "group.com.ryunosuke.appblocker.shared"

    /// UserDefaults keys
    enum Keys {
        static let currentQuote = "currentQuote"
        /// Quote pool that the Shield draws one random quote from every time it is shown (JSON encoded
        /// [SharedQuote]). With this, the Extension does not need to parse the 175-item bundled JSON
        /// (avoids the main cause of the 11-second cold-start freeze), and quotes can rotate on every display
        static let quotePool = "quotePool"
        /// Timestamp for invalidating the Shield Extension's cache
        /// The main app writes a new value every time it updates quotes, and the Extension reloads based on it
        static let quoteUpdatedAt = "quoteUpdatedAt"
        static let selectedQuoteId = "selectedQuoteId"
        /// Mirror of the user's "dream" (user_dreams.dream), used in the subtitle of Shield plan A
        /// (app-name-led).
        /// Written from 3 places in the main app (onboarding save / profile edit save / load at launch).
        /// When no dream is declared, the key itself is removed (an empty string is not saved)
        static let userDream = "userDream"
        static let blockSession = "blockSession"
        static let userSettings = "userSettings"
        static let backgroundStyle = "backgroundStyle"

        // Timer settings
        static let timerConfig = "timerConfig"
        static let timerSelection = "timerSelection"
        static let timerSession = "timerSession"

        // Schedule settings
        /// Old single-schedule format (JSON encoded ScheduleConfig). After the switch to multiple schedules
        /// (2026-07-15), getScheduleConfigs migrates it to scheduleConfigs on read, and this key is deleted
        static let scheduleConfig = "scheduleConfig"
        /// Multiple-schedule format (JSON encoded [ScheduleConfig], up to ScheduleManager.maxSchedules)
        static let scheduleConfigs = "scheduleConfigs"
        static let scheduleSelection = "scheduleSelection"
        static let scheduleSession = "scheduleSession"

        // Location lock settings
        static let locationSelection = "locationBlockSelection"
        static let registeredLocations = "registeredLocations"

        // Onboarding diagnosis (read by UsageReportExtension. The Report extension cannot write to the App
        // Group, so these are one-way input values from the main app → extension)
        /// Self-reported daily usage time (minutes). The main app writes it before showing usageReveal
        static let onboardingEstimateMinutes = "onboardingEstimateMinutes"
        /// Display language ("japanese"/"english")
        static let onboardingLanguage = "onboardingLanguage"
        /// Phase of usageReveal ("comparison"/"topApps"). The extension is merged into one scene,
        /// so it switches what it shows with this flag
        static let onboardingRevealPhase = "onboardingRevealPhase"

        // Block session records (for total time aggregation)
        /// Queue of completed sessions. Bulk inserted into Supabase at launch
        static let pendingBlockSessions = "pendingBlockSessions"
        /// Mirror of the currently signed-in user's UUID (lowercased): used to stamp user_id at enqueue time
        /// (H3). The main app (UserAuthService) writes it on a successful sign-in / session restore, and
        /// removes it in signOut().
        /// It is not removed on a temporary failure of restoreSession (offline etc.) (same F5 policy as the
        /// dream mirror).
        /// The Extension is a separate target, so it references the key hardcoded
        /// (DeviceActivityMonitorExtension.swift)
        static let currentUserId = "currentUserId"
        /// Start time of schedule mode (TimeInterval), written by the Extension (old single-schedule format)
        static let scheduleActiveStart = "scheduleActiveStart"
        /// Prefix for per-schedule start times after the switch to multiple schedules
        /// (key: "scheduleActiveStart_<uuid>")
        static let scheduleActiveStartPrefix = "scheduleActiveStart_"
        /// Prefix for per-region start times in location mode (key: "locationActiveStart_<uuid>")
        static let locationActiveStartPrefix = "locationActiveStart_"

        // Reconcile on purchase expiry (C1)
        /// Mirror (Bool) of whether Pro blocking (schedule/location) may run.
        /// ProAccess.reconcileEntitlementMirror writes it only when it was "confirmed by a fresh fetch"
        /// (writing false from the cache only would wrongly unlock Pro users who launch offline).
        /// Key not set = unconfirmed falls to "allowed to run" (fail-open).
        /// ⚠️ DeviceActivityMonitorExtension hardcodes the same string, so keep them in sync
        static let proBlockingEntitled = "proBlockingEntitled"
    }

    /// Names of the ManagedSettingsStore
    /// Using an independent store for each mode guarantees that "a mode does not break another mode's
    /// shield while they run at the same time"
    /// Apple spec: when there are multiple named stores, the most restrictive settings are combined
    enum Stores {
        static let timer = "timer"
        static let schedule = "schedule"
        static let location = "location"
    }
}
