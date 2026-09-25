//
//  TimerManager.swift
//  AppBlocker
//
//  タイマーブロック管理サービス
//  指定時間だけブロックし、時間が来たら自動解除
//

import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity
import UIKit

/// タイマーブロック管理サービス
final class TimerManager: ObservableObject {

    @MainActor static let shared = TimerManager()

    // MARK: - Published Properties

    /// 残り時間（秒）
    @Published private(set) var remainingSeconds: Int = 0

    /// タイマーが動作中か
    @Published private(set) var isRunning: Bool = false

    /// 現在の設定
    @Published private(set) var currentConfig: TimerConfig?

    /// タイマー自然終了時刻 (手動停止 stopTimer() では更新しない)。
    /// 継続ロック中トースト等、「終了イベント」を監視したい View から onChange で購読する。
    @Published private(set) var didCompleteAt: Date?

    /// 直近に自然完了したセッションの実ロック時間 (秒)。didCompleteAt と同時に更新される。
    /// SessionCompleteView がメイン数字の表示に使う。手動停止では更新しない。
    @Published private(set) var lastCompletedDuration: TimeInterval?

    // MARK: - Private Properties

    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.timer))
    private let storage = AppGroupStorage.shared
    private var timer: Timer?
    private var endTime: Date?
    private var sessionStartedAt: Date?

    private let appGroupID = AppGroupConstants.identifier
    private let selectionKey = AppGroupConstants.Keys.timerSelection

    // MARK: - H5: OS バックストップ (プロセス死亡中の期限切れ対策)

    /// タイマー専用の単発 (repeats: false) DeviceActivity 監視。
    /// アプリが起動していない間に期限が来ても、Extension の intervalDidEnd (タイマー named store
    /// クリア分岐) が OS 側で shield を解除できるようにするための保険。
    /// ⚠️ この文字列は DeviceActivityMonitorExtension.swift 側でハードコードして同期させること
    /// (Extension は別ターゲットでこの定数に直接アクセスできない)
    private static let timerActivityName = DeviceActivityName("AppBlocker.Timer")
    private let activityCenter = DeviceActivityCenter()

    /// フォアグラウンド復帰を検知して、次の Timer tick を待たずに即座に endTime と突き合わせる。
    /// バックグラウンドで RunLoop が長時間止まっていた場合でも、復帰直後に期限超過を検出できる (H4)
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Init

    @MainActor
    private init() {
        // 保存されているタイマーを復元
        restoreTimerState()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncRemainingFromEndTime()
        }
    }

    // MARK: - Public Methods

    /// タイマーを開始
    func startTimer(
        durationMinutes: Int,
        apps: FamilyActivitySelection,
        onComplete: (() -> Void)? = nil
    ) {
        // アプリ選択を保存
        saveSelectionToAppGroup(apps)

        // セッション開始時刻を記録 (累計ロック時間集計用)
        sessionStartedAt = Date()

        // 終了時刻を計算 (H4: 残り時間は常にこの endTime から壁時計で導出する。tick 減算はしない)
        let plannedEndTime = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        endTime = plannedEndTime
        remainingSeconds = durationMinutes * 60

        // 設定を保存
        let config = TimerConfig(durationMinutes: durationMinutes)
        currentConfig = config
        saveTimerConfig(config)

        // シールドを適用
        applyShield(apps: apps)

        // H5: プロセス死亡中の期限切れに備え、OS 側にも単発の監視を登録する
        registerOSBackstop(endTime: plannedEndTime)

        // タイマーを開始
        isRunning = true
        startCountdownTimer(onComplete: onComplete)

        print("⏱️ Timer started: \(durationMinutes) minutes")
    }

    /// タイマーを停止（手動停止）
    func stopTimer() {
        timer?.invalidate()
        timer = nil

        // H5: OS バックストップの監視も掃除する (残しても repeats:false で自然失効するが、
        // 早期停止した分だけ無駄に生き続けるのを避ける)
        clearOSBackstop()

        // シールドを解除
        removeShield()

        // セッションを「aborted」として記録
        // plannedSeconds はリセット前 (currentConfig が生きている) の今のうちに取る
        if let startedAt = sessionStartedAt {
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: Date(),
                status: "aborted",
                plannedSeconds: (currentConfig?.durationMinutes).map { $0 * 60 }
            )
            sessionStartedAt = nil
        }

        // 状態をリセット
        isRunning = false
        remainingSeconds = 0
        endTime = nil
        currentConfig = nil

        // 保存データを削除
        clearTimerConfig()

        print("⏱️ Timer stopped manually")
    }

    /// 残り時間をフォーマット（MM:SS）
    func formattedRemainingTime() -> String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 残り時間をフォーマット（HH:MM:SS）
    func formattedRemainingTimeLong() -> String {
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    // MARK: - Private Methods

    /// カウントダウンタイマーを開始
    ///
    /// H4: tick は表示更新のためだけに使い、残り時間の"真実"は endTime (壁時計) から毎回導出する。
    /// 旧実装は tick ごとに remainingSeconds を 1 ずつ減算していたため、バックグラウンドで
    /// RunLoop/Timer が止まっている間は減らず、その分だけ実際の解除時刻が予定より後ろにズレていた。
    private func startCountdownTimer(onComplete: (() -> Void)? = nil) {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncRemainingFromEndTime(onComplete: onComplete)
        }

        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // 開始/復帰直後の表示を即座に endTime 基準へ合わせる (次の 1 秒 tick を待たない)
        syncRemainingFromEndTime(onComplete: onComplete)
    }

    /// H4: 残り時間を endTime からの壁時計計算で同期する。
    /// - 通常 tick からも、フォアグラウンド復帰通知からも呼ばれる共通経路。
    /// - endTime を過ぎていれば (バックグラウンドで tick が止まっていた分も含めて) 即座に完了処理へ進む。
    private func syncRemainingFromEndTime(onComplete: (() -> Void)? = nil) {
        guard isRunning, let endTime = endTime else { return }

        let remaining = endTime.timeIntervalSinceNow
        if remaining > 0 {
            remainingSeconds = Int(remaining.rounded(.up))
        } else {
            remainingSeconds = 0
            timerCompleted(onComplete: onComplete)
        }
    }

    /// タイマー終了時の処理
    private func timerCompleted(onComplete: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil

        // H5: 自然完了なので OS 側の単発監視も明示的に掃除する
        clearOSBackstop()

        // シールドを解除
        removeShield()

        // セッションを「completed」として記録
        // H4: endedAt は検出時刻 (Date()) ではなく確定済みの endTime (予定終了時刻) を使う。
        // バックグラウンドで検出がずれ込んでも、記録される duration がその分だけ水増しされない
        // (restoreTimerState の期限切れ復元分岐と同じ考え方: endedAt: config.endTime)
        if let startedAt = sessionStartedAt {
            let endedAt = endTime ?? Date()
            // SessionCompleteView 用に実ロック時間を確定 (didCompleteAt 発火前にセット)
            lastCompletedDuration = endedAt.timeIntervalSince(startedAt)
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: endedAt,
                status: "completed",
                plannedSeconds: (currentConfig?.durationMinutes).map { $0 * 60 }
            )
            sessionStartedAt = nil
        }

        // 状態をリセット
        isRunning = false
        remainingSeconds = 0
        endTime = nil
        currentConfig = nil

        // 保存データを削除
        clearTimerConfig()

        // BlockingService 側の timerSession キーも消す。
        // ここを残すと、次回起動時に BlockingService.restoreState が
        // 「タイマーは動いていないのにアクティブセッションが存在する」幽霊状態を復元してしまう。
        storage.saveTimerSession(nil)

        // 自然終了イベントを発火 (手動停止とは区別する)
        didCompleteAt = Date()

        onComplete?()

        print("⏱️ Timer completed - Shield removed")
    }

    /// シールドを適用
    private func applyShield(apps: FamilyActivitySelection) {
        // カテゴリと個別アプリは併用可能 (和集合)。旧「カテゴリ優先」分岐は
        // 両方選んだ時に個別アプリが遮断されない穴だった (2026-07-16 Fableレビュー)
        store.shield.applications = apps.applicationTokens.isEmpty ? nil : apps.applicationTokens
        store.shield.applicationCategories = apps.categoryTokens.isEmpty ? nil : .specific(apps.categoryTokens)

        print("✅ Shield applied: \(apps.applicationTokens.count) apps, \(apps.categoryTokens.count) categories")
    }

    /// シールドを解除
    private func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        print("✅ Timer shield removed")
    }

    /// H5: プロセス死亡中の期限切れに備えた OS 側バックストップを登録する。
    /// DeviceActivityCenter に単発 (repeats: false) の監視を登録し、Extension の
    /// intervalDidEnd (タイマー named store をクリアする分岐) がアプリの生死に関わらず
    /// 期限どおりに shield を解除できるようにする。
    /// iOS の DeviceActivity 監視には最短間隔 (15分) の制約があり、それ未満のタイマーでは
    /// 登録が throw しうる。その場合は握りつぶしログのみとし、アプリ内の壁時計処理 (H4) を
    /// 主経路として許容する (現状と同等の保護レベルであり退行ではない)。
    private func registerOSBackstop(endTime: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        let endComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: endTime
        )

        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )

        do {
            try activityCenter.startMonitoring(Self.timerActivityName, during: schedule)
            print("✅ Timer OS backstop registered (ends \(endTime))")
        } catch {
            print("⚠️ Timer OS backstop registration failed (falling back to in-app wall clock only): \(error)")
        }
    }

    /// H5: OS バックストップの監視を掃除する。タイマーの手動停止・自然完了・期限切れ復元のいずれでも呼ぶこと
    private func clearOSBackstop() {
        activityCenter.stopMonitoring([Self.timerActivityName])
    }

    /// タイマー状態を復元（アプリ再起動時）
    private func restoreTimerState() {
        guard let config = loadTimerConfig() else {
            clearTimerConfig()
            return
        }

        // アプリがキル/サスペンド中にタイマーが終了したケース:
        // shield は OS 設定として残り続けるため、ここで解除しないと永久ブロックになる
        if config.isExpired {
            removeShield()
            // H5: 期限切れ復元パス (= H4 の壁時計 or OS バックストップのどちらかが既に処理済み得るケース) でも、
            // OS 側の単発監視が残っていれば掃除する (二重登録を防ぐ)
            clearOSBackstop()
            let startedAt = config.endTime.addingTimeInterval(-TimeInterval(config.durationMinutes * 60))
            BlockSessionTracker.enqueueSession(
                mode: "timer",
                startedAt: startedAt,
                endedAt: config.endTime,
                status: "completed",
                plannedSeconds: config.durationMinutes * 60
            )
            clearTimerConfig()
            // timerCompleted() と同様、BlockingService 側の timerSession キーも消す。
            // 期限切れ復元パスでこれを怠ると、BlockingService.restoreState が
            // 「実際には動いていないタイマー」のセッションを幽霊復元してしまう。
            storage.saveTimerSession(nil)
            return
        }

        // タイマーを再開
        currentConfig = config
        endTime = config.endTime
        remainingSeconds = config.remainingSeconds
        // 累計記録用 startedAt を復元 (endTime から duration を引く)
        sessionStartedAt = config.endTime.addingTimeInterval(-TimeInterval(config.durationMinutes * 60))

        if remainingSeconds > 0 {
            // 保存されたアプリ選択でシールドを再適用
            if let apps = loadSelectionFromAppGroup() {
                applyShield(apps: apps)
            }

            isRunning = true
            startCountdownTimer()

            print("⏱️ Timer restored: \(remainingSeconds) seconds remaining")
        }
    }

    // MARK: - App Group Storage

    private func saveSelectionToAppGroup(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: selectionKey)
            defaults.synchronize()
        } catch {
            print("❌ Failed to save timer selection: \(error)")
        }
    }

    private func loadSelectionFromAppGroup() -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else {
            return nil
        }

        do {
            return try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("❌ Failed to load timer selection: \(error)")
            return nil
        }
    }

    private func saveTimerConfig(_ config: TimerConfig) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: AppGroupConstants.Keys.timerConfig)
        defaults.synchronize()
    }

    private func loadTimerConfig() -> TimerConfig? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: AppGroupConstants.Keys.timerConfig),
              let config = try? JSONDecoder().decode(TimerConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func clearTimerConfig() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.removeObject(forKey: AppGroupConstants.Keys.timerConfig)
        defaults.removeObject(forKey: selectionKey)
        defaults.synchronize()
    }
}
