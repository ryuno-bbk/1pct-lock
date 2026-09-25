//
//  PurchaseService.swift
//  AppBlocker
//
//  RevenueCat SDK のラッパー。entitlement "pro" はUI即時反映用のクライアント側シグナルで、
//  is_pro のサーバー真実は Supabase users.is_pro (RevenueCat webhook → Edge Function 経由で更新)。
//  ProAccess が両者を OR で合成して最終的な Pro 判定にする (このファイルは単体では判定を確定しない)。
//

import Foundation
import Combine
import RevenueCat

@MainActor
final class PurchaseService: NSObject, ObservableObject {
    static let shared = PurchaseService()

    @Published private(set) var entitlementIsPro = false      // RC entitlement "pro" の即時状態
    @Published private(set) var packages: [Package] = []       // current offering の availablePackages
    @Published private(set) var isLoadingOfferings = false
    @Published private(set) var offeringsLoadFailed = false
    @Published private(set) var yearlyTrialEligible = false    // yearly のイントロ資格 (.eligible のときのみ true)
    @Published private(set) var isPurchasing = false

    private override init() {
        super.init()
    }

    // MARK: - Configure

    /// アプリ起動時に一度だけ呼ぶ。Purchases.shared に触れるのはここが最初。
    /// (ProAccess の init はここより前に走ることがあるが、ProAccess は
    /// PurchaseService.shared.$entitlementIsPro を購読するだけで Purchases.shared には触れないので安全)
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

    /// RevenueCat の appUserID を Supabase users.id (小文字UUID文字列) に揃える。
    /// webhook が users.id と突き合わせるため小文字統一が必須。
    func logIn(userId: UUID) async {
        guard Purchases.isConfigured else { return }
        let targetAppUserID = userId.uuidString.lowercased()
        guard Purchases.shared.appUserID != targetAppUserID else {
            // 既に同一ユーザーで紐付け済み。delegate の発火タイミングに頼らず、
            // キャッシュ済み CustomerInfo を明示的に反映しておく (2回目以降の起動経路)
            if let info = try? await Purchases.shared.customerInfo() {
                apply(info)
            }
            return
        }

        do {
            let (customerInfo, _) = try await Purchases.shared.logIn(targetAppUserID)
            apply(customerInfo)
        } catch {
            // 起動をブロックしない。次回 apply() のタイミング (delegate 経由等) で再同期される
            print("⚠️ PurchaseService.logIn failed: \(error)")
        }
    }

    /// サインアウト時に RevenueCat の紐付けも解除。既に匿名なら何もしない。
    func logOut() async {
        guard Purchases.isConfigured else { return }
        if !Purchases.shared.isAnonymous {
            _ = try? await Purchases.shared.logOut()
        }
        entitlementIsPro = false
    }

    // MARK: - Offerings

    /// current offering の availablePackages をロードし、yearly のトライアル資格を確認する。
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
                // .unknown は false のまま (誇張より控えめに倒す方針): トライアル資格が確証できないときは表示しない
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

            // webhook が Supabase users.is_pro を更新するのを取り込むための突き合わせ (fire-and-forget)
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

    /// C1: キャッシュを使わず RevenueCat サーバーから CustomerInfo を取得して entitlement を確定する。
    /// 成功時は apply() で entitlementIsPro にも反映して値を返し、
    /// 失敗 (オフライン等) は nil を返して「未確定」を呼び出し側に伝える
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

        // サーバー真実 (users.is_pro) との突き合わせログ。動作は ProAccess 側の OR に任せる
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
        // CustomerInfo は Sendable なのでそのまま MainActor へ受け渡せる
        Task { @MainActor in
            self.apply(customerInfo)
        }
    }
}
