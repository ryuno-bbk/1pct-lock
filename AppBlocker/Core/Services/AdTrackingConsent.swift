//
//  AdTrackingConsent.swift
//  AppBlocker
//
//  Decide whether personalized ads are allowed with ATT (App Tracking Transparency) (2026-08-04).
//
//  Background: since ads were introduced on 2026-07-31, they have been fixed to "do not show ATT =
//  everyone gets non-personalized (NPA)". Personalized ads have a higher eCPM (NPA is 30-50% lower
//  than personalized [inferred]), so only the implementation was prepared ahead of time so that ATT
//  can be added by the user's decision.
//
//  🔴 The only shipping switch is `isEnabled`. While it is false, behavior is exactly the same as
//  before (no dialog / stays fixed to NPA / never calls ATTrackingManager).
//

import Foundation
import AppTrackingTransparency

@MainActor
final class AdTrackingConsent {

    static let shared = AdTrackingConsent()

    /// 🔴 The only switch for whether ATT ships.
    ///
    /// **Before setting this to true, always finish all 4 items below. Code alone is not enough.**
    /// Submitting while the declarations and the implementation disagree is a reason for rejection.
    ///
    /// 1. Add `NSUserTrackingUsageDescription` to `AppBlocker/Info.plist`
    ///    (both Japanese/English. Write concretely "why permission is needed". Boilerplate text can be
    ///    rejected)
    /// 2. Change `NSPrivacyTracking` in `AppBlocker/PrivacyInfo.xcprivacy` to **true**
    ///    ⚠️ `NSPrivacyTrackingDomains` is currently not provided by Google
    ///       (measuring PrivacyInfo.xcprivacy in GoogleMobileAds.framework showed that
    ///        the `NSPrivacyTracking` / `NSPrivacyTrackingDomains` keys themselves do not exist, and
    ///        every data type was `Tracking = false`. 2026-08-04, SDK v12.14.0).
    ///       Apple's rule is "if `NSPrivacyTrackingDomains` is not empty, `NSPrivacyTracking` is true",
    ///       and the reverse is not required, so **setting only true without listing domains is valid**.
    ///       However, what iOS blocks when ATT is not allowed is "domains listed in some manifest",
    ///       so not listing = not blocked either. Re-check this before submitting
    /// 3. In App Store Connect "App Privacy", change to **Tracking = Yes** and
    ///    declare the data types used for tracking (identifiers/usage data etc.)
    /// 4. Revise the privacy policy → `cd LegalSite && vercel deploy --prod`
    ///
    /// ⚠️ The reasons against it from 2026-07-30, when "do not add ATT" was decided, still hold:
    ///   ① Brand contradiction: "an app that breaks phone addiction" asking for tracking permission
    ///   ② One more dialog increases drop-off in onboarding/the first experience
    /// Also check the revenue premise: ad revenue is eCPM × impressions, so
    /// **right after launch when DAU is thin, a higher unit price makes almost no difference in amount**.
    static let isEnabled = false

    /// Guard against requesting the dialog multiple times (the feed can be shown again any number of times)
    private var hasRequested = false

    private init() {}

    /// Whether personalized ads may be shown.
    /// - While `isEnabled == false`, always false = fixed to NPA (same behavior as before)
    /// - Also false if ATT is not allowed/not determined/restricted
    var allowsPersonalizedAds: Bool {
        guard Self.isEnabled else { return false }
        return ATTrackingManager.trackingAuthorizationStatus == .authorized
    }

    /// Show the ATT dialog. **await this before requesting the first ad**
    /// (if an ad is requested first, the first one is fixed as non-personalized).
    ///
    /// Called when the feed is first shown. ⚠️ Do not show it during onboarding: inserting a
    /// system dialog into the carefully built onboarding lowers the completion rate (conclusion from the
    /// 2026-07-31 review).
    /// From the 2nd time on, the OS just returns the current state immediately, so there are no side
    /// effects, but guard just in case.
    func requestIfNeeded() async {
        guard Self.isEnabled, !hasRequested else { return }
        hasRequested = true
        // For anything other than .notDetermined (already allowed/denied), the OS does not show the dialog.
        // Reject explicitly to avoid useless calls
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
