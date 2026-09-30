//
//  LegalLinks.swift
//  AppBlocker
//
//  Constants for the terms of service / privacy policy / support contact (for M6/M15/M26,
//  2026-07-22). Used in: AppleSignInStepView (consent text) / SettingsListView (About section) /
//  RevenueCatConfig.Legal (terms and privacy rows on the paywall).
//
//  Live in production since 2026-07-30 (source in LegalSite/, Vercel project onepercent-legal).
//  To change the text, edit LegalSite/ and run `vercel deploy --prod`. The URLs do not change.
//  English versions are /en/terms and /en/privacy (in-app links are fixed to the Japanese version,
//  EN can be switched at the top of the page).
//  Public repository: replace supportEmail with your own support address.
//

import Foundation

enum LegalLinks {

    /// Public URL of the terms of service
    static let termsURL = URL(string: "https://onepercent-legal.vercel.app/terms")!

    /// Public URL of the privacy policy
    static let privacyURL = URL(string: "https://onepercent-legal.vercel.app/privacy")!

    /// Support email address (mailto: target of "設定 > お問い合わせ" ("Settings > Contact"))
    static let supportEmail = "support@example.com"

    /// mailto: URL opened from the contact row (a plain new mail with no subject)
    static var supportMailURL: URL? {
        URL(string: "mailto:\(supportEmail)")
    }
}
