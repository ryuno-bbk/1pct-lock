//
//  AppGroupIdentifier.swift
//  AppBlocker
//
//  App Group識別子の定義
//

import Foundation

/// App Group関連の定数
enum AppGroupConstants {
    /// App Group識別子
    /// ⚠️ Xcode の Signing & Capabilities で同じ値を設定すること
    static let identifier = "group.com.ryunosuke.appblocker.shared"

    /// UserDefaultsのキー
    enum Keys {
        static let currentQuote = "currentQuote"
        /// Shield が表示のたびランダムに1件引くための名言プール (JSON encoded [SharedQuote])。
        /// これを使うことで Extension は 175 件バンドル JSON をパースせずに済み
        /// (コールドスタート 11 秒フリーズの主因を回避)、かつ表示ごとに名言をローテーションできる
        static let quotePool = "quotePool"
        /// Shield Extension のキャッシュ無効化用タイムスタンプ
        /// メインアプリで名言を更新するたびに新しい値を書き、Extension はこれを見て再読込
        static let quoteUpdatedAt = "quoteUpdatedAt"
        static let selectedQuoteId = "selectedQuoteId"
        /// Shield 案A (アプリ名主導) のサブタイトルに使う、ユーザーの「夢」(user_dreams.dream) のミラー。
        /// 本体側の 3 箇所 (オンボ保存 / プロフィール編集保存 / 起動時ロード) から書き込む。
        /// 未宣言時はキー自体を削除する (空文字列は保存しない)
        static let userDream = "userDream"
        static let blockSession = "blockSession"
        static let userSettings = "userSettings"
        static let backgroundStyle = "backgroundStyle"

        // タイマー設定
        static let timerConfig = "timerConfig"
        static let timerSelection = "timerSelection"
        static let timerSession = "timerSession"

        // スケジュール設定
        /// 旧・単一スケジュール形式 (JSON encoded ScheduleConfig)。複数化 (2026-07-15) 後は
        /// getScheduleConfigs が読み取り時に scheduleConfigs へ移行し、このキーは削除される
        static let scheduleConfig = "scheduleConfig"
        /// 複数スケジュール形式 (JSON encoded [ScheduleConfig]、上限 ScheduleManager.maxSchedules)
        static let scheduleConfigs = "scheduleConfigs"
        static let scheduleSelection = "scheduleSelection"
        static let scheduleSession = "scheduleSession"

        // 位置情報ロック設定
        static let locationSelection = "locationBlockSelection"
        static let registeredLocations = "registeredLocations"

        // オンボ診断 (UsageReportExtension が読む。Report拡張は App Group 書き込み不可のため
        // 本体→拡張への一方通行の入力値)
        /// 自己申告の1日使用時間 (分)。usageReveal 表示前に本体が書く
        static let onboardingEstimateMinutes = "onboardingEstimateMinutes"
        /// 表示言語 ("japanese"/"english")
        static let onboardingLanguage = "onboardingLanguage"
        /// usageReveal のフェーズ ("comparison"/"topApps")。拡張は1シーン統合のため
        /// このフラグで表示内容を切り替える
        static let onboardingRevealPhase = "onboardingRevealPhase"

        // ブロックセッション記録（累計時間集計用）
        /// 完了済みセッションのキュー。起動時に Supabase へ一括 insert
        static let pendingBlockSessions = "pendingBlockSessions"
        /// 現サインインユーザーの UUID (lowercased) のミラー — enqueue 時の user_id 刻印用 (H3)。
        /// 本体 (UserAuthService) がサインイン成功/セッション復元成功で書き、signOut() で消す。
        /// restoreSession の一時的な失敗 (オフライン等) では消さない (夢ミラーと同じ F5 方針)。
        /// Extension は別ターゲットのためハードコード参照 (DeviceActivityMonitorExtension.swift)
        static let currentUserId = "currentUserId"
        /// schedule モード開始時刻 (TimeInterval) — Extension が書く (旧・単一スケジュール形式)
        static let scheduleActiveStart = "scheduleActiveStart"
        /// schedule 複数化後のスケジュール別開始時刻プレフィックス (key: "scheduleActiveStart_<uuid>")
        static let scheduleActiveStartPrefix = "scheduleActiveStart_"
        /// location モード region 別開始時刻のプレフィックス (key: "locationActiveStart_<uuid>")
        static let locationActiveStartPrefix = "locationActiveStart_"

        // 課金失効リコンサイル (C1)
        /// Pro 遮断 (スケジュール/位置) の実行可否ミラー (Bool)。
        /// ProAccess.reconcileEntitlementMirror が「新鮮なフェッチで確定した」ときだけ書く
        /// (キャッシュのみで false を書くとオフライン起動の Pro ユーザーを誤解除するため)。
        /// キー未設定 = 未確定は「実行許可」に倒す (fail-open)。
        /// ⚠️ DeviceActivityMonitorExtension は同名文字列をハードコードしているので同期させること
        static let proBlockingEntitled = "proBlockingEntitled"
    }

    /// ManagedSettingsStore の名前
    /// 各モード独立のストアを使うことで「同時運用中に他モードの shield を破壊しない」を保証する
    /// Apple 仕様: 複数の named store がある場合、最も制限の厳しい設定が結合される
    enum Stores {
        static let timer = "timer"
        static let schedule = "schedule"
        static let location = "location"
    }
}
