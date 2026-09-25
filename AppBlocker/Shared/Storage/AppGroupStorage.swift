//
//  AppGroupStorage.swift
//  AppBlocker
//
//  App Group経由でのデータ保存・取得
//

import Foundation

/// App Group UserDefaults ラッパー
final class AppGroupStorage {

    static let shared = AppGroupStorage()

    private let userDefaults: UserDefaults?

    private init() {
        userDefaults = UserDefaults(suiteName: AppGroupConstants.identifier)
    }

    // MARK: - Quote

    /// 現在の名言を保存
    /// Shield Extension のキャッシュ無効化用に更新タイムスタンプも書き込む
    func saveCurrentQuote(_ quote: SharedQuote) {
        guard let data = try? JSONEncoder().encode(quote) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.currentQuote)
        userDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.Keys.quoteUpdatedAt)
        userDefaults?.synchronize()
    }

    /// 現在の名言を取得
    func getCurrentQuote() -> SharedQuote? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.currentQuote),
              let quote = try? JSONDecoder().decode(SharedQuote.self, from: data) else {
            return nil
        }
        return quote
    }

    /// Shield 用の名言プールを保存 (表示のたび Extension がここからランダムに1件引く)。
    /// これにより Extension 側は 175 件 JSON パースを完全に不要にできる
    func saveQuotePool(_ quotes: [SharedQuote]) {
        guard !quotes.isEmpty, let data = try? JSONEncoder().encode(quotes) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.quotePool)
        userDefaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.Keys.quoteUpdatedAt)
        userDefaults?.synchronize()
    }

    // MARK: - Dream (Shield 案A サブタイトル用)

    /// ユーザーの「夢」を Shield Extension 用に App Group へミラー保存する。
    /// nil または空文字は未宣言扱いでキーごと削除する (Extension 側は「キー無し→名言フォールバック」で判定)
    func saveUserDream(_ dream: String?) {
        let trimmed = dream?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            userDefaults?.set(trimmed, forKey: AppGroupConstants.Keys.userDream)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.userDream)
        }
        userDefaults?.synchronize()
    }

    /// ミラー保存済みの「夢」を取得。未宣言なら nil
    func getUserDream() -> String? {
        userDefaults?.string(forKey: AppGroupConstants.Keys.userDream)
    }

    // MARK: - Current User ID Mirror (セッション帰属用, H3)

    /// 現サインインユーザーの UUID を App Group へミラー保存する。
    /// enqueue (本体 / DeviceActivityMonitorExtension) がセッション行に user_id を刻印するために読む。
    /// nil はサインアウト確定時のみ渡す (キーごと削除)。lowercased で保存する
    /// (Supabase auth.uid() が lowercase のため、SessionInsert と同じ流儀で揃える)
    func saveCurrentUserId(_ userId: UUID?) {
        if let userId {
            userDefaults?.set(userId.uuidString.lowercased(), forKey: AppGroupConstants.Keys.currentUserId)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.currentUserId)
        }
        userDefaults?.synchronize()
    }

    // MARK: - Language Sync (Shield 表示言語用)

    /// メインアプリの表示言語 ("japanese"/"english") を Shield Extension が読めるようミラーする。
    /// UsageReportExtension が既に読んでいる onboardingLanguage キーを流用し、
    /// 起動のたびに現在値で上書きすることで、オンボ後に設定画面で言語を変えても
    /// 次回起動時点で Shield 側に反映される (完全リアルタイムではない旨は既知の制約)
    func syncCurrentLanguage(isJapanese: Bool) {
        userDefaults?.set(isJapanese ? "japanese" : "english", forKey: AppGroupConstants.Keys.onboardingLanguage)
        userDefaults?.synchronize()
    }

    // MARK: - Onboarding 診断入力 (UsageReportExtension への受け渡し)

    /// usageReveal 表示前に自己申告値と言語を書き込む。
    /// Report 拡張はこれを読んで「予想 vs 実測」比較を拡張内で描画する
    func saveOnboardingRevealInputs(estimateMinutes: Int, languageRaw: String) {
        userDefaults?.set(estimateMinutes, forKey: AppGroupConstants.Keys.onboardingEstimateMinutes)
        userDefaults?.set(languageRaw, forKey: AppGroupConstants.Keys.onboardingLanguage)
        userDefaults?.synchronize()
    }

    /// usageReveal のフェーズ ("comparison"/"topApps") を書き込む。
    /// 書いた後にフィルタを微変更して再クエリを起こすと、拡張が makeConfiguration で
    /// このフラグを読み直して表示を切り替える
    func saveOnboardingRevealPhase(_ phase: String) {
        userDefaults?.set(phase, forKey: AppGroupConstants.Keys.onboardingRevealPhase)
        userDefaults?.synchronize()
    }

    // MARK: - Settings

    /// 設定を保存
    func saveSettings(_ settings: SharedSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.userSettings)
        userDefaults?.synchronize()
    }

    /// 設定を取得
    func getSettings() -> SharedSettings {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.userSettings),
              let settings = try? JSONDecoder().decode(SharedSettings.self, from: data) else {
            return SharedSettings()
        }
        return settings
    }

    // MARK: - Background Style

    /// 背景スタイルを保存
    func saveBackgroundStyle(_ style: BackgroundStyle) {
        userDefaults?.set(style.rawValue, forKey: AppGroupConstants.Keys.backgroundStyle)
        userDefaults?.synchronize()
    }

    /// 背景スタイルを取得
    func getBackgroundStyle() -> BackgroundStyle {
        guard let rawValue = userDefaults?.string(forKey: AppGroupConstants.Keys.backgroundStyle),
              let style = BackgroundStyle(rawValue: rawValue) else {
            return .solidBlack
        }
        return style
    }

    // MARK: - Block Session (Legacy)

    /// ブロックセッションを保存（旧API互換）
    func saveBlockSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.blockSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.blockSession)
        }
        userDefaults?.synchronize()
    }

    /// ブロックセッションを取得（旧API互換）
    func getBlockSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.blockSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Timer Session（独立セッション）

    /// タイマーセッションを保存
    func saveTimerSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.timerSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.timerSession)
        }
        userDefaults?.synchronize()
    }

    /// タイマーセッションを取得
    func getTimerSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.timerSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Schedule Session（常駐型）

    /// スケジュールセッションを保存
    func saveScheduleSession(_ session: BlockSession?) {
        if let session = session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            userDefaults?.set(data, forKey: AppGroupConstants.Keys.scheduleSession)
        } else {
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleSession)
        }
        userDefaults?.synchronize()
    }

    /// スケジュールセッションを取得
    func getScheduleSession() -> BlockSession? {
        guard let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleSession),
              let session = try? JSONDecoder().decode(BlockSession.self, from: data) else {
            return nil
        }
        return session
    }

    // MARK: - Schedule Configs (複数対応 2026-07-15)

    /// スケジュール設定 (配列) を保存。上限の強制は ScheduleManager 側で行う
    func saveScheduleConfigs(_ configs: [ScheduleConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        userDefaults?.set(data, forKey: AppGroupConstants.Keys.scheduleConfigs)
        userDefaults?.synchronize()
    }

    /// スケジュール設定 (配列) を取得。
    /// 旧・単一形式 (scheduleConfig キー) が残っていれば配列に包んで即永続化し、旧キーを削除する
    /// (旧形式には id が無くデコードごとに UUID が変わるため、ここで確定させないと
    /// DeviceActivityName とセッション記録キーが起動のたびにズレる)
    func getScheduleConfigs() -> [ScheduleConfig] {
        if let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleConfigs),
           let configs = try? JSONDecoder().decode([ScheduleConfig].self, from: data) {
            return configs
        }

        // 旧単一形式からの読み取り時移行
        if let data = userDefaults?.data(forKey: AppGroupConstants.Keys.scheduleConfig),
           let legacy = try? JSONDecoder().decode(ScheduleConfig.self, from: data) {
            let migrated = [legacy]
            saveScheduleConfigs(migrated)
            userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfig)
            userDefaults?.synchronize()
            return migrated
        }

        return []
    }

    /// スケジュール設定を全削除 (旧キーも掃除する)
    func removeScheduleConfigs() {
        userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfigs)
        userDefaults?.removeObject(forKey: AppGroupConstants.Keys.scheduleConfig)
    }

    // MARK: - Pro Blocking Entitlement Mirror (C1)

    /// Pro 遮断 (スケジュール/位置) の実行可否ミラーを書き込む。
    /// false を書いてよいのは ProAccess.reconcileEntitlementMirror (新鮮なフェッチで失効確定) のみ。
    /// true は ProAccess.recompute の正方向 (購入直後の即時復活) からも書かれる
    func saveProBlockingEntitled(_ entitled: Bool) {
        userDefaults?.set(entitled, forKey: AppGroupConstants.Keys.proBlockingEntitled)
        userDefaults?.synchronize()
    }

    /// Pro 遮断の実行可否を取得。未確定 (キー無し) は true = 許可に倒す
    /// (オフライン起動・初回アップデート直後に正規 Pro の遮断を誤解除しないため)
    func isProBlockingEntitled() -> Bool {
        (userDefaults?.object(forKey: AppGroupConstants.Keys.proBlockingEntitled) as? Bool) ?? true
    }

    // MARK: - Clear

    /// すべてのデータをクリア
    /// ログアウトやアカウント削除時にも呼ばれるので、App Group 側に残る全キーを網羅すること
    func clearAll() {
        let keys = [
            AppGroupConstants.Keys.currentQuote,
            AppGroupConstants.Keys.quotePool,
            AppGroupConstants.Keys.quoteUpdatedAt,
            AppGroupConstants.Keys.selectedQuoteId,
            AppGroupConstants.Keys.userDream,
            AppGroupConstants.Keys.currentUserId,
            AppGroupConstants.Keys.blockSession,
            AppGroupConstants.Keys.userSettings,
            AppGroupConstants.Keys.backgroundStyle,
            // タイマー
            AppGroupConstants.Keys.timerConfig,
            AppGroupConstants.Keys.timerSelection,
            AppGroupConstants.Keys.timerSession,
            // スケジュール
            AppGroupConstants.Keys.scheduleConfig,
            AppGroupConstants.Keys.scheduleConfigs,
            AppGroupConstants.Keys.scheduleSelection,
            AppGroupConstants.Keys.scheduleSession,
            // 位置情報
            AppGroupConstants.Keys.locationSelection,
            AppGroupConstants.Keys.registeredLocations,
            // 課金 (C1)
            AppGroupConstants.Keys.proBlockingEntitled
        ]
        keys.forEach { userDefaults?.removeObject(forKey: $0) }
        userDefaults?.synchronize()
    }

    /// ユーザー固有データのみをクリア (サインアウト/アカウント削除時、M16 監査2026-07-20対応)。
    /// clearAll() は課金失効ミラーやキューまで含めて全消しするため、サインアウト用途には過剰:
    /// - proBlockingEntitled を消すと nil=fail-open (許可) 側に倒れてしまう (C1)
    /// - pendingBlockSessions を消すと user_id 刻印済みの未送信セッションが失われる (H3)
    /// ここでは「端末共有時に前ユーザーの位置座標/スケジュール設定/Shield表示キャッシュが
    /// 次ユーザーへ漏れる」ことの防止に範囲を限定する。
    ///
    /// 意図的に対象外 (残す):
    /// - pendingBlockSessions: 各行に user_id 刻印済み、本人の再サインイン時に正しく flush される
    /// - onboardingLanguage (currentLanguage ミラー兼用) / onboardingEstimateMinutes / onboardingRevealPhase:
    ///   デバイスレベル設定・サインイン前提でないオンボ入力値
    /// - proBlockingEntitled: nil にすると fail-open になるため触らない (M17でエンジン自体を止める)
    /// - userDream / currentUserId: signOut() 内で確定タイミングが別管理のため、そちらで個別に消す
    func clearUserSpecificData() {
        let keys = [
            // Shield 表示用キャッシュ (名言) — 前ユーザーの選択が次ユーザーに一瞬見える事故を防ぐ
            AppGroupConstants.Keys.currentQuote,
            AppGroupConstants.Keys.quotePool,
            AppGroupConstants.Keys.quoteUpdatedAt,
            AppGroupConstants.Keys.selectedQuoteId,
            // 旧・現行の各セッションミラー
            AppGroupConstants.Keys.blockSession,
            // タイマー (TimerManager.stopTimer() が timerConfig は消すが、選択/セッションも念のため)
            AppGroupConstants.Keys.timerConfig,
            AppGroupConstants.Keys.timerSelection,
            AppGroupConstants.Keys.timerSession,
            // スケジュール (ScheduleManager.stopMonitoring() が configs は消すが、選択は消えないため必須)
            AppGroupConstants.Keys.scheduleConfig,
            AppGroupConstants.Keys.scheduleConfigs,
            AppGroupConstants.Keys.scheduleSelection,
            AppGroupConstants.Keys.scheduleSession,
            // 位置情報 (座標/半径) — LocationManager.removeLocation() ループで registeredLocations は
            // 空配列化されるが、アプリ選択 (locationSelection) は別キーのため必須
            AppGroupConstants.Keys.locationSelection,
            AppGroupConstants.Keys.registeredLocations
        ]
        keys.forEach { userDefaults?.removeObject(forKey: $0) }

        // scheduleActiveStart_<uuid> / locationActiveStart_<uuid> はスケジュール/地点ごとに
        // 動的なキー名 (プレフィックス+UUID) のため上の配列に列挙できない。
        // スケジュール側は ScheduleManager.stopMonitoring() が事前に flush 済みだが、
        // LocationManager には同等の flush 公開APIが無く signOut 時点の在室セッションが
        // 未flushで残り得るため、プレフィックス一致で残骸を総ざらいする
        // (この場合そのセッションは completed としてキューに積まれず、統計からは欠落する — 既知の制約)
        if let defaults = userDefaults {
            let prefixes = [
                AppGroupConstants.Keys.scheduleActiveStartPrefix,
                AppGroupConstants.Keys.locationActiveStartPrefix
            ]
            for key in defaults.dictionaryRepresentation().keys {
                if key == AppGroupConstants.Keys.scheduleActiveStart || prefixes.contains(where: { key.hasPrefix($0) }) {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        userDefaults?.synchronize()
    }
}
