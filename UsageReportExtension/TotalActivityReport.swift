//
//  TotalActivityReport.swift
//  UsageReportExtension
//
//  2 DeviceActivityReport scenes for the onboarding diagnosis.
//  - onboardingComparison: comparison chart of estimate (self-reported) vs measured
//  - onboardingTopApps:    top 3 by usage (real app icons + names can be drawn with Label(token)
//                          only inside this extension)
//
//  Data flow:
//  - Measured values (DeviceActivityResults) cannot be taken outside this extension (Apple privacy
//    restriction). So everything down to the headings and charts is drawn by Views inside this extension.
//  - The self-report (estimate) is written to the App Group by the main app and read here
//    (a Report extension cannot write to the App Group but can read it).
//  - The Context rawValue must match exactly on the main app's DeviceActivityReport(...) side (fixed
//    string).
//

import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI

// App Group (must match AppGroupConstants in the main app. Hardcoded because it cannot be imported
// from the extension)
private let appGroupID = "group.com.ryunosuke.appblocker.shared"
private let keyEstimateMinutes = "onboardingEstimateMinutes"
private let keyOnboardingLang = "onboardingLanguage"
private let keyRevealPhase = "onboardingRevealPhase"

extension DeviceActivityReport.Context {
    /// Estimate vs measured comparison (onboarding diagnosis)
    static let onboardingComparison = Self("onboardingComparison")
    /// Top 3 by usage (onboarding diagnosis)
    static let onboardingTopApps = Self("onboardingTopApps")
    // History of real device testing (2026-07-13):
    // - 2 DeviceActivityReport instances in the main app → the 2nd is blank (a known iOS quirk)
    // - Single instance + switching context → ✅ both rendered (confirmed on a real device at 20:24)
    // - Merged into 1 scene + re-query with a small filter change → ❌ every switch has a blank of a few
    //   seconds while re-querying and the placeholder shows through (regression confirmed on a real device
    //   at 20:41)
    // → Conclusion: "2 scenes + the main app has a single instance and only switches context" is correct
}

// MARK: - Shared helpers

/// Read the self-reported daily estimate (minutes) from the App Group. 0 if unset
func loadEstimateMinutes() -> Int {
    UserDefaults(suiteName: appGroupID)?.integer(forKey: keyEstimateMinutes) ?? 0
}

/// Read the language ("japanese"/"english") from the App Group. Treated as Japanese if unset
func loadIsJapanese() -> Bool {
    let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: keyOnboardingLang)
    return raw != "english"
}

// MARK: - Merged scene (comparison + top 3)

struct TopAppEntry: Identifiable {
    let id = UUID()
    let token: ApplicationToken?
    let fallbackName: String
    /// Total for the period (minutes)
    let totalMinutes: Int
}

struct UsageConfiguration {
    /// "comparison" or "topApps" (phase flag the main app writes to the App Group)
    let phase: String
    /// Measured daily average (minutes)
    let actualDailyMinutes: Int
    /// Self-reported daily estimate (minutes). 0 = unset
    let estimateDailyMinutes: Int
    let apps: [TopAppEntry]
    let isJapanese: Bool
}

/// Shared aggregation (both total and per-app in 1 pass)
private func buildUsageConfiguration(_ data: DeviceActivityResults<DeviceActivityData>, phase: String) async -> UsageConfiguration {
    var total: TimeInterval = 0
    var dayCount = 0
    var seconds: [ApplicationToken?: TimeInterval] = [:]
    var names: [ApplicationToken?: String] = [:]

    for await d in data {
        for await segment in d.activitySegments {
            total += segment.totalActivityDuration
            dayCount += 1
            for await category in segment.categories {
                for await app in category.applications {
                    let key = app.application.token
                    seconds[key, default: 0] += app.totalActivityDuration
                    if names[key] == nil {
                        names[key] = app.application.localizedDisplayName ?? "App"
                    }
                }
            }
        }
    }

    let days = Double(max(dayCount, 1))
    let dailyAvgMinutes = Int((total / days) / 60)
    // Per-app values are also daily averages (a weekly total gives numbers like 58 hours
    // and gets confused with the daily average on the comparison screen. 2026-07-13 real device feedback)
    let top = seconds
        .sorted { $0.value > $1.value }
        .prefix(3)
        .map { TopAppEntry(token: $0.key, fallbackName: names[$0.key] ?? "App", totalMinutes: Int(($0.value / days) / 60)) }

    return UsageConfiguration(
        phase: phase,
        actualDailyMinutes: dailyAvgMinutes,
        estimateDailyMinutes: loadEstimateMinutes(),
        apps: Array(top),
        isJapanese: loadIsJapanese()
    )
}

struct OnboardingComparisonReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .onboardingComparison
    let content: (UsageConfiguration) -> ComparisonReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageConfiguration {
        await buildUsageConfiguration(data, phase: "comparison")
    }
}

struct OnboardingTopAppsReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .onboardingTopApps
    let content: (UsageConfiguration) -> TopAppsReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageConfiguration {
        await buildUsageConfiguration(data, phase: "topApps")
    }
}
