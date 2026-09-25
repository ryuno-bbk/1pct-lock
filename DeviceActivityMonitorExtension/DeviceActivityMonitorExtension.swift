//
//  DeviceActivityMonitorExtension.swift
//  DeviceActivityMonitorExtension
//
//  スケジュールベースのシールド制御 (複数スケジュール対応 2026-07-15)
//
//  activity 名の形式:
//  - "AppBlocker.Schedule.<uuid>" — 複数化後のスケジュール別監視 (ScheduleManager.activityName(for:))
//  - "AppBlocker.Schedule"        — 旧・単一形式 (移行前に発火し得るため後方互換で残す)
//  shield は named store "schedule" 1 つの和集合。終了時は「他の有効スケジュールが
//  現在時間帯内でないか」を必ず確認してから解除する (先に終わった方が後発の shield を消さない)
//

import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    /// schedule モード専用の named store
    /// ⚠️ 名前は AppGroupConstants.Stores.schedule と完全一致させること
    /// （Extension は別ターゲットで AppGroupConstants にアクセスできない可能性があるためハードコード）
    private let store = ManagedSettingsStore(named: .init("schedule"))

    /// H5: タイマーの OS バックストップ用 named store。
    /// ⚠️ 名前は AppGroupConstants.Stores.timer / TimerManager.store と完全一致させること
    private let timerStore = ManagedSettingsStore(named: .init("timer"))

    /// H5: TimerManager が登録する単発監視の activity 名。
    /// ⚠️ TimerManager.timerActivityName ("AppBlocker.Timer") と完全一致させること
    private let timerActivityRawValue = "AppBlocker.Timer"

    private let appGroupID = "group.com.ryunosuke.appblocker.shared"

    // App Group キーは AppGroupConstants と同期させる (Extension は別ターゲットなのでハードコード)
    private let scheduleActiveStartKey = "scheduleActiveStart"          // 旧・単一形式
    private let scheduleActiveStartPrefix = "scheduleActiveStart_"     // 複数化後: + <uuid>
    private let pendingBlockSessionsKey = "pendingBlockSessions"
    private let currentUserIdKey = "currentUserId"                      // 現サインインユーザー UUID (lowercased) ミラー (H3)
    private let scheduleConfigKey = "scheduleConfig"                    // 旧・単一形式
    private let scheduleConfigsKey = "scheduleConfigs"                  // 複数化後 (JSON 配列)

    /// C1: Pro 遮断の実行可否ミラー。AppGroupConstants.Keys.proBlockingEntitled と同期させること
    private let proBlockingEntitledKey = "proBlockingEntitled"

    private let legacyActivityRawValue = "AppBlocker.Schedule"
    private let activityRawValuePrefix = "AppBlocker.Schedule."

    // MARK: - Schedule Events

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        // H5: タイマーの OS バックストップ用 activity ("AppBlocker.Timer") はここでは何もしない。
        // タイマーの shield 適用は TimerManager (メインアプリ) が既にアプリ内で行っており、
        // ここでの処理はスケジュール専用ロジックに限定する
        // (isScheduleActivity は "AppBlocker.Schedule" prefix のみを対象にしており、
        // "AppBlocker.Timer" は元々マッチしないが、意図を明示するためコメントで残す)
        guard isScheduleActivity(activity) else { return }

        let id = scheduleId(from: activity)
        let configs = loadScheduleConfigs()

        // M27: 前回の intervalDidEnd が (OS都合等で) 欠落していた場合、前日分の開始キーが
        // 残ったままこの新しい開始キーで上書きされると、その分がまるごと記録から消える。
        // 上書きするより前に必ず補完する。以降の C1/曜日ガード等でこの回の開始自体が
        // skip される場合でも、前日分の掃除は独立して必要なのでここで無条件に行う
        flushDanglingSessionIfNeeded(id: id, configs: configs)

        // C1: 課金失効が新鮮なフェッチで確定している場合は shield を張らない。
        // セッション開始記録もスキップする (遮断していないので累計時間に計上しない)
        guard isProBlockingEntitled() else {
            print("📅 Schedule interval started but Pro entitlement lapsed — skipping shield")
            return
        }

        // 曜日ガード: OS の DeviceActivitySchedule は曜日を絞れないため、
        // インターバル開始日の曜日が config.weekdays に含まれない回は shield を適用しない。
        // config が読めない場合は従来通り適用する (over-block より「スケジュールが無音で動かない」方が
        // ユーザーに気付かれず危険なため、フェイルセーフは「適用」側に倒す)
        if !configs.isEmpty {
            if let id {
                guard let config = configs.first(where: { $0.id == id }) else {
                    // 配列は読めているのに id が無い = 削除済みスケジュールの残骸イベント。
                    // ここはフェイルセーフの対象外 (適用すると削除したはずのロックが復活してしまう)
                    print("📅 Schedule interval started for unknown id \(id) — skipping shield")
                    return
                }
                if config.isEnabled == false {
                    // 無効化済み (監視停止が漏れた場合の保険)
                    print("📅 Schedule interval started but config disabled — skipping shield")
                    return
                }
                if !isIntervalStartWeekdayAllowed(config: config) {
                    print("📅 Schedule interval started but weekday not in config.weekdays — skipping shield")
                    return
                }
            } else if let legacy = configs.first {
                // 旧・単一形式の activity 名 (移行前)。従来と同じく先頭 config で曜日ガード
                if !isIntervalStartWeekdayAllowed(config: legacy) {
                    print("📅 Legacy schedule interval started but weekday not allowed — skipping shield")
                    return
                }
            }
        }

        // 名言ローテは quote pool 方式 (21c76d1) に一本化。旧 rotateShieldQuote は
        // Quotes.json 非同梱で無動作の死コードだったため削除 (2026-07-16)
        applyShieldForSchedule()

        // セッション開始時刻を記録 (累計ロック時間集計用、スケジュール別キー)
        recordSessionStart(id: id)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // H5: タイマーの OS バックストップ。TimerManager がプロセス生存中に自然完了/手動停止した
        // 場合は既に shield 解除・stopMonitoring 済みのはずだが、プロセスが死んでいる間に
        // 期限が来た場合はここが最後の砦になる。timer named store だけをクリアし、
        // schedule 側のセッション記録・和集合判定には一切触れない (別モードのため)。
        // セッション記録は次回アプリ起動時に TimerManager.restoreTimerState (期限切れ復元パス) が行う
        if activity.rawValue == timerActivityRawValue {
            clearTimerShield()
            return
        }

        guard isScheduleActivity(activity) else { return }

        let id = scheduleId(from: activity)

        // セッションをキューに追加 (Supabase 同期はメインアプリ起動時)
        recordSessionEnd(id: id)

        // 🔥 複数スケジュールの和集合: 他の有効スケジュールが現在時間帯内なら shield を残す。
        // (例: 9-12 と 11-13 が重なっている時、12 時の終了イベントで 11-13 の shield を消さない)
        let configs = loadScheduleConfigs()
        let othersStillActive = configs.contains { config in
            config.isEnabled != false && config.id != id && isWithinSchedule(config: config)
        }
        if othersStillActive {
            print("📅 Schedule interval ended but another schedule is active — keeping shield")
            return
        }

        // schedule named store だけ clear する（timer/location store には触らない）
        removeScheduleShield()
    }

    // MARK: - Activity Name Resolution

    private func isScheduleActivity(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue == legacyActivityRawValue || activity.rawValue.hasPrefix(activityRawValuePrefix)
    }

    /// "AppBlocker.Schedule.<uuid>" から uuid を取り出す。旧形式 ("AppBlocker.Schedule") は nil
    private func scheduleId(from activity: DeviceActivityName) -> UUID? {
        let raw = activity.rawValue
        guard raw.hasPrefix(activityRawValuePrefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(activityRawValuePrefix.count)))
    }

    private func sessionStartKey(for id: UUID?) -> String {
        if let id {
            return scheduleActiveStartPrefix + id.uuidString
        }
        return scheduleActiveStartKey
    }

    // MARK: - Session Recording (累計時間集計)

    private func recordSessionStart(id: UUID?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: sessionStartKey(for: id))
    }

    /// - Parameter endedAt: セッションの終了時刻。通常は呼び出し時点 (Date()) だが、
    ///   M27 の前日分取りこぼし補完 (flushDanglingSessionIfNeeded) では
    ///   「そのスケジュールの期待終了時刻」を明示的に渡す
    private func recordSessionEnd(id: UUID?, endedAt: Date = Date()) {
        let key = sessionStartKey(for: id)
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let startTs = defaults.object(forKey: key) as? TimeInterval else {
            return
        }

        let endTs = endedAt.timeIntervalSince1970
        // 7日超 (開始キーの残留等) は 015 の validate_block_session に永久拒否されるため、
        // started_at 側を切り詰めて duration と timestamp を両方クランプする。
        // ⚠️ BlockSessionTracker.repairedInterval と同じ補正。片方だけ直さないこと
        var clampedStartTs = startTs
        if endTs - clampedStartTs > 604800 {
            clampedStartTs = endTs - 604800
        }
        let duration = max(0, Int(endTs - clampedStartTs))
        guard duration > 0 else {
            defaults.removeObject(forKey: key)
            return
        }

        var entry: [String: Any] = [
            "entry_id": UUID().uuidString,   // flush 後の個別削除用 (BlockSessionTracker と同期, H2/H3)
            "mode": "schedule",
            "started_at": clampedStartTs,
            "ended_at": endTs,
            "duration_seconds": duration,
            "status": "completed"
        ]
        // H3: 現サインインユーザーを刻印 (本体が currentUserId キーへミラー済み)。
        // ミラーが無い (サインアウト中) 場合は user_id 無しで積まれ、flush 時に破棄される
        if let uid = defaults.string(forKey: currentUserIdKey) {
            entry["user_id"] = uid
        }

        var queue = defaults.array(forKey: pendingBlockSessionsKey) as? [[String: Any]] ?? []
        queue.append(entry)
        defaults.set(queue, forKey: pendingBlockSessionsKey)
        defaults.removeObject(forKey: key)
    }

    // MARK: - M27: 前日分の取りこぼし防止

    /// intervalDidStart で新しい開始キーを書く前に呼ぶ。閉じられていない (= intervalDidEnd が
    /// 欠落した) 前回分の開始キーが残っていれば、「そのスケジュールの期待終了時刻」で
    /// completed セッションとして補完してからキューに積む (recordSessionEnd をそのまま再利用する
    /// ことで entry_id/user_id 刻印パターン・7日クランプを完全に踏襲する)。
    /// 開始キーが残っていなければ何もしない (通常の正常系はここで即 return)
    private func flushDanglingSessionIfNeeded(id: UUID?, configs: [ScheduleConfigMirror]) {
        let key = sessionStartKey(for: id)
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let startTs = defaults.object(forKey: key) as? TimeInterval else {
            return
        }

        let startedAt = Date(timeIntervalSince1970: startTs)
        let config = id != nil ? configs.first(where: { $0.id == id }) : configs.first
        let expectedEnd = expectedEndDate(startedAt: startedAt, config: config)

        print("⚠️ M27: dangling schedule session found (\(key)) at new intervalDidStart — flushing as completed before overwrite")
        recordSessionEnd(id: id, endedAt: expectedEnd)
    }

    /// 開始時刻 + スケジュール窓の長さ (endHour:endMinute - startHour:startMinute。深夜跨ぎで
    /// end <= start の場合は +24h) から、その回の期待終了時刻を算出する。
    /// config が見つからない/窓の長さが異常な場合は開始+24hへ安全側クランプする。
    /// 「今」より後にはならないようにもクランプする (新しい intervalDidStart が発火している時点で
    /// 前日分は必ず過去のはずだが、config 破損等の異常系に備える)
    private func expectedEndDate(startedAt: Date, config: ScheduleConfigMirror?) -> Date {
        let fallback = startedAt.addingTimeInterval(86400) // 安全側クランプ (24h)
        guard let config else { return min(fallback, Date()) }

        let startMinutes = config.startHour * 60 + config.startMinute
        let endMinutes = config.endHour * 60 + config.endMinute
        let windowMinutes = endMinutes > startMinutes
            ? (endMinutes - startMinutes)
            : (endMinutes + 24 * 60 - startMinutes)

        guard windowMinutes > 0 else { return min(fallback, Date()) }

        let candidate = startedAt.addingTimeInterval(TimeInterval(windowMinutes * 60))
        return min(candidate, Date(), fallback)
    }

    // MARK: - Shield Methods

    private func applyShieldForSchedule() {
        guard let selection = loadSelection(forKey: "scheduleSelection") else { return }
        applyShield(selection: selection)
    }

    private func applyShield(selection: FamilyActivitySelection) {
        // カテゴリと個別アプリは併用可能 (和集合)。旧「カテゴリ優先」分岐は
        // 両方選んだ時に個別アプリが遮断されない穴だった (2026-07-16 Fableレビュー)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    /// schedule named store だけ shield を解除する。
    /// timer/location は別 named store なので影響を受けない（タイマー巻き添え解除を防止）
    private func removeScheduleShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    /// H5: タイマー専用 named store ("timer") だけを clear する。
    /// schedule/location の named store には触らない (モード間の巻き添え解除を防止)。
    /// TimerManager が既に removeShield 済みのケースでも冪等に呼べる (nil 代入は無害)
    private func clearTimerShield() {
        timerStore.shield.applications = nil
        timerStore.shield.applicationCategories = nil
        print("⏱️ Timer OS backstop fired — timer shield cleared")
    }

    // MARK: - Storage

    private func loadSelection(forKey key: String) -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    /// C1: メインアプリが App Group にミラーした Pro 遮断の実行可否。
    /// キー未設定 = 未確定は「許可」に倒す (オフライン起動の Pro ユーザーを誤解除しないため)。
    /// 再課金するとメインアプリ側がミラーを true に戻すので、次のインターバルから自動で復活する
    private func isProBlockingEntitled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return true }
        return (defaults.object(forKey: proBlockingEntitledKey) as? Bool) ?? true
    }

    // MARK: - Schedule Config Mirror (曜日ガード / 和集合判定用)

    /// メインアプリの ScheduleConfig (Core/Models/BlockMode.swift) を最小ミラーした Codable struct。
    /// Extension は別ターゲットで ScheduleConfig 型に直接アクセスできないため、
    /// フィールド構成 (id/startHour/startMinute/endHour/endMinute/weekdays/isEnabled) を手動同期させる。
    /// id/isEnabled は旧・単一形式の保存データに存在しないため Optional で受ける。
    /// ⚠️ SwiftUI import 禁止 (Extension のメモリ予算) なので Foundation の Codable のみで完結させること
    private struct ScheduleConfigMirror: Codable {
        let id: UUID?
        let startHour: Int
        let startMinute: Int
        let endHour: Int
        let endMinute: Int
        let weekdays: [Int] // 1=日曜, 2=月曜, ... 7=土曜
        let isEnabled: Bool?
    }

    /// App Group のスケジュール設定をデコード。
    /// 複数形式 (scheduleConfigs, JSON 配列) を優先し、旧・単一形式 (scheduleConfig) にフォールバック
    private func loadScheduleConfigs() -> [ScheduleConfigMirror] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }

        if let data = defaults.data(forKey: scheduleConfigsKey),
           let configs = try? JSONDecoder().decode([ScheduleConfigMirror].self, from: data) {
            return configs
        }

        if let data = defaults.data(forKey: scheduleConfigKey),
           let legacy = try? JSONDecoder().decode(ScheduleConfigMirror.self, from: data) {
            return [legacy]
        }

        return []
    }

    /// インターバル開始日の曜日が config.weekdays に含まれるかどうか。
    /// 深夜跨ぎ (start > end) で現在時刻が endTime より前の場合、このインターバルは
    /// 「昨日」開始したものなので昨日の曜日で判定する。
    /// ⚠️ この判定ロジックは ScheduleManager.isWithinSchedule (AppBlocker/Core/Services/ScheduleManager.swift)
    /// と同じ考え方で揃えること。片方だけ直すと深夜跨ぎスケジュールで extension と main app の判断がずれる
    private func isIntervalStartWeekdayAllowed(config: ScheduleConfigMirror) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday else {
            // 判定不能 (異常系) → フェイルセーフで適用側に倒す
            return true
        }

        let currentTime = hour * 60 + minute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute
        let isOvernight = startTime > endTime

        if isOvernight && currentTime < endTime {
            // このインターバルは前日に開始している → 昨日の曜日で判定
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                return config.weekdays.contains(weekday)
            }
            let yesterdayWeekday = calendar.component(.weekday, from: yesterday)
            return config.weekdays.contains(yesterdayWeekday)
        } else {
            return config.weekdays.contains(weekday)
        }
    }

    /// 現在時刻が config の時間帯内か (曜日込み)。
    /// ⚠️ ScheduleManager.isWithinSchedule と同じアルゴリズム。片方だけ直さないこと
    private func isWithinSchedule(config: ScheduleConfigMirror) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday else {
            return false
        }

        let currentTime = hour * 60 + minute
        let startTime = config.startHour * 60 + config.startMinute
        let endTime = config.endHour * 60 + config.endMinute

        if startTime < endTime {
            // 同日内のスケジュール（例: 09:00 - 17:00）→ 今日の曜日で判定
            guard config.weekdays.contains(weekday) else { return false }
            return currentTime >= startTime && currentTime < endTime
        } else {
            // 日をまたぐスケジュール（例: 22:00 - 07:00）
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
}
