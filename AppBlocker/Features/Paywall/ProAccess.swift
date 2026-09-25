//
//  ProAccess.swift
//  AppBlocker
//
//  Pro 機能アクセスの判定。
//  isPro はサーバー真実 (UserAuthService.isPro ← Supabase users.is_pro ← RevenueCat webhook) と
//  RevenueCat entitlement のクライアント即時反映 (PurchaseService.entitlementIsPro) の OR。
//  購入直後は webhook 到達前でも entitlement 側が先に true になるため即座に解放され、
//  サーバー側の失効は次回 UserAuthService.refreshProfile() で反映される。
//

import Foundation
import SwiftUI
import Combine

/// Pro 機能アクセスの状態管理。
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

    /// C1: 直近の「新鮮な確定」時刻。scenePhase .active は頻発するため 1 時間スロットル
    private var lastFreshReconcileAt: Date?
    /// C1: リコンサイルの多重実行防止 (.task と scenePhase .active がほぼ同時に走るため)
    private var isReconciling = false

    static let shared = ProAccess()

    private init() {
        // オフライン起動用: 前回確定した merged (server || entitlement) 値をキャッシュから初期化
        self.isPro = UserDefaults.standard.bool(forKey: Self.storageKey)
        #if DEBUG
        self.debugOverride = UserDefaults.standard.bool(forKey: Self.debugOverrideKey)
        #endif

        // 注意: PurchaseService.shared の init は Purchases.shared (RevenueCat SDK) に触れない設計。
        // そのため PurchaseService.configure() (アプリ起動時の SDK 初期化) より前にこの購読が
        // 走っても安全 — Combine は現在値を即座に emit するので起動直後の状態も正しく反映される。
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
        // 永続化には DEBUG override を含めない (デバッグ抜けで本番同然になる事故を防ぐ)
        UserDefaults.standard.set(merged, forKey: Self.storageKey)
        // C1: 正方向 (Pro 確定) だけは即ミラー反映 — 購入直後に entitlement が true になった瞬間、
        // スケジュール/位置遮断の実行ゲートが待ちなしで開く。
        // ⚠️ 負方向 (false) はここでは絶対に書かない: 起動直後の sink は必ず false/false で一度走るため、
        // ここで false を書くとオフライン起動の Pro ユーザーの遮断が誤解除される。
        // 失効の確定は reconcileEntitlementMirror の新鮮なフェッチのみが行う
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
    /// DEBUG ビルド専用: ペイウォールの「Pro として進む」ボタンから呼ばれる一時オーバーライド。
    func setDebugOverride(_ on: Bool) {
        debugOverride = on
        UserDefaults.standard.set(on, forKey: Self.debugOverrideKey)
        recompute()
    }
    #endif

    /// C1: 課金失効リコンサイル。起動時 (.task) とフォアグラウンド復帰時に呼ぶ。
    /// 「server is_pro と RevenueCat entitlement の両方が新鮮なフェッチで false と確定した」
    /// ときだけ App Group ミラーを false にし、Pro 遮断 (スケジュール/位置) の実行を止める。
    /// - オフライン / 一時的な通信失敗では何も書かない (キャッシュのみでの強制 OFF 禁止)
    /// - スケジュールの isEnabled / 場所の設定には一切触れない
    ///   (設定は残り、再課金でミラーが true に戻れば自動復活する = サンクコスト型ペイウォール設計)
    func reconcileEntitlementMirror() async {
        #if DEBUG
        if debugOverride {
            // デバッグ Pro 中に実フェッチの false で遮断が止まると検証にならないため許可で固定
            AppGroupStorage.shared.saveProBlockingEntitled(true)
            return
        }
        #endif

        // サインイン確定前は判定しない (H6: オフライン起動では userId が nil になり得る)
        guard UserAuthService.shared.userId != nil else { return }

        guard !isReconciling else { return }
        if let last = lastFreshReconcileAt, Date().timeIntervalSince(last) < 3600 { return }
        isReconciling = true
        defer { isReconciling = false }

        // 新鮮なフェッチ (それぞれ nil = 取得失敗 = 未確定)
        let freshServer = await UserAuthService.shared.fetchIsProFresh()
        let freshEntitlement = await PurchaseService.shared.fetchEntitlementIsProFresh()

        if freshServer == true || freshEntitlement == true {
            // どちらかが新鮮に Pro と確定 → 許可 + 残存 ON の遮断を即時再適用 (再課金の自動復活)
            lastFreshReconcileAt = Date()
            AppGroupStorage.shared.saveProBlockingEntitled(true)
            ScheduleManager.shared.checkScheduleState()
            LocationManager.shared.checkCurrentLocationAgainstAllGeofences()
        } else if freshServer == false && freshEntitlement == false {
            // 両方が新鮮に非 Pro と確定 → 失効。shield だけ即時解除 (設定と isEnabled は残す)
            lastFreshReconcileAt = Date()
            AppGroupStorage.shared.saveProBlockingEntitled(false)
            ScheduleManager.shared.checkScheduleState()   // reconcileShieldNow がゲートを見て解除方向に働く
            LocationManager.shared.removeShield()
            // エリート限定アイコンもプライマリへ巻き戻す (2026-07-29 実機バグFB:
            // 失効後もホーム画面が有料アイコンのままだった)
            AppIconCatalog.revertPaidIconIfLapsed()
            print("🔒 Pro entitlement lapsed (fresh) — schedule/location blocking disabled")
        }
        // それ以外 (片方でも未確定で true が無い) → 何も書かない = 前回の確定を維持
    }

    /// 指定された BlockMode が Pro 限定機能か
    static func requiresPro(_ mode: BlockMode) -> Bool {
        switch mode {
        case .timer: return false
        case .schedule, .location: return true
        }
    }

    /// 指定された BlockMode が現状アクセス可能か
    func canAccess(_ mode: BlockMode) -> Bool {
        !Self.requiresPro(mode) || isPro
    }
}
