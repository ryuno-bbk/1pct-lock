//
//  ProAccess.swift
//  AppBlocker
//
//  Checks access to Pro features.
//  isPro is the OR of the server truth (UserAuthService.isPro ← Supabase users.is_pro ← RevenueCat
//  webhook) and the immediate client-side RevenueCat entitlement (PurchaseService.entitlementIsPro).
//  Right after a purchase, the entitlement becomes true first, even before the webhook arrives, so
//  access is unlocked immediately,
//  and an expiry on the server side is applied on the next UserAuthService.refreshProfile().
//

import Foundation
import SwiftUI
import Combine

/// State management for Pro feature access.
@MainActor
final class ProAccess: ObservableObject {
    private static let storageKey = "isPro"
    private static let debugOverrideKey = "debugProOverride"

    @Published private(set) var isPro: Bool

    private var serverIsPro = false
    private var entitlementIsPro = false
    #if DEBUG
    private var debugOverride: Bool
    #endif
    private var cancellables = Set<AnyCancellable>()

    /// C1: time of the most recent "fresh confirmation". scenePhase .active fires often, so it is throttled
    /// to 1 hour
    private var lastFreshReconcileAt: Date?
    /// C1: prevents running the reconcile more than once at a time (.task and scenePhase .active run almost
    /// at the same time)
    private var isReconciling = false

    static let shared = ProAccess()

    private init() {
        // For offline launch: initialize from the cache with the last confirmed merged (server || entitlement)
        // value
        self.isPro = UserDefaults.standard.bool(forKey: Self.storageKey)
        #if DEBUG
        self.debugOverride = UserDefaults.standard.bool(forKey: Self.debugOverrideKey)
        #endif

        // Note: the init of PurchaseService.shared is designed not to touch Purchases.shared (RevenueCat SDK).
        // So it is safe even if this subscription runs before PurchaseService.configure() (SDK
        // initialization at app launch). Combine emits the current value immediately, so the state right
        // after launch is also reflected correctly.
        UserAuthService.shared.$isPro
            .sink { [weak self] value in
                self?.serverIsPro = value
                self?.recompute()
            }
            .store(in: &cancellables)

        PurchaseService.shared.$entitlementIsPro
            .sink { [weak self] value in
                self?.entitlementIsPro = value
                self?.recompute()
            }
            .store(in: &cancellables)
    }

    private func recompute() {
        let merged = serverIsPro || entitlementIsPro
        // The DEBUG override is not persisted (prevents an accident where a leftover debug value makes it act
        // like production)
        UserDefaults.standard.set(merged, forKey: Self.storageKey)
        // C1: only the positive direction (Pro confirmed) is mirrored immediately. The moment the entitlement
        // becomes true right after a purchase, the run gate for schedule/location blocking opens with no wait.
        // ⚠️ Never write the negative direction (false) here: the sink right after launch always runs once
        // with false/false, so writing false here would wrongly unlock blocking for Pro users launching offline.
        // Only the fresh fetch in reconcileEntitlementMirror confirms an expiry
        if merged {
            AppGroupStorage.shared.saveProBlockingEntitled(true)
        }
        #if DEBUG
        isPro = merged || debugOverride
        #else
        isPro = merged
        #endif
    }

    #if DEBUG
    /// DEBUG builds only: a temporary override called from the paywall's "Pro として進む" ("Continue as Pro")
    /// button.
    func setDebugOverride(_ on: Bool) {
        debugOverride = on
        UserDefaults.standard.set(on, forKey: Self.debugOverrideKey)
        recompute()
    }
    #endif

    /// C1: purchase expiry reconcile. Called at launch (.task) and when returning to the foreground.
    /// Only when "both server is_pro and the RevenueCat entitlement are confirmed false by fresh fetches"
    /// is the App Group mirror set to false, which stops Pro blocking (schedule/location) from running.
    /// - Nothing is written when offline / on a temporary network failure (no forced OFF based only on the
    ///   cache)
    /// - Never touch the schedule's isEnabled / the place settings
    ///   (the settings remain, and if the mirror goes back to true on a new purchase, it comes back
    ///   automatically = sunk-cost paywall design)
    func reconcileEntitlementMirror() async {
        #if DEBUG
        if debugOverride {
            // While debug Pro is on, blocking stopping because a real fetch returned false would make testing
            // useless, so it is fixed to allowed
            AppGroupStorage.shared.saveProBlockingEntitled(true)
            return
        }
        #endif

        // Do not decide before sign-in is confirmed (H6: on offline launch userId can be nil)
        guard UserAuthService.shared.userId != nil else { return }

        guard !isReconciling else { return }
        if let last = lastFreshReconcileAt, Date().timeIntervalSince(last) < 3600 { return }
        isReconciling = true
        defer { isReconciling = false }

        // Fresh fetches (each nil = fetch failed = not confirmed)
        let freshServer = await UserAuthService.shared.fetchIsProFresh()
        let freshEntitlement = await PurchaseService.shared.fetchEntitlementIsProFresh()

        if freshServer == true || freshEntitlement == true {
            // Either one is freshly confirmed as Pro → allow + immediately reapply blocking that is still ON
            // (automatic return after a new purchase)
            lastFreshReconcileAt = Date()
            AppGroupStorage.shared.saveProBlockingEntitled(true)
            ScheduleManager.shared.checkScheduleState()
            LocationManager.shared.checkCurrentLocationAgainstAllGeofences()
        } else if freshServer == false && freshEntitlement == false {
            // Both are freshly confirmed as not Pro → expired. Only remove the shield immediately (keep the settings
            // and isEnabled)
            lastFreshReconcileAt = Date()
            AppGroupStorage.shared.saveProBlockingEntitled(false)
            ScheduleManager.shared.checkScheduleState()   // reconcileShieldNow checks the gate and works in the unlock direction
            LocationManager.shared.removeShield()
            // Also revert the Elite-only icon to the primary one (2026-07-29 real-device bug feedback:
            // the home screen kept the paid icon after expiry)
            AppIconCatalog.revertPaidIconIfLapsed()
            print("🔒 Pro entitlement lapsed (fresh) — schedule/location blocking disabled")
        }
        // Otherwise (at least one is not confirmed and there is no true) → write nothing = keep the last
        // confirmed value
    }

    /// Whether the given BlockMode is a Pro-only feature
    static func requiresPro(_ mode: BlockMode) -> Bool {
        switch mode {
        case .timer: return false
        case .schedule, .location: return true
        }
    }

    /// Whether the given BlockMode is currently accessible
    func canAccess(_ mode: BlockMode) -> Bool {
        !Self.requiresPro(mode) || isPro
    }
}
