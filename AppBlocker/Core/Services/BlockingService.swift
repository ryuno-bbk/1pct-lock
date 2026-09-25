//
//  BlockingService.swift
//  AppBlocker
//
//  3 モード（タイマー / スケジュール / 位置）統括サービス
//  各 Manager は専用 named store を持つので、ここで store を直接触らない
//

import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity

/// アプリブロック管理サービス
final class BlockingService: ObservableObject {

    @MainActor static let shared = BlockingService()

    // MARK: - Published Properties

    /// タイマーセッション（独立動作）
    @Published private(set) var timerSession: BlockSession?

    /// スケジュールセッション（常駐型）
    @Published private(set) var scheduleSession: BlockSession?

    /// 選択されたアプリ（タイマー/スケジュール共有、location は LocationManager 内で別管理）
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection()

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// ロック開始直後の「準備中」オーバーレイ表示フラグ。
    /// shield 適用 (メインスレッド同期の重い書き込み) 直後にホームへ遷移すると固まる症状の緩和用。
    /// この間ユーザーの操作を封じ、システムが enforcement を立ち上げる猶予を作る。
    /// startTimerBlockingWithSettle 参照。
    @Published var isPreparingLock = false

    /// いずれかの制限が有効かどうか
    var isBlocking: Bool {
        isTimerActive || isScheduleActive || isLocationActive
    }

    /// タイマーが有効か
    var isTimerActive: Bool {
        TimerManager.shared.isRunning
    }

    /// スケジュールが有効か（時間帯内で制限中）
    var isScheduleActive: Bool {
        ScheduleManager.shared.isShieldActive
    }

    /// スケジュールが設定されているか（時間帯外でも）
    var isScheduleConfigured: Bool {
        ScheduleManager.shared.isMonitoring
    }

    /// 位置情報ロックが有効か（ジオフェンス内で制限中）
    var isLocationActive: Bool {
        LocationManager.shared.isShieldActive
    }

    // MARK: - Dependencies

    private let storage = AppGroupStorage.shared

    // MARK: - Init

    @MainActor
    private init() {
        restoreState()
    }

    // MARK: - Timer Methods（独立セッション）

    /// タイマーブロックを開始
    @MainActor
    func startTimerBlocking(durationMinutes: Int) {
        guard !selectedApps.applicationTokens.isEmpty ||
              !selectedApps.categoryTokens.isEmpty else {
            errorMessage = "ブロックするアプリを選択してください"
            return
        }

        errorMessage = nil

        // ブロック開始ごとに新しい名言をローテーション
        QuoteService.shared.shuffleQuote()
        if let quote = QuoteService.shared.currentQuote {
            saveQuoteForShield(quote)
        }
        // Shield 表示ごとの名言ローテーション用プールも更新 (Extension の重い JSON パース回避)
        saveQuotePoolForShield()

        // タイマーを開始（TimerManager が timer named store に shield を設定）
        TimerManager.shared.startTimer(
            durationMinutes: durationMinutes,
            apps: selectedApps
        )

        // セッションを保存
        let config = TimerConfig(durationMinutes: durationMinutes)
        let session = BlockSession(mode: .timer, timerConfig: config)
        timerSession = session
        storage.saveTimerSession(session)

        // 🔴 解除課題をこの時点の設定で焼き付ける。以降このセッションが終わるまで
        //    設定を緩めても効かない (ロック中に設定を下げて逃げるのを防ぐ)
        UnlockChallengeService.shared.beginSession(id: session.id)

        print("⏱️ Timer blocking started: \(durationMinutes) minutes")
    }

    /// ロック開始 + 「準備中」オーバーレイでの settling 猶予つき版。
    ///
    /// 背景: startTimerBlocking 内の shield 適用 (`store.shield.applications = tokens`) は
    /// メインスレッド同期の重い書き込み。適用直後にユーザーがホームへ遷移/バックグラウンド化
    /// すると、システムが enforcement を立ち上げる最中とレースして固まる症状がある。
    /// くるくるを ~3s 見せて操作を封じ、その揮発ウィンドウを跨がせないことで緩和する。
    ///
    /// 注意: これは Apple Extension の cold-start フリーズ (= ブロック対象アプリを開いた瞬間に
    /// Shield extension が cold start して数秒固まる、project_known_issues.md B項) には効かない。
    /// あれは別プロセス・別タイミングの Apple 構造制約であり、メインアプリのスピナーでは防げない。
    /// この関数が効くなら「メインスレッドヒッチ/spin-up レース」の方 (フリーズ②) を見ていた証拠になる。
    @MainActor
    func startTimerBlockingWithSettle(durationMinutes: Int) async {
        // 前提チェックはスピナーを出す前に (アプリ未選択なら即エラーで抜ける)
        guard !selectedApps.applicationTokens.isEmpty ||
              !selectedApps.categoryTokens.isEmpty else {
            errorMessage = "ブロックするアプリを選択してください"
            return
        }

        isPreparingLock = true
        // 1 フレーム譲ってスピナーを先に描画させてから重い shield 書き込みへ入る
        await Task.yield()

        startTimerBlocking(durationMinutes: durationMinutes)

        // enforcement が落ち着くまで保持。この間はオーバーレイで操作を封じ、遷移レースを防ぐ。
        // 3秒 = ユーザー体感で「これくらい待てば固まらない」の値 (2026-07-07 実機フィードバック)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        isPreparingLock = false
    }

    /// タイマーブロックを停止
    @MainActor
    func stopTimerBlocking() {
        TimerManager.shared.stopTimer()
        timerSession = nil
        storage.saveTimerSession(nil)
        UnlockChallengeService.shared.endSession()

        print("⏱️ Timer blocking stopped")
    }

    // MARK: - Schedule Methods（常駐型）

    /// スケジュールを追加 (複数対応、上限は ScheduleManager.maxSchedules)
    /// apps はスケジュール専用のローカル選択 (2026-07-16 Fableレビュー: タイマーの selectedApps 流用を廃止)
    @MainActor
    func startScheduleBlocking(config: ScheduleConfig, apps: FamilyActivitySelection) {
        // ブロック開始ごとに新しい名言をローテーション
        QuoteService.shared.shuffleQuote()
        if let quote = QuoteService.shared.currentQuote {
            saveQuoteForShield(quote)
        }
        // Shield 表示ごとの名言ローテーション用プールも更新 (Extension の重い JSON パース回避)
        saveQuotePoolForShield()

        do {
            try ScheduleManager.shared.addSchedule(
                config: config,
                apps: apps
            )

            // セッションを保存
            let session = BlockSession(mode: .schedule, scheduleConfig: config)
            scheduleSession = session
            storage.saveScheduleSession(session)

            print("📅 Schedule blocking started")
        } catch {
            errorMessage = error.localizedDescription
            print("❌ Schedule blocking failed: \(error)")
        }
    }

    /// ロック開始 + 「準備中」オーバーレイでの settling 猶予つき版（A-7）。
    ///
    /// startTimerBlockingWithSettle と同型。時間帯内で即座にシールドが適用される場合のみ
    /// enforcement が落ち着くまで保持する。時間帯外での開始（監視登録だけで shield は未適用）は
    /// 重い同期書き込みが起きないので短い待ちだけで十分。
    @MainActor
    func startScheduleBlockingWithSettle(config: ScheduleConfig, apps: FamilyActivitySelection) async {
        isPreparingLock = true
        // 1 フレーム譲ってスピナーを先に描画させてから重い shield 書き込みへ入る
        await Task.yield()

        startScheduleBlocking(config: config, apps: apps)

        if ScheduleManager.shared.isShieldActive {
            // 時間帯内で即時 shield 適用になったケースのみ、timer と同じ 3秒保持でレースを避ける
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        } else {
            // 時間帯外での開始は監視登録のみ（重い shield 書き込みなし）なので短い待ちで十分
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        isPreparingLock = false
    }

    /// スケジュール設定を更新 (id で対象を特定)
    /// apps はスケジュール専用のローカル選択 (2026-07-16 Fableレビュー: タイマーの selectedApps 流用を廃止)
    @MainActor
    func updateScheduleBlocking(config: ScheduleConfig, apps: FamilyActivitySelection) {
        do {
            try ScheduleManager.shared.updateSchedule(
                config: config,
                apps: apps
            )

            // セッションを更新
            let session = BlockSession(mode: .schedule, scheduleConfig: config)
            scheduleSession = session
            storage.saveScheduleSession(session)

            print("📅 Schedule blocking updated")
        } catch {
            errorMessage = "スケジュールの更新に失敗しました: \(error.localizedDescription)"
            print("❌ Schedule update failed: \(error)")
        }
    }

    /// スケジュールを 1 件削除
    @MainActor
    func removeScheduleBlocking(id: UUID) {
        ScheduleManager.shared.removeSchedule(id: id)

        if ScheduleManager.shared.configs.isEmpty {
            scheduleSession = nil
            storage.saveScheduleSession(nil)
        }

        print("📅 Schedule removed")
    }

    /// スケジュールブロックを全停止 (サインアウト等の全消し用)
    @MainActor
    func stopScheduleBlocking() {
        ScheduleManager.shared.stopMonitoring()
        scheduleSession = nil
        storage.saveScheduleSession(nil)

        print("📅 Schedule blocking stopped")
    }

    // MARK: - Location Methods

    /// 位置情報ロックは LocationManager が CLLocationManager のジオフェンスイベントで自動 apply/remove する。
    /// ここでは "ロック対象アプリの選択を保存" の入口だけ提供する。
    @MainActor
    func saveLocationApps(_ selection: FamilyActivitySelection) {
        LocationManager.shared.saveSelection(selection)
    }

    // MARK: - Location Methods (settle 付きラッパー — フリーズ調査 2026-07-15)
    //
    // ジオフェンス内でトグル/追加すると、タップと同一 runloop ティックで store への重い同期書き込みが
    // 走り、timer が settle (A-7) で回避している enforcement 起動レースにそのまま突っ込んで
    // フリーズ + デフォルト Shield 表示になっていた。timer/schedule と同じ保護をかける

    /// 場所の有効/無効切り替え (settle 付き)
    @MainActor
    func toggleLocationWithSettle(_ location: RegisteredLocation) async {
        // これから ON にする時だけ在圏評価を待つ。toggleLocation は isEnabled を反転させるので、
        // 渡された location がまだ OFF = これから ON 化するケース
        await runLocationMutationWithSettle(waitsForEvaluation: !location.isEnabled) {
            LocationManager.shared.toggleLocation(location)
        }
    }

    /// 場所の追加 (settle 付き。追加地点の圏内に居ると即時シールドが走るため)
    @MainActor
    func addLocationWithSettle(_ location: RegisteredLocation) async {
        await runLocationMutationWithSettle {
            LocationManager.shared.addLocation(location)
        }
    }

    /// 場所の更新 (settle 付き)
    @MainActor
    func updateLocationWithSettle(_ location: RegisteredLocation) async {
        // updateLocation は在圏評価を要求しない (ジオフェンス再登録のみ) ので待たない
        await runLocationMutationWithSettle(waitsForEvaluation: false) {
            LocationManager.shared.updateLocation(location)
        }
    }

    @MainActor
    private func runLocationMutationWithSettle(waitsForEvaluation: Bool = true, _ mutation: () -> Void) async {
        // Shield 拡張コールドスタート時に名言プールが確実にあるように (timer/schedule 開始時と同じ。
        // location だけ未実施だった)
        saveQuotePoolForShield()

        isPreparingLock = true
        // 1 フレーム譲ってスピナーを先に描画させてから重い shield 書き込みへ入る
        await Task.yield()

        mutation()

        // 在圏評価は fix 到着駆動の非同期 (リトライ込みで最大 ~12 秒) なので、直後の
        // isShieldActive 同期チェックでは常に「未適用」に見えてスピナーが一瞬で消えていた。
        // 評価が解決するか、requestState 経由で先にシールドが付いたら待ちを打ち切る。
        // OFF/編集 (waitsForEvaluation: false) は評価を要求しない操作なので、
        // 先行チェーンの解決を相続して待たない。
        //
        // ⚠️ 上限は 6 秒。PreparingLockOverlay は全画面でタップを奪うため、リトライ全長
        // (12秒) を待つとフリーズと区別がつかない (「今いない場所」のロックを屋内で ON に
        // する = ごく普通の操作でこれを踏む)。6 秒で打ち切ってもシールド適用自体は
        // 評価の解決時に非同期で走るので、ロックがかからなくなるわけではない
        if waitsForEvaluation {
            let deadline = Date().addingTimeInterval(6)
            while LocationManager.shared.isEvaluatingRegion
                  && !LocationManager.shared.isShieldActive
                  && Date() < deadline {
                if Task.isCancelled { break }   // キャンセル時に try? が例外を握り潰してビジーループ化するのを防ぐ
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if LocationManager.shared.isShieldActive {
            // 即時シールド適用になったケースは enforcement が落ち着くまで保持 (timer A-7 と同じ 3 秒)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        isPreparingLock = false
    }

    // MARK: - Utility Methods

    /// 選択をリセット
    func resetSelection() {
        selectedApps = FamilyActivitySelection()
    }

    /// 現在の名言をShield用に保存
    func saveQuoteForShield(_ quote: Quote) {
        let sharedQuote = SharedQuote(from: quote)
        storage.saveCurrentQuote(sharedQuote)
    }

    /// Shield が表示のたびランダムに1件引くための名言プールを App Group に書き出す。
    /// これで Extension は 175 件 JSON パース (コールドスタート 11 秒フリーズの主因) を
    /// 一切せずに済み、かつロック画面が出るたび名言がローテーションする。
    /// タイマー/スケジュール/位置いずれのブロック開始でも、また起動時にも呼ぶ
    func saveQuotePoolForShield() {
        // Shield UI強化 (2026-07-16 ユーザー確定): プールは「ユーザーがいいねした名言」を優先。
        // personal な名言が夢の下に出る。いいねが 1 件も無ければ従来の全体ランダムプール
        let liked = LikeService.shared.likedQuotes
        let pool: [SharedQuote]
        if liked.isEmpty {
            pool = QuoteService.shared.randomPool(count: 40).map { SharedQuote(from: $0) }
        } else {
            pool = liked.shuffled().prefix(40).map { SharedQuote(from: $0) }
        }
        storage.saveQuotePool(pool)
    }

    // MARK: - Private: Restore State

    @MainActor
    private func restoreState() {
        // タイマーセッションを復元
        //
        // 注意: TimerManager.shared への参照は、ここで初めて TimerManager の init
        // (= restoreTimerState、期限切れ処理を含む) を走らせるトリガーになる。
        // BlockingService.init → restoreState() は @MainActor で TimerManager.shared も
        // @MainActor なので、この参照時点で TimerManager 側の復元 (期限切れなら
        // shield 解除 + storage.saveTimerSession(nil) まで) が先に完了してから
        // 以下の判定に入る。この順序は意図的なので変更しないこと。
        if let session = storage.getTimerSession(), session.isActive {
            // TimerManager が実際に稼働していない (＝自然終了/期限切れ/停止済み) のに
            // timerSession キーだけが残っている「幽霊アクティブセッション」を弾く。
            // C-2 (a) で timerCompleted() / restoreTimerState() の期限切れ分岐は
            // saveTimerSession(nil) するようにしたが、想定外の経路で残った場合の
            // 保険としてここでもクロスチェックする。
            if TimerManager.shared.isRunning {
                timerSession = session
            } else {
                storage.saveTimerSession(nil)
            }
        }

        // スケジュールセッションを復元
        if let session = storage.getScheduleSession(), session.isActive {
            scheduleSession = session
        }

        // 前回使ったタイマー用アプリ選択をプリフィルする (2026-07-15: オンボ末尾のアプリ選択を
        // 次回起動でも引き継ぐため。従来は起動ごとに空で、毎回選び直しだった)
        if selectedApps.applicationTokens.isEmpty && selectedApps.categoryTokens.isEmpty,
           let defaults = UserDefaults(suiteName: AppGroupConstants.identifier),
           let data = defaults.data(forKey: AppGroupConstants.Keys.timerSelection),
           let saved = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = saved
        }
    }

    // MARK: - Initial Shared Selection (オンボ末尾のアプリ選択)

    /// オンボ末尾で選んだアプリを 3 モード共通の初期値として保存する。
    /// 以後は各モードの画面で個別に変更できる (従来仕様のまま)
    @MainActor
    func saveInitialSharedSelection(_ selection: FamilyActivitySelection) {
        selectedApps = selection

        // タイマー: timerSelection キーへ直接書く (TimerManager と同じエンコード)。
        // 次回起動時は上の restoreState プリフィルが拾う
        if let defaults = UserDefaults(suiteName: AppGroupConstants.identifier),
           let data = try? PropertyListEncoder().encode(selection) {
            defaults.set(data, forKey: AppGroupConstants.Keys.timerSelection)
            defaults.synchronize()
        }

        ScheduleManager.shared.saveSelectionToAppGroup(selection)
        LocationManager.shared.saveSelection(selection)

        print("✅ Initial shared selection saved to all 3 modes")
    }
}
