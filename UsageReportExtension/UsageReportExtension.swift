//
//  UsageReportExtension.swift
//  UsageReportExtension
//
//  Report extension entry point for the onboarding diagnosis.
//  Only scenes whose Context rawValue matches the DeviceActivityReport(...) in the main app
//  are drawn by the system.
//

import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct UsageReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        // There are 2 scenes, but the main app's DeviceActivityReport is always a single instance that
        // switches context (the only setup confirmed to work in real-device testing. For details see the
        // comments in TotalActivityReport.swift)
        OnboardingComparisonReport { config in
            ComparisonReportView(config: config)
        }
        OnboardingTopAppsReport { config in
            TopAppsReportView(config: config)
        }
    }
}
