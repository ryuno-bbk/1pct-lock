//
//  RevenueCatConfig.swift
//  AppBlocker
//
//  RevenueCat constants (values the user set in the dashboard on 2026-07-18).
//  The Public SDK Key is a public key meant to be embedded in the app (not a secret).
//  Never put the Secret Key (sk_) or the In-App Purchase Key (.p8) in the repository.
//

import Foundation
// Also serves as a check that the SPM RevenueCat package is linked to the target correctly
// (check right after adding the package on 2026-07-18. Real use goes through PurchaseService)
import RevenueCat

enum RevenueCatConfig {
    /// Public SDK Key (Apple). RevenueCat → API keys → appl_...
    static let apiKey = "appl_RCPtBnrpBaYNDrRBskkzwqlXwgj"

    /// The single entitlement ID that represents the purchase state (monthly / yearly / lifetime all grant it).
    /// Note: the identifier actually created in the RevenueCat dashboard is "1% Pro" (with a space).
    /// Identifiers cannot be changed after creation, so the code matches it (found in the sandbox on
    /// 2026-07-19).
    /// Always keep it identical to PRO_ENTITLEMENT in Supabase/functions/revenuecat-webhook/index.ts.
    static let proEntitlementID = "1% Pro"

    /// App Store Connect product IDs (normally not referenced directly because they come through Offerings.
    /// Reference values for debugging and logs)
    enum ProductID {
        static let monthly  = "onepercent.pro.monthly"
        static let yearly   = "onepercent.pro.yearly"
        static let lifetime = "onepercent.pro.lifetime"
    }

    enum Legal {
        /// Our own Terms of Use (published 2026-07-30. The minimum EULA terms required by Apple are included in
        /// Article 13 of the terms, so it replaces Apple's standard EULA)
        static let termsOfUse = LegalLinks.termsURL
        /// Privacy Policy (published 2026-07-30. This enables the paywall display that App Review requires)
        static let privacyPolicy: URL? = LegalLinks.privacyURL
    }
}
