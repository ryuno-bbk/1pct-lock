//
//  HomeView.swift
//  AppBlocker
//
//  メイン画面（モード切替 + 各モード設定）
//

import SwiftUI
import FamilyControls

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var blockingService = BlockingService.shared
    @ObservedObject private var timerManager = TimerManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var proAccess = ProAccess.shared
    @ObservedObject private var sessionTracker = BlockSessionTracker.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("selectedBlockMode") private var selectedModeRaw: String = BlockMode.timer.rawValue
    @AppStorage("shieldFirstRunHintShown") private var shieldFirstRunHintShown: Bool = false

    @State private var selectedMinutes: Int = 30
    @State private var showCustomDurationPicker = false
    @State private var showChallengePicker = false
    /// 解除方法の Pro 課題をタップした時のペイウォール。
    /// (モード自体のゲートは各モード画面側が持っている — selectMode のコメント参照)
    @State private var showChallengePaywall = false
    @ObservedObject private var challengeService = UnlockChallengeService.shared
    @State private var showingPicker = false
    @State private var showStopConfirmation = false
    @State private var hintToastMessage: String?
    @State private var showSessionComplete = false
    @State private var sessionCompleteFooterMessage: String?
    /// スケジュール/位置ロックの稼働状況シート (常駐バナー廃止の代替。実機FB 2026-07-15:
    /// バナーが増えるほどモード切替が下に押されるため、右上ボタン+ボトムシートに移設)
    @State private var showLockManager = false
    /// F3: scheduleAppCountText() は UserDefaults 読み込み + PropertyListDecoder デコードを伴うため、
    /// body 内で毎秒 (タイマー実行中の remainingSeconds publish 経由) 再評価されるのを防ぐためキャッシュする
    @State private var cachedScheduleAppCountText: String = ""

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var selectedMode: BlockMode {
        BlockMode(rawValue: selectedModeRaw) ?? .timer
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        modeSegment

                        // 解除方法。🔴 ここは3モード共通の位置なので、1箇所置けば
                        //    タイマー/スケジュール/位置の全部に出る。
                        //    ⚠️ 最終的な位置は実機を見てから決める (2026-08-28 保留)
                        // 🔴 実装済みの課題が1つしか無い間は出さない。
                        //    選択肢1つのピッカーはユーザーを混乱させるだけ。
                        //    次の課題 (ノート+ペン / スクロール / 投稿) が入れば自動で復活する
                        if UnlockChallenge.pickable.filter(\.isImplemented).count >= 2 {
                        UnlockChallengeCard(
                            challenge: isAnyLockRunning
                                ? (challengeService.activeChallenge ?? challengeService.selected)
                                : challengeService.selected,
                            lang: lang,
                            isLocked: isAnyLockRunning
                        ) {
                            showChallengePicker = true
                        }
                        }

                        switch selectedMode {
                        case .timer:
                            timerSection
                        case .schedule:
                            ScheduleBlockView(blockingService: blockingService)
                        case .location:
                            LocationBlockView()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
                }

                // 停止確認オーバーレイ
                if showStopConfirmation {
                    StopConfirmationView(
                        isPresented: $showStopConfirmation,
                        lang: lang,
                        onConfirm: { blockingService.stopTimerBlocking() },
                        challenge: UnlockChallengeService.shared.activeChallenge ?? .longPress
                    )
                    .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showChallengePicker) {
                UnlockChallengeSheet(
                    lang: lang,
                    hasPro: ProAccess.shared.canAccess(.schedule),
                    selected: $challengeService.selected,
                    onRequestPro: {
                        showChallengePicker = false
                        // シートを閉じてから出さないと重なって出ない
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showChallengePaywall = true
                        }
                    }
                )
                // 2026-09-05 実機FB: .medium (約50%) だとハードロックモードが見切れていた。
                // 5つ全部が一度に見える高さで開き、必要なら .large まで引き上げられる
                .presentationDetents([.fraction(0.75), .large])
            }
            .sheet(isPresented: $showChallengePaywall) {
                ProPaywallView(triggeredBy: .schedule)
            }
            .familyActivityPicker(
                isPresented: $showingPicker,
                selection: $blockingService.selectedApps
            )
            .sheet(isPresented: $showLockManager) {
                lockManagerSheet
            }
            .fullScreenCover(isPresented: $showSessionComplete) {
                SessionCompleteView(
                    duration: timerManager.lastCompletedDuration ?? 0,
                    continuedLockMessage: sessionCompleteFooterMessage,
                    lang: lang
                )
            }
            .overlay(alignment: .bottom) {
                hintToastOverlay
            }
            .overlay {
                if blockingService.isPreparingLock {
                    PreparingLockOverlay(lang: lang)
                }
            }
            .animation(.easeOut(duration: 0.2), value: blockingService.isPreparingLock)
            .onAppear {
                if let quote = viewModel.currentQuote {
                    blockingService.saveQuoteForShield(quote)
                }
                refreshScheduleAppCountText()
                // Extension が BG で shield を適用した直後は isShieldActive フラグが古いことがある
                // (15秒タイマーの隙間)。表示のたびに冪等リコンサイルで実状態に揃える
                // (2026-07-15 実機FB: 稼働中なのに管理ピルが待機中表示)
                scheduleManager.checkScheduleState()
            }
            .onChange(of: selectedModeRaw) { _, _ in
                refreshScheduleAppCountText()
            }
            .onReceive(scheduleManager.$configs) { _ in
                refreshScheduleAppCountText()
            }
            .task {
                await sessionTracker.loadStats()
            }
            .onChange(of: blockingService.isBlocking) { _, isBlocking in
                if isBlocking && !shieldFirstRunHintShown {
                    shieldFirstRunHintShown = true
                    showHintToast(L.homeShieldFirstRunHint(lang))
                }
            }
            .onChange(of: timerManager.didCompleteAt) { _, newValue in
                guard newValue != nil else { return }
                // 継続ロック中の判定は既存トーストと同じロジックを流用し、
                // 完了画面のフッター注記として引き渡す (トースト自体は廃止)
                if blockingService.isScheduleActive {
                    sessionCompleteFooterMessage = L.homeStillLockedSchedule(lang)
                } else if blockingService.isLocationActive {
                    sessionCompleteFooterMessage = L.homeStillLockedLocation(lang)
                } else {
                    sessionCompleteFooterMessage = nil
                }

                // L16: ロック管理シート (.sheet) 表示中に fullScreenCover を出そうとすると
                // presentation が衝突して完了画面が出ない/挙動不定になる。シートが出ていれば
                // 先に閉じ、dismiss が落ち着いてから (jumpToModeFromSheet と同じ 0.4s の間) 完了画面を出す
                if showLockManager {
                    showLockManager = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showSessionComplete = true
                    }
                } else {
                    showSessionComplete = true
                }
            }
        }
    }

    // MARK: - Mode Title (ヘッダの大タイトル = 選択中モードの説明)

    private var modeTitle: String {
        switch selectedMode {
        case .timer:
            return lang == .japanese ? "決めた時間だけロック" : "Lock for a set time" // 文言はユーザー添削待ち
        case .schedule:
            return lang == .japanese ? "時間帯で自動ロック" : "Lock on a schedule" // 文言はユーザー添削待ち
        case .location:
            return lang == .japanese ? "場所で自動ロック" : "Lock by location" // 文言はユーザー添削待ち
        }
    }

    // MARK: - Hint Toast (Shield 初回ヒント / 継続ロック通知、S11 の画像保存トーストと同じパターン)

    @ViewBuilder
    private var hintToastOverlay: some View {
        if let message = hintToastMessage {
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }

    private func showHintToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.25)) {
            hintToastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                hintToastMessage = nil
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.homeGreeting(lang))
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)

                // タイトル = 選択中モードの説明 (2026-07-15 実機FB: 固定挨拶タイトルをやめ、
                // セグメント下にあった小さいキャプションをここへ昇格)。
                // 読点なし+1行固定+自動縮小で変な位置の改行を防ぐ (同日FB)
                Text(modeTitle)
                    .font(AppTypography.largeTitle)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Spacer()

            // 連続日数 (2026-07-30 D案改2: プロフィールから移設し、ここ=ロックタブ右上が定位置。
            // 本人にしか見えない画面なので公開/非公開の概念なし。2026-07-15の炎バッジ廃止とは別物で、
            // これは実測ストリークの控えめな数字表示)
            if sessionTracker.streakDays > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.warning)
                    Text(lang == .japanese ? "\(sessionTracker.streakDays)日" : "\(sessionTracker.streakDays)d")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                }
                .padding(.trailing, 10)
                .padding(.top, 6)
                .accessibilityLabel(lang == .japanese ? "連続\(sessionTracker.streakDays)日" : "\(sessionTracker.streakDays)-day streak")
            }

            lockManagerButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lock Manager (右上ピル + ボトムシート)

    /// スケジュール/位置ロックが 1 つでも設定済みの時だけ出す管理ピル。
    /// モックv1 案A: ドット+件数。稼働中があれば緑ドット+稼働件数、なければグレードット+設定件数
    @ViewBuilder
    private var lockManagerButton: some View {
        let totalRows = scheduleManager.configs.count + (hasLocationConfig ? 1 : 0)
        if totalRows > 0 {
            let activeRows = activeLockRowCount
            Button {
                showLockManager = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(activeRows > 0 ? AppColors.success : AppColors.textTertiary)
                        .frame(width: 6, height: 6)
                    Text("\(activeRows > 0 ? activeRows : totalRows)")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(AppColors.textPrimary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Capsule().fill(AppColors.cardBackground))
            }
            .buttonStyle(.plain)
        }
    }

    /// ロック管理シートの行のうち、いま実際に稼働している数 (シート表示と同じ数え方)
    private var activeLockRowCount: Int {
        let activeSchedules = scheduleManager.configs.filter {
            $0.isEnabled && scheduleManager.isShieldActive && scheduleManager.isWithinSchedule(config: $0)
        }.count
        let locationActive = !locationManager.activeLocationIds.isEmpty ? 1 : 0
        return activeSchedules + locationActive
    }

    /// 稼働状況シート。行 UI とタップ挙動 (Pro ゲート込みの selectMode) は旧バナーをそのまま流用。
    /// シートを閉じてから遷移しないと paywall シートと presentation が衝突するため少し遅らせる
    private var lockManagerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang == .japanese ? "ロックの管理" : "Manage locks") // 文言はユーザー添削待ち
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .padding(.top, 28)

            ScrollView {
                statusBanners
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            // シートを開いた瞬間に実状態へ揃える (稼働中なのに待機中と出る鮮度問題の対策)
            scheduleManager.checkScheduleState()
        }
    }

    private func jumpToModeFromSheet(_ mode: BlockMode) {
        showLockManager = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            selectMode(mode)
        }
    }

    // MARK: - Status Banners (スケジュール/位置情報の稼働状況行。ロック管理シート内で表示)

    @ViewBuilder
    private var statusBanners: some View {
        VStack(spacing: 8) {
            ForEach(scheduleManager.configs) { config in
                let isRowActive = config.isEnabled
                    && scheduleManager.isShieldActive
                    && scheduleManager.isWithinSchedule(config: config)
                StatusBannerRow(
                    isActive: isRowActive,
                    title: !config.isEnabled
                        ? (lang == .japanese ? "スケジュール オフ" : "Schedule off") // 文言はユーザー添削待ち
                        : isRowActive
                            ? (lang == .japanese ? "スケジュール稼働中" : "Schedule active") // 文言はユーザー添削待ち
                            : (lang == .japanese ? "スケジュール待機中" : "Schedule waiting"), // 文言はユーザー添削待ち
                    summary: scheduleSummaryText(config)
                ) {
                    jumpToModeFromSheet(.schedule)
                }
            }

            if hasLocationConfig {
                StatusBannerRow(
                    isActive: !locationManager.activeLocationIds.isEmpty,
                    title: !locationManager.activeLocationIds.isEmpty
                        ? (lang == .japanese ? "位置情報ロック稼働中" : "Location lock active") // 文言はユーザー添削待ち
                        : (lang == .japanese ? "位置情報ロック待機中" : "Location lock waiting"), // 文言はユーザー添削待ち
                    summary: locationSummaryText
                ) {
                    jumpToModeFromSheet(.location)
                }
            }
        }
    }

    /// モード切替。2026-07-19 ゲート方針転換: モード自体は無課金でも開ける (設定を作らせて
    /// 価値を見せる)。課金ゲートは各モード画面の「実行 (ONにする)」の瞬間に移設
    /// (ScheduleBlockView / LocationBlockView 側の showProPaywall 参照)
    /// タイマーかスケジュールのどちらかが実際に遮断中か。
    /// 🔴 遮断中は解除方法を変えさせない。セッションには開始時の課題が焼き付いているので、
    ///    走行中に設定だけ変えるとカードの表示と実際の課題がズレる (2026-08-28 実機報告)
    ///
    /// 🔴 ここで isWithinAnySchedule() を呼ばないこと。
    ///    HomeView は常駐タブで 1Hz タイマーにより body が毎秒再評価されるため
    ///    (2026-08-09 のフリーズ調査で特定済みの既知の急所)、Calendar の日時計算を
    ///    スケジュール数ぶん毎秒回すことになる。
    ///    isShieldActive は 15秒ごとのリコンサイルが維持している @Published なので、
    ///    読むだけで計算が走らない
    private var isAnyLockRunning: Bool {
        timerManager.isRunning || scheduleManager.isShieldActive
    }

    private func selectMode(_ mode: BlockMode) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedModeRaw = mode.rawValue
        }
    }

    private static let weekdayShortNamesJa: [Int: String] = [1: "日", 2: "月", 3: "火", 4: "水", 5: "木", 6: "金", 7: "土"]
    private static let weekdayShortNamesEn: [Int: String] = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]

    /// スケジュールバナーの要約行 (例: "平日 22:00–07:00 · 12アプリ")
    private func scheduleSummaryText(_ config: ScheduleConfig) -> String {
        let weekdaySet = Set(config.weekdays)
        let weekdayText: String
        if weekdaySet == Set([2, 3, 4, 5, 6]) {
            weekdayText = lang == .japanese ? "平日" : "Weekdays"
        } else if weekdaySet == Set(1...7) {
            weekdayText = lang == .japanese ? "毎日" : "Every day"
        } else if weekdaySet == Set([1, 7]) {
            weekdayText = lang == .japanese ? "週末" : "Weekends"
        } else {
            // F4: カスタム曜日の略称も lang に応じて切り替える (以前は日本語固定)
            let names = lang == .japanese ? Self.weekdayShortNamesJa : Self.weekdayShortNamesEn
            let separator = lang == .japanese ? "・" : ", "
            weekdayText = config.weekdays.sorted()
                .compactMap { names[$0] }
                .joined(separator: separator)
        }

        let start = String(format: "%02d:%02d", config.startHour, config.startMinute)
        let end = String(format: "%02d:%02d", config.endHour, config.endMinute)

        return "\(weekdayText) \(start)–\(end) · \(cachedScheduleAppCountText)"
    }

    /// F3: UserDefaults 読み込み + PropertyListDecoder デコードを伴う重い処理。
    /// body から直接呼ばず、onAppear / selectedModeRaw 変化時 / currentConfig publish 時にのみ再計算しキャッシュする。
    private func refreshScheduleAppCountText() {
        guard let selection = scheduleManager.loadSelectionFromAppGroup() else {
            cachedScheduleAppCountText = lang == .japanese ? "0アプリ" : "0 apps"
            return
        }
        let appCount = selection.applicationTokens.count
        let categoryCount = selection.categoryTokens.count
        if categoryCount > 0 {
            cachedScheduleAppCountText = lang == .japanese
                ? "\(appCount)アプリ・\(categoryCount)カテゴリ"
                : "\(appCount) apps, \(categoryCount) categories"
        } else {
            cachedScheduleAppCountText = lang == .japanese ? "\(appCount)アプリ" : "\(appCount) apps"
        }
    }

    /// 位置情報が1件でも保存されていればバナーを表示 (有効/無効を問わず「設定済み」扱い)
    private var hasLocationConfig: Bool {
        !locationManager.registeredLocations.isEmpty
    }

    /// 位置情報バナーの要約行 (例: "「自宅」半径100m · 2箇所")
    private var locationSummaryText: String {
        guard let first = locationManager.registeredLocations.first else { return "" }
        let radius = Int(first.radius)
        let count = locationManager.registeredLocations.count
        return lang == .japanese
            ? "「\(first.name)」半径\(radius)m · \(count)箇所"
            : "\"\(first.name)\" \(radius)m radius · \(count) places"
    }

    // MARK: - Mode Segment

    private var modeSegment: some View {
        HStack(spacing: 8) {
            ForEach(BlockMode.allCases) { mode in
                modeButton(for: mode)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.cardBackground)
        )
    }

    private func modeButton(for mode: BlockMode) -> some View {
        let isSelected = selectedMode == mode
        let requiresPro = ProAccess.requiresPro(mode)
        let isLocked = requiresPro && !proAccess.isPro

        return Button {
            selectMode(mode)
        } label: {
            // アイコン+ラベルの2段構成でトグル自体の存在感を上げる (2026-07-19 ユーザーFB:
            // スケジュール/位置情報の入口が地味だと Pro 機能に気づかれない)
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: modeIconName(mode))
                        .font(.system(size: 17, weight: .semibold))

                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 9, y: -3)
                    }
                }
                .frame(height: 20)

                Text(L.blockModeDisplayName(mode, lang))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(isSelected ? AppColors.background : AppColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AppColors.textPrimary : Color.clear)
            )
        }
    }

    private func modeIconName(_ mode: BlockMode) -> String {
        switch mode {
        case .timer:    return "timer"
        case .schedule: return "calendar.badge.clock"
        case .location: return "location.fill"
        }
    }

    // MARK: - Timer Section (内蔵タイマー UI)

    @ViewBuilder
    private var timerSection: some View {
        if timerManager.isRunning {
            timerCountdownCard
        } else {
            timerSetupCard
            appSelectionCard
            startButton
        }
    }

    // MARK: - Timer Setup Card (時間を主役にしたヒーロー表示 + プリセットピル)

    private let presetMinutes: [Int] = [30, 60, 120]

    private var timerSetupCard: some View {
        VStack(spacing: 24) {
            // 大きな時間表示 (ヒーロー)
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Text("\(selectedMinutes)")
                        .font(.system(size: 72, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(AppColors.textPrimary)
                        .contentTransition(.numericText(value: Double(selectedMinutes)))
                        .animation(.easeInOut(duration: 0.2), value: selectedMinutes)

                    Text(L.homeBlockTimeMinutes(lang))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)
                }
                Spacer()
            }
            .padding(.top, 8)

            presetPillsRow

            if showCustomDurationPicker {
                customDurationPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
        )
    }

    private var presetPillsRow: some View {
        HStack(spacing: 8) {
            ForEach(presetMinutes, id: \.self) { preset in
                presetPill(
                    label: presetLabel(preset),
                    isSelected: !showCustomDurationPicker && selectedMinutes == preset
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMinutes = preset
                        showCustomDurationPicker = false
                    }
                }
            }

            presetPill(
                label: lang == .japanese ? "カスタム" : "Custom", // 文言はユーザー添削待ち
                isSelected: showCustomDurationPicker
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCustomDurationPicker = true
                }
            }
        }
    }

    /// プリセット時間のピル表示ラベル (例: 30分 / 1時間 / 2時間)
    private func presetLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return lang == .japanese ? "\(hours)時間" : "\(hours)h" // 文言はユーザー添削待ち
        }
        return lang == .japanese ? "\(minutes)分" : "\(minutes)m" // 文言はユーザー添削待ち
    }

    private func presetPill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? AppColors.background : AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? AppColors.textPrimary : Color.clear)
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.clear : AppColors.textTertiary.opacity(0.4), lineWidth: 1)
                        )
                )
        }
    }

    /// カスタム時間ピッカー (既存スライダー UI をそのまま流用、カスタム選択時のみ表示)
    private var customDurationPicker: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(selectedMinutes) },
                    set: { selectedMinutes = Int($0) }
                ),
                in: 5...180,
                step: 5
            )
            .tint(AppColors.textPrimary)

            HStack {
                Text(L.homeBlockTimeSliderMin(lang))
                    .font(AppTypography.caption2)
                    .foregroundColor(AppColors.textTertiary)
                Spacer()
                Text(L.homeBlockTimeSliderMax(lang))
                    .font(AppTypography.caption2)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }

    // MARK: - App Selection Card (共通部品 AppSelectCard に統一 — 3モードで同一UI)

    private var appSelectionCard: some View {
        AppSelectCard(selection: blockingService.selectedApps, lang: lang) {
            showingPicker = true
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        PrimaryButton(
            L.homeStartBlock(lang),
            icon: "play.fill",
            isDisabled: !canStart
        ) {
            startTimer()
        }
    }

    // MARK: - Timer Countdown Card

    private var timerCountdownCard: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "stopwatch.fill")
                    .foregroundColor(AppColors.textPrimary)
                Text(L.homeTimerBlock(lang))
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }

            Text(timerManager.formattedRemainingTimeLong())
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .monospacedDigit()

            // 進捗バー
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.secondaryBackground)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.textPrimary)
                        .frame(width: geo.size.width * countdownProgress, height: 6)
                        .animation(.linear(duration: 1), value: timerManager.remainingSeconds)
                }
            }
            .frame(height: 6)

            Text(L.homeRemainingTime(lang))
                .font(AppTypography.subheadline)
                .foregroundColor(AppColors.textSecondary)

            // 停止ボタン → 確認画面を表示
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showStopConfirmation = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                    Text(L.homeStopTimer(lang))
                        .font(AppTypography.buttonMedium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppColors.error)
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AppColors.modeTimer.opacity(0.5), lineWidth: 2)
                )
        )
    }

    // MARK: - Computed Properties

    private var hasSelection: Bool {
        !blockingService.selectedApps.applicationTokens.isEmpty ||
        !blockingService.selectedApps.categoryTokens.isEmpty
    }

    private var appCount: Int {
        blockingService.selectedApps.applicationTokens.count
    }

    private var categoryCount: Int {
        blockingService.selectedApps.categoryTokens.count
    }

    private var canStart: Bool {
        hasSelection && selectedMinutes > 0
    }

    private var countdownProgress: Double {
        guard let config = timerManager.currentConfig else { return 0 }
        let total = Double(config.durationMinutes * 60)
        guard total > 0 else { return 0 }
        return Double(timerManager.remainingSeconds) / total
    }

    // MARK: - Actions

    private func startTimer() {
        // settle 版: くるくるを最低 ~1.8s 出して、shield 適用直後の遷移レース由来のフリーズを緩和
        Task { await blockingService.startTimerBlockingWithSettle(durationMinutes: selectedMinutes) }
    }
}

// MARK: - Status Banner Row (スケジュール/位置情報 共通の常駐インジケータ行)

private struct StatusBannerRow: View {
    let isActive: Bool
    let title: String
    let summary: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(isActive ? AppColors.success : AppColors.textTertiary)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppColors.cardBackground)
            )
        }
    }
}

// MARK: - Stop Confirmation View（5秒クールダウン + フィード風全画面名言）

struct StopConfirmationView: View {
    @Binding var isPresented: Bool
    let lang: AppLanguage
    let onConfirm: () -> Void

    /// このセッションに課された解除課題。
    /// 🔴 現在の設定ではなく「セッション開始時に焼き付けた値」を渡すこと
    ///    (UnlockChallengeService.challenge(forSession:))。現在値を読むと、
    ///    ロック中に設定を緩めるだけで逃げられてしまう
    var challenge: UnlockChallenge = .longPress

    /// 中断すると完遂率が下がるか。スケジュールからも使えるよう外から渡す
    /// (以前は TimerManager を直接読んでいたためタイマー専用だった)
    var affectsCompletionRateOverride: Bool? = nil

    /// 夢は UserAuthService (in-app 既存ソース) から観測。App Group ミラーは別エージェントが並行実装中のため、
    /// このビューはあくまで in-app の @Published 値を読むだけに留める。
    @ObservedObject private var userAuth = UserAuthService.shared

    @State private var quote: Quote?
    // 実機FB第11弾 (2026-07-16): 「5秒待ってからタップ」を廃止し、長押しでのみ終了できる方式へ。
    // 長押しは待ち時間より能動的な摩擦 (自分の意思で押し続けないと終了できない)
    @State private var isHolding = false
    @State private var holdProgress: Double = 0
    /// 長押し2秒の自前計時 (実機FB第15弾: ジェスチャーの完了コールバックが再描画で発火しない対策)
    @State private var holdTask: Task<Void, Never>?
    @State private var showDeclaration = false
    /// 🔴 表示するページは開く瞬間に1回だけ確定させ、リクエストごと持つ。
    ///    fullScreenCover の中で毎回 shuffled() を呼ぶと、HomeView が1秒ごとに
    ///    body を再評価するたびに並びが作り直され、見たページの記録がリセットされる
    ///    (2026-08-29 実機で「勝手に変わる」「あと2件から進まない」として発現)
    @State private var scrollRequest: ScrollChallengeRequest?

    /// 終了に必要な長押し秒数
    private let holdSeconds: Double = 2.0

    @ObservedObject private var timerManager = TimerManager.shared

    /// このセッションを中断すると完遂率が下がるか。
    /// 033 の定義: 完遂率の母数は「予定 10 分以上のタイマーロック」のみ。
    /// 短いタイマーは母数に入らないので、警告を出すと嘘になる
    private var affectsCompletionRate: Bool {
        if let affectsCompletionRateOverride { return affectsCompletionRateOverride }
        return (timerManager.currentConfig?.durationMinutes ?? 0) >= 10
    }

    /// 宣言済みの夢 (空文字/未宣言は nil 扱い)。夢は実データであり、プレースホルダーは作らない
    private var dreamText: String? {
        guard let trimmed = userAuth.dream?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        ZStack {
            // 夢がある場合は純黒 (夢テキストを主役にするため名言背景は使わない)。
            // 夢が未宣言の場合のみ、従来通りフィードと同じ名言背景にフォールバックする
            Group {
                if dreamText == nil, let quote = quote {
                    QuoteBackgroundView(quoteId: quote.id)
                } else {
                    Color.black
                }
            }
            .overlay(Color.black.opacity(0.35))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 中央: 夢主役 (宣言済みの場合) / 名言フォールバック (未宣言の場合)
                VStack(spacing: 24) {
                    // 実機FB第12弾 (案1「終了は儀式」) + 第14弾修正: 長押し中にフェードアウトするのは
                    // **夢ブロックだけ** (確認文と下部ボタンは残す、ユーザー確定)。holdProgress 駆動で離せば戻る
                    VStack(spacing: 20) {
                        if let dreamText {
                            VStack(spacing: 10) {
                                Text(lang == .japanese ? "あなたの目標" : "Your goal") // 文言はユーザー添削待ち
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                    .tracking(1.5)

                                // 実機FB第13弾: 夢はこの画面の主役なので一回り大きく (25→30 bold)
                                Text(dreamText)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(7)
                                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                            }
                        } else if let quote = quote {
                            VStack(spacing: 14) {
                                Text("\u{201C}\(QuoteTypography.poeticText(quote.displayPrimary(lang: lang, showOriginal: false)))\u{201D}")
                                    .font(.system(size: 27, weight: .bold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(8)
                                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)

                                if let name = quote.displayAuthor {
                                    Text("— \(name)")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(.white.opacity(0.55))
                                        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                                }
                            }
                        }

                    }
                    .opacity(1 - holdProgress)

                    Text(lang == .japanese ? "本当にセッションを終了しますか?" : "End this session?") // 文言はユーザー添削待ち
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    // F1: 「終了すると連続◯日が途切れます」警告は削除。
                    // TimerManager.stopTimer() はセッションを status="aborted" + duration 付きで記録し、
                    // get_streak_days はその日に記録があれば継続扱いにするため、この警告は事実に反していた。

                    // 終了は夢の直下で長押し (フェードが指のすぐ上で見えるよう下部ボタン群から移動、実機FB第12弾)
                    endSessionControl

                    // 2026-07-31 実機FB: 完遂率は実際に下がるので告知する (「そんなの知らなかった」を防ぐ)。
                    // 撤去した連続日数の警告と違い、これは事実。位置は長押しリンクの「下」= 注意書きの扱いで、
                    // 色は付けない (金は主張が強すぎるとユーザー却下)。
                    // 033 の定義どおり「予定10分以上のタイマー」だけが完遂率の母数なので、
                    // 対象セッションの時だけ出す = 嘘の警告を出さない
                    if affectsCompletionRate {
                        Text(L.stopConfirmCompletionWarning(lang))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                // 下部: 2ボタン構成 (終了リンクは夢の直下へ移動、実機FB第12弾)。
                // 第14弾: 長押し中もフェードアウトしない (薄くなるのは夢ブロックだけ、ユーザー確定)
                VStack(spacing: 18) {
                    // 実機FB第11弾: 「続ける」はロック停止の文脈でおかしい →「作業に戻る」へ
                    PrimaryButton(lang == .japanese ? "作業に戻る" : "Back to work") { // 文言はユーザー添削待ち
                        dismiss()
                    }

                    // 終了の代替導線: おすすめフィードへ飛ばして他人の進捗を見せる (2026-07-16 ユーザー要望。
                    // セッションは終了しない = 続けるの亜種)
                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .switchToFeedTab, object: nil)
                    } label: {
                        // 2026-08-04 ユーザー確定:「他の人」→「ライバル」。中核ループの言葉に揃える
                        Text(lang == .japanese ? "ライバルの進捗を見る" : "See your rivals' progress")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            if dreamText == nil, quote == nil {
                quote = pickQuote()
            }
        }
        .fullScreenCover(item: $scrollRequest) { request in
            ScrollChallengeView(
                pages: request.pages,
                requiredCount: Self.scrollRequiredCount,
                lang: lang,
                onCompleted: {
                    scrollRequest = nil
                    onConfirm()
                    withAnimation { isPresented = false }
                },
                // 🔴 やっぱり作業を続ける = 解除をやめて中断画面ごと閉じる (ロックは継続)
                onKeepWorking: {
                    scrollRequest = nil
                    withAnimation { isPresented = false }
                }
            )
        }
        .fullScreenCover(isPresented: $showDeclaration) {
            DeclarationChallengeView(
                lang: lang,
                onCompleted: {
                    showDeclaration = false
                    onConfirm()
                    withAnimation { isPresented = false }
                },
                onCancel: { showDeclaration = false }
            )
        }
    }

    // MARK: - End Session Control (課題ごとの終了手段)

    /// 課された課題に応じて終了手段を出し分ける。
    /// 🔴 未実装の課題は長押しに倒す。ここで何も出さないと解除手段が消えて詰む。
    ///    (腕立て・スクワットは 2026-08-29 に廃止。UnlockChallenge の冒頭コメント参照)
    @ViewBuilder
    private var endSessionControl: some View {
        switch challenge {
        case .declaration:
            challengePill(lang == .japanese ? "次にやることを書いて終了" : "Write what's next to end") {
                showDeclaration = true
            }
        case .scrollFeed:
            challengePill(lang == .japanese ? "ライバルの進捗を見て終了" : "See your rivals to end") {
                Task { await prepareScrollChallenge(isImages: false) }
            }
        case .imageScroll:
            challengePill(lang == .japanese ? "自分の画像を見て終了" : "See your images to end") {
                Task { await prepareScrollChallenge(isImages: true) }
            }
        case .none:
            hardModeNotice
        default:
            endSessionLink
        }
    }

    /// スクロール課題で何件見せるか。⚠️ 実機で試してから調整する値
    private static let scrollRequiredCount = 5

    /// 表示中のスクロール課題。
    /// 🔴 ページを一緒に持たせて「提示」と「中身」を不可分にする。
    ///    別々の @State にすると、提示が先に走った一瞬だけ中身が空になり
    ///    「見せるものがありません」が瞬間的に出る (2026-08-29 実機報告)
    struct ScrollChallengeRequest: Identifiable {
        let id = UUID()
        let pages: [ScrollChallengeView.Page]
    }

    /// 🔴 開く前にページを確定させてから提示する。
    ///    画像は毎回ランダム順にする (1枚目が固定だとすぐ慣れる) が、
    ///    シャッフルは「開く瞬間に1回だけ」であって、描画のたびではない
    private func prepareScrollChallenge(isImages: Bool) async {
        let pages: [ScrollChallengeView.Page]
        if isImages {
            let store = UnlockImageStore.shared
            pages = store.imageIds.shuffled().compactMap { id in
                store.image(for: id).map { ScrollChallengeView.Page.image(id: id, image: $0) }
            }
        } else {
            if FeedService.shared.recommendedFeed.isEmpty {
                await FeedService.shared.loadRecommended(limit: 20)
            }
            // 🔴 2026-09-09 ユーザー指摘: 以前は prefix() で先頭から取っていたため、
            //    キャッシュ済みのフィードが使い回されて**毎回同じ投稿**が出ていた
            //    (画像モードだけ shuffled() されていて、投稿モードは抜けていた)。
            //    同じものを見せ続けると慣れて摩擦が消え、この課題の意味が無くなる。
            //
            //    ⚠️ ここで再取得はしない。recommendedFeed はフィードタブと同じ配列で、
            //    解除のたびに取り直すとタブのスクロール位置と中身が動く。
            //    手持ちのプールをシャッフルするだけで十分な変化が出る (20件から15件を選ぶ)。
            //
            //    🔴 シャッフルは「開く瞬間に1回だけ」。HomeView は1秒ごとに body を
            //    再評価するので、描画のたびに混ぜると見たページの記録が飛ぶ
            //    (2026-08-29 に踏んだ「あと2件から進まない」バグの原因)
            pages = FeedService.shared.recommendedFeed
                .shuffled()
                .prefix(Self.scrollRequiredCount * 3)
                .map { ScrollChallengeView.Page.post($0) }
        }
        // 🔴 空でもそのまま提示する。ScrollChallengeView 側の「見せるものがありません」に任せる。
        //    2026-09-09 に「空なら長押しへ倒す」を入れかけたが撤回した:
        //    機内モードにすればフィード取得が失敗して長押しに落ちるため、
        //    **誰でも意図的に難易度を下げられる抜け穴**になる。
        //    摩擦を課す機能にオフラインという迂回路を付けるのは本末転倒。
        //    画像0枚は選択シートが赤字で警告しており、そもそもユーザー側の設定ミス。
        //
        // 中身が確定してから初めて提示する
        scrollRequest = ScrollChallengeRequest(pages: pages)
    }

    /// 課題を開くピル。長押しのピルと見た目を合わせる
    private func challengePill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title) // ⚠️ 文言はユーザー添削待ち
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background {
                    Capsule().fill(Color.white.opacity(0.08))
                        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// ハードモード: 解除手段を出さない。
    /// 🔴 「何をしても解除できません」とは書かない。アプリを消せば解除されるので嘘になる。
    ///    アプリの中では真実である「このモードでは解除できません」に留め、
    ///    抑止力は「消したら記録が全部消える」で作る
    private var hardModeNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            // ⚠️ 文言はユーザー添削待ち
            Text(lang == .japanese ? "ハードロックモード" : "Hard lock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text(lang == .japanese
                 ? "何をしてもロックを解除できない\n時間が来れば自動で終わります"
                 : "Nothing can lift this lock.\nIt ends on its own when the time is up")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 6)
    }

    // MARK: - End Session Link (長押しでのみ終了、実機FB第11弾)

    // 実機FB第13弾: 素のテキストリンクは「どこを押すのか分からない」ため小さなピルに。
    // 長押し中はピル内部が左から満ちていき、満ちきったら終了
    private var endSessionLink: some View {
        Text(lang == .japanese ? "長押しで終了" : "Hold to end") // 文言はユーザー添削待ち
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(isHolding ? 0.95 : 0.6))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background {
                // 実機FB第14弾: 溜まりは部分幅の Capsule だと外形と曲率が合わず左端がはみ出して
                // 見えるため、Rectangle をピル外形で clip する方式に修正
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: geo.size.width * holdProgress)
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
            }
            .contentShape(Capsule())
        // 実機FB第15弾: minimumDuration 到達時の完了コールバックは、長押し中に再描画が走り続ける
        // 画面 (フェード進行で毎フレーム再描画) だと発火しないことがある → 「バーが満タンでも
        // 終了しない」バグの正体。ジェスチャーには押下検知だけをさせ (minimumDuration: .infinity)、
        // 2秒の計時は自前の Task で行う方式に置換。指の微動での取消も maximumDistance 拡大で緩和
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 90) {
            // .infinity のため perform は発火しない (完了判定は holdTask 側)
        } onPressingChanged: { pressing in
            isHolding = pressing
            if pressing {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.linear(duration: holdSeconds)) { holdProgress = 1 }
                holdTask?.cancel()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
                    guard !Task.isCancelled, isHolding else { return }
                    // 溜め切り成功 → 終了確定 (成功ハプティクス)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onConfirm()
                    withAnimation { isPresented = false }
                }
            } else {
                // 途中で離した → 計時を破棄してリセット (終了成立時も通るが直後に dismiss されるので無害)
                holdTask?.cancel()
                holdTask = nil
                withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isPresented = false
        }
    }

    // いいね一覧から優先選定。空なら全体ランダムにフォールバック。
    private func pickQuote() -> Quote? {
        if let liked = LikeService.shared.likedQuotes.randomElement() {
            return liked
        }
        return QuoteService.shared.quotes.randomElement()
    }

}

// MARK: - Preview

#Preview {
    HomeView()
}
