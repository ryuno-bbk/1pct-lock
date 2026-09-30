//
//  PurchaseService.swift
//  AppBlocker
//
//  Wrapper for the RevenueCat SDK. The entitlement "pro" is a client-side signal for instant UI
//  updates, and the server truth for is_pro is Supabase users.is_pro (updated via RevenueCat webhook
//  → Edge Function).
//  ProAccess combines both with OR for the final Pro decision (this file alone does not decide it).
//

import Foundation
import Combine
import RevenueCat

@MainActor
final class PurchaseService: NSObject, ObservableObject {
    static let shared = PurchaseService()

    @Published private(set) var entitlementIsPro = false      // Instant state of the RC entitlement "pro"
    @Published private(set) var packages: [Package] = []       // availablePackages of the current offering
    @Published private(set) var isLoadingOfferings = false
    @Published private(set) var offeringsLoadFailed = false
    @Published private(set) var yearlyTrialEligible = false    // Intro offer eligibility for yearly (true only when .eligible)
    @Published private(set) var isPurchasing = false

    private override init() {
        super.init()
    }

    // MARK: - Configure

    /// Call only once at app launch. This is the first place that touches Purchases.shared.
    /// (ProAccess's init may run before this, but ProAccess only subscribes to
    /// PurchaseService.shared.$entitlementIsPro and does not touch Purchases.shared, so it is safe)
    static func configure() {
        guard !Purchases.isConfigured else { return }
        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: RevenueCatConfig.apiKey)
        Purchases.shared.delegate = PurchaseService.shared
    }

    // MARK: - Identity

    /// Align RevenueCat's appUserID with Supabase users.id (lowercase UUID string).
    /// The webhook matches it against users.id, so lowercase is required.
    func logIn(userId: UUID) async {
        guard Purchases.isConfigured else { return }
        let targetAppUserID = userId.uuidString.lowercased()
        guard Purchases.shared.appUserID != targetAppUserID else {
            // Already linked with the same user. Do not rely on when the delegate fires;
            // explicitly apply the cached CustomerInfo (the path for the 2nd launch onward)
            if let info = try? await Purchases.shared.customerInfo() {
                apply(info)
            }
            return
        }

        do {
            let (customerInfo, _) = try await Purchases.shared.logIn(targetAppUserID)
            apply(customerInfo)
        } catch {
            // Do not block launch. It resyncs at the next apply() (via the delegate, etc.)
            print("⚠️ PurchaseService.logIn failed: \(error)")
        }
    }

    /// On sign-out, also unlink RevenueCat. Do nothing if already anonymous.
    func logOut() async {
        guard Purchases.isConfigured else { return }
        if !Purchases.shared.isAnonymous {
            _ = try? await Purchases.shared.logOut()
        }
        entitlementIsPro = false
    }

    // MARK: - Offerings

    /// Load availablePackages of the current offering and check yearly trial eligibility.
    func loadOfferings() async {
        guard Purchases.isConfigured else { return }
        isLoadingOfferings = true
        offeringsLoadFailed = false
        defer { isLoadingOfferings = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            guard let current = offerings.current else {
                offeringsLoadFailed = true
                return
            }
            packages = current.availablePackages

            if let yearly = packageFor(type: .annual, fallbackID: RevenueCatConfig.ProductID.yearly) {
                let productID = yearly.storeProduct.productIdentifier
                let eligibilities = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
                    productIdentifiers: [productID]
                )
                // .unknown stays false (policy: lean conservative rather than overstating): do not show the trial
                // when eligibility cannot be confirmed
                yearlyTrialEligible = eligibilities[productID]?.status == .eligible
            } else {
                yearlyTrialEligible = false
            }
        } catch {
            print("⚠️ PurchaseService.loadOfferings failed: \(error)")
            offeringsLoadFailed = true
        }
    }

    // MARK: - Purchase

    enum PurchaseOutcome {
        case success
        case cancelled
        case failed(String)
    }

    func purchase(_ package: Package) async -> PurchaseOutcome {
        guard Purchases.isConfigured else {
            return .failed("Purchases not configured")
        }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                return .cancelled
            }
            apply(result.customerInfo)

            // Reconciliation to pick up the webhook updating Supabase users.is_pro (fire-and-forget)
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await UserAuthService.shared.refreshProfile()
            }
            return .success
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    enum RestoreOutcome {
        case restored
        case nothingToRestore
        case failed(String)
    }

    func restore() async -> RestoreOutcome {
        guard Purchases.isConfigured else {
            return .failed("Purchases not configured")
        }
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            apply(customerInfo)
            if customerInfo.entitlements[RevenueCatConfig.proEntitlementID]?.isActive == true {
                return .restored
            } else {
                return .nothingToRestore
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Fresh Entitlement Check (C1)

    /// C1: get CustomerInfo from the RevenueCat server without the cache to confirm the entitlement.
    /// On success, also apply it to entitlementIsPro with apply() and return the value;
    /// on failure (offline etc.) return nil to tell the caller it is "undetermined"
    func fetchEntitlementIsProFresh() async -> Bool? {
        guard Purchases.isConfigured else { return nil }
        do {
            let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
            apply(info)
            return info.entitlements[RevenueCatConfig.proEntitlementID]?.isActive == true
        } catch {
            print("⚠️ fetchEntitlementIsProFresh failed: \(error)")
            return nil
        }
    }

    // MARK: - Apply CustomerInfo

    private func apply(_ info: CustomerInfo) {
        entitlementIsPro = info.entitlements[RevenueCatConfig.proEntitlementID]?.isActive == true

        // Log comparing with the server truth (users.is_pro). Behavior is left to the OR on the ProAccess
        // side
        let serverIsPro = UserAuthService.shared.isPro
        if serverIsPro != entitlementIsPro {
            print("⚠️ is_pro mismatch: server=\(serverIsPro) rc=\(entitlementIsPro)")
        }
    }

    // MARK: - Package Accessors

    var monthlyPackage: Package? {
        packageFor(type: .monthly, fallbackID: RevenueCatConfig.ProductID.monthly)
    }

    var yearlyPackage: Package? {
        packageFor(type: .annual, fallbackID: RevenueCatConfig.ProductID.yearly)
    }

    var lifetimePackage: Package? {
        packageFor(type: .lifetime, fallbackID: RevenueCatConfig.ProductID.lifetime)
    }

    private func packageFor(type: PackageType, fallbackID: String) -> Package? {
        packages.first { $0.packageType == type }
            ?? packages.first { $0.storeProduct.productIdentifier == fallbackID }
    }
}

// MARK: - PurchasesDelegate

extension PurchaseService: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        // CustomerInfo is Sendable, so it can be passed to the MainActor as is
        Task { @MainActor in
            self.apply(customerInfo)
        }
    }
}
