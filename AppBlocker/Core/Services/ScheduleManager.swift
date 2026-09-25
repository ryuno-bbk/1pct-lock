//
//  ScheduleManager.swift
//  AppBlocker
//
//  DeviceActivitySchedule を使用したスケジュール管理 (複数スケジュール対応 2026-07-15)
//

import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import Combine

enum ScheduleError: LocalizedError {
    case limitReached
    /// L14: 開始=終了などの極端に短い/無効なスケジュール (ScheduleManager.minScheduleDurationMinutes 未満)
    case tooShort

    var errorDescription: String? {
        // サービス層なので @AppStorage は使えず、アプリ内言語設定を UserDefaults から直接読む
        let currentLang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mainLanguage") ?? AppLanguage.deviceDefault.rawValue) ?? .english
        switch self {
        case .limitReached:
            // 文言はユーザー添削待ち
            return currentLang == .japanese
                ? "スケジュールは最大 \(ScheduleManager.maxSchedules) 個までです"
                : "You can have up to \(ScheduleManager.maxSchedules) schedules"
        case .tooShort:
            return L.scheduleTooShort(ScheduleManager.minScheduleDurationMinutes, currentLang)
        }
    }
}

/// スケジュール管理サービス
///
/// 複数スケジュール設計 (上限 maxSchedules、アプリ選択は全スケジュール共通):
/// - スケジュールごとに DeviceActivityName("AppBlocker.Schedule.<uuid>") を発行して OS に登録する
/// - shield は従来どおり named store "schedule" 1 つ。いずれかのスケジュールが時間帯内なら適用、
///   全て時間帯外なら解除 (= 和集合)。解除判定は「他に稼働中のスケジュールが無いか」を必ず確認する
/// - iOS の DeviceActivity は 1 アプリ約 20 activity が上限。maxSchedules = 5 はその余裕内
final class ScheduleManager: ObservableObject {

    @MainActor static let shared = ScheduleManager()

    private let center = DeviceActivityCenter()
    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.schedule))
    private let storage = AppGroupStorage.shared

    /// 定期チェック用タイマー
    private var scheduleCheckTimer: Timer?

    /// スケジュール数の上限。DeviceActivity の約 20 activity 制限に余裕を持たせつつ
    /// 一覧 UI が破綻しない数 (2026-07-15 ユーザー確定)
    static let maxSchedules = 5

    /// L14: スケジュールとして許容する最小長 (分)。開始=終了などの実質ゼロ/極端に短い設定を弾く
    static let minScheduleDurationMinutes = 15

    /// 旧・単一スケジュール時代の監視識別子。移行後は reconcileMonitoring が停止する
    static let legacyActivityName = DeviceActivityName("AppBlocker.Schedule")

    /// スケジュール別の監視識別子。この prefix 判定は DeviceActivityMonitorExtension と同期させること
    static func activityName(for id: UUID) -> DeviceActivityName {
        DeviceActivityName("AppBlocker.Schedule.\(id.uuidString)")
    }

    /// 現在のスケジュール設定一覧（Published）
    @Published private(set) var configs: [ScheduleConfig] = []

    /// 1 つでもスケジュールが登録されているか
    @Published private(set) var isMonitoring: Bool = false

    /// 現在シールドが適用されているか
    @Published private(set) var isShieldActive: Bool = false

    @MainActor
    private init() {
        // 保存されている設定を読み込み (旧単一形式はここで配列形式へ移行される)
        configs = storage.getScheduleConfigs()

        // 保存されたスケジュールがある場合、状態を復元
        restoreScheduleState()
    }

    /// アプリ起動時にスケジュール状態を復元
    private func restoreScheduleState() {
        restoreSkippedOccurrences()
        guard !configs.isEmpty else { return }

        isMonitoring = true

        // OS 側の監視登録を望ましい状態へ突き合わせる
        // (旧 "AppBlocker.Schedule" の停止・BG 再起動等での登録漏れの自己修復を兼ねる)
        reconcileMonitoring()

        // 現在の時間がいずれかのスケジュール内かチェックしてシールドを適用/解除
        // A-4/A-5: applyShield の戻り値で isShieldActive を決める（bail しても true を主張しない）
        reconcileShieldNow()
        print("🔄 Schedule restored - \(configs.count) config(s), shield active: \(isShieldActive)")

        // タイマーを開始
        startScheduleCheckTimer()
    }

    // MARK: - Monitoring Reconcile

    /// OS の DeviceActivity 登録を configs (有効なもの) と突き合わせる冪等処理。
    /// - 余分 (削除済み/無効化済み/旧単一形式の legacy 名) を停止
    /// - 不足 (登録が消えている有効スケジュール) を再登録
    /// prefix "AppBlocker.Schedule" のものだけ触り、他モードの activity には手を出さない
    private func reconcileMonitoring() {
        let desiredByName = Dictionary(
            uniqueKeysWithValues: configs.filter(\.isEnabled)
                .map { (Self.activityName(for: $0.id).rawValue, $0) }
        )

        let currentScheduleActivities = center.activities
            .filter { $0.rawValue.hasPrefix("AppBlocker.Schedule") }

        // 余分を停止 (legacy 名もここで落ちる)
        let extras = currentScheduleActivities.filter { desiredByName[$0.rawValue] == nil }
        if !extras.isEmpty {
            center.stopMonitoring(extras)
            print("🧹 Stopped stale schedule activities: \(extras.map(\.rawValue))")
        }

        // 不足を登録
        let currentNames = Set(currentScheduleActivities.map(\.rawValue))
        for (name, config) in desiredByName where !currentNames.contains(name) {
            do {
                try center.startMonitoring(DeviceActivityName(name), during: deviceActivitySchedule(for: config))
                print("✅ (Re)registered schedule activity: \(name)")
            } catch {
                print("❌ Failed to register schedule activity \(name): \(error)")
            }
        }
    }

    /// L14: スケジュールの実際の長さ (分)。深夜跨ぎ (32e04ef で対応済みの isWithinSchedule と同じ考え方) を考慮する。
    /// start == end は「24時間」ではなく実質ゼロ長 (無効な設定) として扱う。
    /// UI 側 (ScheduleBlockView) からも参照するため internal 公開。
    static func durationMinutes(for config: ScheduleConfig) -> Int {
        let start = config.startHour * 60 + config.startMinute
        let end = config.endHour * 60 + config.endMinute
        if start == end { return 0 }
        if start < end { return end - start }
        return (24 * 60 - start) + end
    }

    private func deviceActivitySchedule(for config: ScheduleConfig) -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(
                hour: config.startHour,
                minute: config.startMinute
            ),
            intervalEnd: DateComponents(
                hour: config.endHour,
                minute: config.endMinute
            ),
            repeats: true,
            warningTime: nil
        )
    }

    // MARK: - Public Methods (追加/更新/削除/有効切替)

    /// スケジュールを追加して監視を開始
    func addSchedule(
        config: ScheduleConfig,
        apps: FamilyActivitySelection
    ) throws {
        guard configs.count < Self.maxSchedules else {
            throw ScheduleError.limitReached
        }

        // L14: 開始=終了などの極端に短い/無効なスケジュールは保存させない
        guard Self.durationMinutes(for: config) >= Self.minScheduleDurationMinutes else {
            throw ScheduleError.tooShort
        }

        // 選択したアプリを保存（全スケジュール共通、DeviceActivityMonitorExtension で使用）
        saveSelectionToAppGroup(apps)

        // L10: isEnabled=false の設定は OS 監視を登録しない。
        // 登録してしまうと実行封じが Extension 側のミラーデコード頼みになり
        // (デコード不能時はフェイルオープン)、無効設定でも遮断が走りうる。
        // OS 登録に成功してから配列へ反映する (失敗時に幽霊 config を残さない)
        if config.isEnabled {
            try center.startMonitoring(
                Self.activityName(for: config.id),
                during: deviceActivitySchedule(for: config)
            )
        }

        configs.append(config)
        storage.saveScheduleConfigs(configs)
        isMonitoring = true

        // 🔥 重要: 現在時刻がスケジュール時間内なら即座にシールドを適用
        reconcileShieldNow()

        // 定期チェックタイマーを開始（15秒ごとにスケジュール状態を確認）
        startScheduleCheckTimer()

        print("✅ Schedule added (\(configs.count)/\(Self.maxSchedules)): \(config.startHour):\(config.startMinute) - \(config.endHour):\(config.endMinute)")
    }

    /// スケジュールを更新（リアルタイム編集）。id で対象を特定し、その activity だけ再登録する
    func updateSchedule(
        config: ScheduleConfig,
        apps: FamilyActivitySelection
    ) throws {
        // L14: 開始=終了などの極端に短い/無効なスケジュールは保存させない。
        // 既存の監視を触る前に検証し、無効な内容で既存状態を壊さないようにする
        guard Self.durationMinutes(for: config) >= Self.minScheduleDurationMinutes else {
            throw ScheduleError.tooShort
        }

        // L14b: 失敗時に「元の設定+元の監視状態」へロールバックできるよう変更前の値を保持しておく
        let previousConfig = configs.first(where: { $0.id == config.id })

        // A-6: 編集で監視を切る前に、進行中のセッションがあれば確定させてキューに積む
        // (取りこぼすと累計ロック時間の集計から消える)
        flushActiveScheduleSession(id: config.id)

        // 対象スケジュールの監視だけ一度停止（シールドは解除しない）
        center.stopMonitoring([Self.activityName(for: config.id)])

        // 選択したアプリを更新（全スケジュール共通）
        saveSelectionToAppGroup(apps)

        if config.isEnabled {
            do {
                try center.startMonitoring(
                    Self.activityName(for: config.id),
                    during: deviceActivitySchedule(for: config)
                )
            } catch {
                // L14b: 新しい設定の監視登録に失敗。configs 配列はまだ書き換えていないので、
                // 元の設定の監視を復元してから rethrow すれば「設定は元のまま・監視も元のまま」に揃う
                // (直前で監視を止めているため、ここで復元しないと「設定は残るが監視は止まったまま」になる)
                if let previousConfig, previousConfig.isEnabled {
                    try? center.startMonitoring(
                        Self.activityName(for: previousConfig.id),
                        during: deviceActivitySchedule(for: previousConfig)
                    )
                }
                print("❌ Failed to register updated schedule activity, restored previous state: \(error)")
                throw error
            }
        }

        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        storage.saveScheduleConfigs(configs)
        isMonitoring = true

        // 🔥 重要: 現在時刻の状態に合わせてシールドを適用/解除
        reconcileShieldNow()

        // タイマーが停止していたら再開
        if scheduleCheckTimer == nil {
            startScheduleCheckTimer()
        }

        print("✅ Schedule updated: \(config.startHour):\(config.startMinute) - \(config.endHour):\(config.endMinute)")
    }

    /// スケジュールを 1 件削除
    func removeSchedule(id: UUID) {
        // A-6: 監視を止める前に、進行中のセッションがあれば確定させてキューに積む
        flushActiveScheduleSession(id: id)

        center.stopMonitoring([Self.activityName(for: id)])

        configs.removeAll { $0.id == id }
        storage.saveScheduleConfigs(configs)

        if configs.isEmpty {
            storage.removeScheduleConfigs()
            scheduleCheckTimer?.invalidate()
            scheduleCheckTimer = nil
            isMonitoring = false
        }

        // 残りのスケジュール状況に合わせてシールドを適用/解除
        reconcileShieldNow()

        print("✅ Schedule removed (\(configs.count)/\(Self.maxSchedules) remaining)")
    }

    /// スケジュールの有効/無効を切り替える (設定は残したまま監視だけ止める)
    func setScheduleEnabled(id: UUID, isEnabled: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        guard configs[index].isEnabled != isEnabled else { return }

        configs[index].isEnabled = isEnabled
        storage.saveScheduleConfigs(configs)

        // 🔴 ON に戻した = 「今すぐ遮断したい」意思表示なので、スキップを必ず捨てる。
        //    これが無いと「今日の分を終える」→ トグルON にしても
        //    isWithinAnySchedule が false のままで遮断が始まらない (2026-08-28 実機報告)
        if isEnabled, skippedOccurrences.removeValue(forKey: id) != nil {
            persistSkippedOccurrences()
        }

        if isEnabled {
            do {
                try center.startMonitoring(
                    Self.activityName(for: id),
                    during: deviceActivitySchedule(for: configs[index])
                )
            } catch {
                print("❌ Failed to re-enable schedule: \(error)")
            }
        } else {
            flushActiveScheduleSession(id: id)
            center.stopMonitoring([Self.activityName(for: id)])
        }

        reconcileShieldNow()
        print("✅ Schedule \(id) enabled=\(isEnabled)")
    }

    /// 全スケジュールを削除して監視を停止 (サインアウト等の全消し用)
    func stopMonitoring() {
        // A-6: 監視を止める前に、進行中のセッションがあれば確定させてキューに積む
        for config in configs {
            flushActiveScheduleSession(id: config.id)
        }

        let names = configs.map { Self.activityName(for: $0.id) } + [Self.legacyActivityName]
        center.stopMonitoring(names)

        // タイマーを停止
        scheduleCheckTimer?.invalidate()
        scheduleCheckTimer = nil

        // シールドを解除
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        // 設定を削除
        storage.removeScheduleConfigs()
        configs = []
        isMonitoring = false
        isShieldActive = false

        print("✅ Schedule monitoring stopped (all)")
    }

    // MARK: - Shield Reconcile

    /// 定期チェックタイマーを開始
    private func startScheduleCheckTimer() {
        // 既存のタイマーを停止
        scheduleCheckTimer?.invalidate()

        // 15秒ごとにスケジュール状態をチェック（A-3: リコンサイル方式にしたためフラップの心配がなく、
        // 5秒だと無駄が多いのでバッテリー配慮でこの間隔に緩めた）
        scheduleCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkScheduleState()
            }
        }

        // RunLoopに追加
        if let timer = scheduleCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // 初回チェックを即座に実行
        DispatchQueue.main.async { [weak self] in
            self?.checkScheduleState()
        }
    }

    /// スケジュール状態をチェックし、必要に応じてシールドを適用/解除
    ///
    /// A-3: メモリ上の isShieldActive フラグとの差分ではなく、store の実状態と突き合わせる
    /// 冪等リコンサイル。フラグ差分方式だと、コールドローンチ直後 (isShieldActive=false 初期化)
    /// に store 側だけ前回の shield が残っているケースを検知できず放置してしまう欠陥があった。
    func checkScheduleState() {
        reconcileShieldNow()
    }

    /// store の実状態と「いずれかの有効スケジュールが時間帯内か」を突き合わせる冪等リコンサイル
    private func reconcileShieldNow() {
        pruneSkippedOccurrences()
        // C1: 課金失効が新鮮なフェッチで確定している間はスケジュール遮断を実行しない。
        // isEnabled や OS 監視登録には触れない (ミラーが true に戻れば次のリコンサイルで自動復活)。
        // ミラー未確定 (キー無し) はオフライン起動での誤解除を避けるため「許可」に倒す
        let desired = storage.isProBlockingEntitled() && isWithinAnySchedule()
        // store の実状態（メモリ上のフラグではなく）を正とする
        let actuallyApplied = store.shield.applications != nil || store.shield.applicationCategories != nil

        if desired && !actuallyApplied {
            // スケジュール時間内なのに store に shield がない → 適用
            print("⏰ Entering schedule time - Applying shield...")
            isShieldActive = applyShield()
            // 遮断が始まった瞬間の解除方法を焼き付ける (以降ここが緩まない)
            if isShieldActive { UnlockChallengeService.shared.beginSessionIfNeeded() }
            print("✅ Schedule check: Shield apply attempted (active: \(isShieldActive))")
            return
        }

        if !desired && actuallyApplied {
            // スケジュール時間外なのに store に shield が残っている → 解除
            print("⏰ Leaving schedule time - Removing shield...")
            removeShield()
            isShieldActive = false
            // タイマーが並走している場合はそちらの焼き付けを消してはいけない
            if !TimerManager.shared.isRunning {
                UnlockChallengeService.shared.endSession()
            }
            print("✅ Schedule check: Shield removed")
            return
        }

        // 一致している → 書き込みはせず、フラグだけ実状態に揃える。
        // L3: 15秒ごとに毎回無条件代入すると値が変わっていなくても @Published が発火し、
        // isShieldActive を observe している View を無駄に再評価させてしまうため、
        // 実際に変化する時だけ代入するガードを挟む
        if isShieldActive != actuallyApplied {
            isShieldActive = actuallyApplied
        }
    }

    /// いずれかの有効なスケジュールが現在時間帯内か
    func isWithinAnySchedule() -> Bool {
        // 「今日の分を終える」でスキップ中の予定は遮断対象から外す。
        // 🔴 スキップは isWithinSchedule (時間判定) には混ぜない。
        //    あちらは Extension と同一ロジックを保つ必要があるため、上に重ねる
        configs.contains { $0.isEnabled && isWithinSchedule(config: $0) && !isSkipped(config: $0) }
    }

    // MARK: - 今日の分を終える (スキップ)
    //
    // 予定そのものを消さずに、今走っている回だけを終わらせる。
    // トグルをオフにすると次回以降も止まってしまうため、この2つは別操作にする。
    //
    // 🔴 Extension とは取り合いにならない:
    //   DeviceActivityMonitorExtension が shield に触るのは intervalDidStart /
    //   intervalDidEnd の境界だけ。区間の途中で外すのはアプリ側の 15 秒リコンサイル
    //   だけなので、そこがスキップを見ていれば遮断は復活しない。

    /// スキップ中の予定 (id → スキップした時刻)。アプリ内だけの概念
    private var skippedOccurrences: [UUID: Date] = [:]

    private static let skippedOccurrencesKey = "schedule.skippedOccurrences"

    /// 走っている回だけを終わらせる。予定は有効なまま残り、次回また動く
    func skipCurrentOccurrence(id: UUID) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        guard isWithinSchedule(config: config) else { return }

        // 統計がずれないよう、実行中セッションを先に確定させる
        flushActiveScheduleSession(id: id)

        skippedOccurrences[id] = Date()
        persistSkippedOccurrences()
        reconcileShieldNow()
        print("⏭️ Schedule \(id) skipped for this occurrence")
    }

    /// いずれかの予定が今まさに遮断中か (スキップ済みは除く)
    var hasRunningOccurrence: Bool {
        isShieldActive && isWithinAnySchedule()
    }

    /// この予定が今の回をスキップ済みか。
    /// 区間が終われば自動的に解ける (次回の開始は妨げない)
    func isSkipped(config: ScheduleConfig) -> Bool {
        guard let skippedAt = skippedOccurrences[config.id] else { return false }
        // 区間の外に出たら解除。深夜跨ぎも isWithinSchedule が面倒を見る
        guard isWithinSchedule(config: config) else { return false }
        // 🔴 24時間に近い予定だと上の条件だけでは永久にスキップされ続けるため、
        //    予定の長さでも上限をかける
        let duration = TimeInterval(Self.durationMinutes(for: config) * 60)
        guard duration > 0 else { return false }
        return Date().timeIntervalSince(skippedAt) < duration
    }

    /// 期限切れのスキップを捨てる (辞書が育ち続けないように)
    private func pruneSkippedOccurrences() {
        let before = skippedOccurrences.count
        skippedOccurrences = skippedOccurrences.filter { id, _ in
            guard let config = configs.first(where: { $0.id == id }) else { return false }
            return isSkipped(config: config)
        }
        if skippedOccurrences.count != before { persistSkippedOccurrences() }
    }

    private func persistSkippedOccurrences() {
        let raw = skippedOccurrences.reduce(into: [String: Double]()) { acc, entry in
            acc[entry.key.uuidString] = entry.value.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: Self.skippedOccurrencesKey)
    }

    /// 🔴 復元は必須。アプリを再起動したらスキップが消える作りだと、
    ///    落として開き直すだけで遮断が復活してしまう
    private func restoreSkippedOccurrences() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.skippedOccurrencesKey) as? [String: Double] else { return }
        skippedOccurrences = raw.reduce(into: [UUID: Date]()) { acc, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            acc[id] = Date(timeIntervalSince1970: entry.value)
        }
    }

    /// 現在のスケジュール時間内かどうかを確認
    ///
    /// ⚠️ この判定ロジックは DeviceActivityMonitorExtension の isWithinSchedule /
    /// isIntervalStartWeekdayAllowed (DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.swift)
    /// と同期させること。片方だけ直すと深夜跨ぎスケジュールで main app と extension の判断がずれ、
    /// 「アプリ上は時間内表示なのに OS のシールドは掛かっていない (または逆)」というフラップが再発する。
    func isWithinSchedule(config: ScheduleConfig) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let currentComponents = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let currentHour = currentComponents.hour,
              let currentMinute = currentComponents.minute,
              let weekday = currentComponents.weekday else {
            return false
        }

        let currentTime = currentHour * 60 + currentMinute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute

        if startTime < endTime {
            // 同日内のスケジュール（例: 09:00 - 17:00）→ 今日の曜日で判定
            guard config.weekdays.contains(weekday) else { return false }
            return currentTime >= startTime && currentTime < endTime
        } else {
            // 日をまたぐスケジュール（例: 22:00 - 07:00）
            // currentTime >= startTime: 今日の夜、まだ今日の曜日のインターバル中 → 今日の曜日で判定
            // currentTime < endTime: 日付は変わっているが、インターバルは「昨日」開始 → 昨日の曜日で判定
            if currentTime >= startTime {
                return config.weekdays.contains(weekday)
            } else if currentTime < endTime {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                    return config.weekdays.contains(weekday)
                }
                let yesterdayWeekday = calendar.component(.weekday, from: yesterday)
                return config.weekdays.contains(yesterdayWeekday)
            } else {
                return false
            }
        }
    }

    /// シールドを適用
    /// ManagedSettingsStore を使用して直接シールドを設定
    /// - Returns: 実際に shield を書き込んだら true。権限未承認・選択なしなど bail した場合は false
    ///   （呼び元はこの戻り値で isShieldActive を設定すること。A-4: bail しても true 扱いにするバグの修正）
    @discardableResult
    func applyShield() -> Bool {
        print("🔒 applyShield() called")

        // C1: 失効確定中は書き込まない (reconcileShieldNow 以外の呼び出し経路の取りこぼし対策)
        guard storage.isProBlockingEntitled() else {
            print("⚠️ applyShield: Pro entitlement lapsed - Shield not applied")
            return false
        }

        // Screen Time 権限が失効/未承認の場合、store に書いても enforcement されない。
        // 「見た目だけ active」を防ぐため false で早期return（A-5）
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            print("⚠️ applyShield: Family Controls not approved - Shield not applied")
            return false
        }

        guard let selection = loadSelectionFromAppGroup() else {
            print("⚠️ No saved selection found in App Group (key: \(selectionKey))")
            return false
        }

        let appCount = selection.applicationTokens.count
        let categoryCount = selection.categoryTokens.count

        print("🔍 Applying shield - Apps: \(appCount), Categories: \(categoryCount)")

        if appCount == 0 && categoryCount == 0 {
            print("⚠️ No apps or categories selected - Shield not applied")
            return false
        }

        // カテゴリと個別アプリは併用可能 (和集合)。旧「カテゴリ優先」分岐は
        // 両方選んだ時に個別アプリが遮断されない穴だった (2026-07-16 Fableレビュー)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        print("✅ Shield set for \(categoryCount) categories, \(appCount) applications")

        print("🔒 Shield applied successfully!")
        return true
    }

    /// シールドを解除
    func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        print("✅ Shield removed")
    }

    // MARK: - Session Recording (A-6: 編集/停止でのセッション取りこぼし対策)

    /// App Group の scheduleActiveStart_<uuid> (Extension が intervalDidStart で書く開始時刻) が
    /// 残っていれば、[start, now) を completed セッションとしてキューに積んで取りこぼしを防ぐ。
    /// updateSchedule / removeSchedule / 無効化 の冒頭で呼ぶこと（監視を切る前に必ず確定させる）。
    /// 旧・単一形式時代の "scheduleActiveStart" キーも移行ケアとして一緒に流す
    private func flushActiveScheduleSession(id: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        let keys = [
            AppGroupConstants.Keys.scheduleActiveStartPrefix + id.uuidString,
            AppGroupConstants.Keys.scheduleActiveStart // legacy
        ]

        for key in keys {
            guard let startTs = defaults.object(forKey: key) as? TimeInterval else { continue }
            BlockSessionTracker.enqueueSession(
                mode: "schedule",
                startedAt: Date(timeIntervalSince1970: startTs),
                endedAt: Date(),
                status: "completed"
            )
            defaults.removeObject(forKey: key)
            print("📥 Flushed in-flight schedule session (\(key)) before edit/stop")
        }
    }

    // MARK: - App Group Storage

    private let appGroupID = AppGroupConstants.identifier
    private let selectionKey = AppGroupConstants.Keys.scheduleSelection

    /// アプリ選択の変更を反映する (全スケジュール共通)。
    /// shield 稼働中なら store の中身も新しい選択で書き直す (リコンサイルは on/off しか見ないため、
    /// 選択だけ変わったケースはここで明示的に再適用しないと古いアプリセットのままになる)
    func updateSharedSelection(_ selection: FamilyActivitySelection) {
        saveSelectionToAppGroup(selection)
        if isShieldActive {
            isShieldActive = applyShield()
        }
    }

    /// アプリ選択を保存 (全スケジュール共通)。UI からの選択変更を即反映するために公開している
    func saveSelectionToAppGroup(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: selectionKey)
            defaults.synchronize()
        } catch {
            print("❌ Failed to save selection: \(error)")
        }
    }

    func loadSelectionFromAppGroup() -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else {
            return nil
        }

        do {
            return try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("❌ Failed to load selection: \(error)")
            return nil
        }
    }
}
