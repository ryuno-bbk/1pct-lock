//
//  AppLanguage.swift
//  AppBlocker
//
//  Choices for the app display language. Adding a new language only needs a new case.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    // Future examples: case chinese = "zh", case spanish = "es"

    var id: String { rawValue }

    /// Native language name shown in the Picker on the settings screen
    var displayName: String {
        switch self {
        case .english:  return "English"
        case .japanese: return "日本語"
        }
    }

    /// Default language that follows the device language (2026-07-25 real device feedback: with the
    /// device set to English, the UI stayed in Japanese while only OS-provided screens
    /// (FamilyActivityPicker etc.) were in English, an inconsistent mix. App Review also uses English
    /// devices). The old implementation was "always Japanese" for a Japan-first market, but Japanese
    /// devices still get Japanese, so this does not conflict with the Japan-first strategy. Nothing
    /// writes to mainLanguage, so this value is evaluated on every launch and follows the device language
    static var deviceDefault: AppLanguage {
        // Locale.current can resolve to the app's declared localizations, so
        // read the user's device setting itself (AppleLanguages) directly
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? .japanese : .english
    }
}
