//
//  HomeView.swift
//  AppBlocker
//
//  Main screen (mode switch + settings for each mode)
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
    /// Paywall shown when the user taps a Pro challenge in the unlock methods.
    /// (The gate for the modes themselves is held by each mode screen. See the comment on selectMode.)
    @State private var showChallengePaywall = false
    @ObservedObject private var challengeService = UnlockChallengeService.shared
    @State private var showingPicker = false
    @State private var showStopConfirmation = false
    @State private var hintToastMessage: String?
    @State private var showSessionComplete = false
    @State private var sessionCompleteFooterMessage: String?
    /// Status sheet for schedule/location locks (replaces the always-visible banners. Real device
    /// feedback 2026-07-15: the more banners there were, the further down the mode switch was pushed,
    /// so it moved to a top-right button + bottom sheet)
    @State private var showLockManager = false
    /// F3: scheduleAppCountText() reads UserDefaults and decodes with PropertyListDecoder, so it is
    /// cached to prevent it from being re-evaluated every second inside body (via the remainingSeconds
    /// publish while the timer runs)
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

                        // Unlock method. 🔴 This position is shared by all 3 modes, so placing it in one spot makes it
                        //    appear in timer/schedule/location.
                        //    ⚠️ Decide the final position after checking on a real device (on hold 2026-08-28)
                        // 🔴 Do not show it while only one challenge is implemented.
                        //    A picker with a single option only confuses the user.
                        //    It comes back automatically once the next challenge (notebook + pen / scroll / post) is added
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

                // Stop confirmation overlay
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
                        // It must be shown after the sheet is closed, otherwise they overlap and it does not appear
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showChallengePaywall = true
                        }
                    }
                )
                // 2026-09-05 real device feedback: with .medium (about 50%) the hard lock mode was cut off.
                // Open at a height where all 5 are visible at once, and allow pulling up to .large if needed
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
                // Right after the Extension applies the shield in the background, the isShieldActive flag can be
                // stale (the gap in the 15-second timer). Every time it is shown, an idempotent reconcile syncs it
                // to the real state (2026-07-15 real device feedback: the manager pill showed waiting while active)
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
                // The check for an ongoing lock reuses the same logic as the existing toast,
                // and is passed to the completion screen as a footer note (the toast itself was removed)
                if blockingService.isScheduleActive {
                    sessionCompleteFooterMessage = L.homeStillLockedSchedule(lang)
                } else if blockingService.isLocationActive {
                    sessionCompleteFooterMessage = L.homeStillLockedLocation(lang)
                } else {
                    sessionCompleteFooterMessage = nil
                }

                // L16: Presenting a fullScreenCover while the lock manager sheet (.sheet) is shown makes the
                // presentations collide, so the completion screen does not appear or behaves unpredictably. If the
                // sheet is shown, close it first, then show the completion screen after the dismiss settles (the
                // same 0.4s delay as jumpToModeFromSheet)
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

    // MARK: - Mode Title (large header title = description of the selected mode)

    private var modeTitle: String {
        switch selectedMode {
        case .timer:
            return lang == .japanese ? "決めた時間だけロック" : "Lock for a set time" // Wording awaiting user review
        case .schedule:
            return lang == .japanese ? "時間帯で自動ロック" : "Lock on a schedule" // Wording awaiting user review
        case .location:
            return lang == .japanese ? "場所で自動ロック" : "Lock by location" // Wording awaiting user review
        }
    }

    // MARK: - Hint Toast (first-time Shield hint / ongoing lock notice, same pattern as the S11 image-save toast)

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

                // Title = description of the selected mode (2026-07-15 real device feedback: dropped the fixed
                // greeting title and promoted the small caption that was under the segment control to here).
                // No commas + fixed to 1 line + auto shrink, to prevent line breaks at odd positions (feedback the
                // same day)
                Text(modeTitle)
                    .font(AppTypography.largeTitle)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Spacer()

            // Consecutive days (2026-07-30 plan D rev 2: moved from the profile, its fixed place is here = top
            // right of the lock tab. This screen is only visible to the user, so there is no public/private
            // concept. This is separate from the flame badge removed on 2026-07-15; it is a modest number
            // display of the measured streak)
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

    // MARK: - Lock Manager (top-right pill + bottom sheet)

    /// Manager pill shown only when at least 1 schedule/location lock is configured.
    /// Mockup v1 plan A: dot + count. If any are active, green dot + active count; otherwise gray dot +
    /// configured count
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

    /// Number of lock manager sheet rows that are actually active right now (counted the same way as the
    /// sheet)
    private var activeLockRowCount: Int {
        let activeSchedules = scheduleManager.configs.filter {
            $0.isEnabled && scheduleManager.isShieldActive && scheduleManager.isWithinSchedule(config: $0)
        }.count
        let locationActive = !locationManager.activeLocationIds.isEmpty ? 1 : 0
        return activeSchedules + locationActive
    }

    /// Status sheet. The row UI and tap behavior (selectMode, including the Pro gate) are reused as-is
    /// from the old banners. Navigating before the sheet closes makes its presentation collide with the
    /// paywall sheet, so it is delayed slightly
    private var lockManagerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang == .japanese ? "ロックの管理" : "Manage locks") // Wording awaiting user review
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
            // Sync to the real state the moment the sheet opens (fix for the freshness issue where it shows
            // waiting while active)
            scheduleManager.checkScheduleState()
        }
    }

    private func jumpToModeFromSheet(_ mode: BlockMode) {
        showLockManager = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            selectMode(mode)
        }
    }

    // MARK: - Status Banners (status rows for schedule/location. Shown inside the lock manager sheet)

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
                        ? (lang == .japanese ? "スケジュール オフ" : "Schedule off") // Wording awaiting user review
                        : isRowActive
                            ? (lang == .japanese ? "スケジュール稼働中" : "Schedule active") // Wording awaiting user review
                            : (lang == .japanese ? "スケジュール待機中" : "Schedule waiting"), // Wording awaiting user review
                    summary: scheduleSummaryText(config)
                ) {
                    jumpToModeFromSheet(.schedule)
                }
            }

            if hasLocationConfig {
                StatusBannerRow(
                    isActive: !locationManager.activeLocationIds.isEmpty,
                    title: !locationManager.activeLocationIds.isEmpty
                        ? (lang == .japanese ? "位置情報ロック稼働中" : "Location lock active") // Wording awaiting user review
                        : (lang == .japanese ? "位置情報ロック待機中" : "Location lock waiting"), // Wording awaiting user review
                    summary: locationSummaryText
                ) {
                    jumpToModeFromSheet(.location)
                }
            }
        }
    }

    /// Mode switch. 2026-07-19 gate policy change: the modes themselves can be opened without paying (let
    /// users build a setup and see the value). The purchase gate moved to the moment of "run (turn ON)"
    /// on each mode screen (see showProPaywall in ScheduleBlockView / LocationBlockView)
    /// Whether the timer or the schedule is actually blocking right now.
    /// 🔴 Do not allow changing the unlock method while blocking. The session has the challenge from its
    ///    start baked in, so changing only the setting mid-run makes the card display and the real
    ///    challenge disagree (2026-08-28 real device report)
    ///
    /// 🔴 Do not call isWithinAnySchedule() here.
    ///    HomeView is an always-resident tab and its body is re-evaluated every second by a 1Hz timer
    ///    (a known weak spot identified in the 2026-08-09 freeze investigation), so this would run
    ///    Calendar date calculations once per schedule every second.
    ///    isShieldActive is an @Published value kept up to date by the reconcile every 15 seconds,
    ///    so reading it does not trigger any calculation
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

    /// Summary line for the schedule banner (e.g. "平日 22:00-07:00 · 12アプリ" ("Weekdays 22:00-07:00 · 12 apps"))
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
            // F4: Custom weekday abbreviations also switch by lang (previously fixed to Japanese)
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

    /// F3: Heavy work that reads UserDefaults and decodes with PropertyListDecoder.
    /// Not called directly from body. Recalculated and cached only on onAppear / when selectedModeRaw
    /// changes / when currentConfig publishes.
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

    /// Show the banner if at least 1 location is saved (treated as "configured" whether enabled or
    /// disabled)
    private var hasLocationConfig: Bool {
        !locationManager.registeredLocations.isEmpty
    }

    /// Summary line for the location banner (e.g. "「自宅」半径100m · 2箇所" ("Home" radius 100m · 2 places))
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
            // Two-tier icon + label layout to make the toggle itself stand out more (2026-07-19 user feedback:
            // if the entry points for schedule/location are plain, people do not notice the Pro features)
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

    // MARK: - Timer Section (built-in timer UI)

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

    // MARK: - Timer Setup Card (hero display with the time as the main element + preset pills)

    private let presetMinutes: [Int] = [30, 60, 120]

    private var timerSetupCard: some View {
        VStack(spacing: 24) {
            // Large time display (hero)
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
                label: lang == .japanese ? "カスタム" : "Custom", // Wording awaiting user review
                isSelected: showCustomDurationPicker
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCustomDurationPicker = true
                }
            }
        }
    }

    /// Display label for the preset time pills (e.g. "30分" / "1時間" / "2時間" ("30 min" / "1 hour" / "2 hours"))
    private func presetLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return lang == .japanese ? "\(hours)時間" : "\(hours)h" // Wording awaiting user review
        }
        return lang == .japanese ? "\(minutes)分" : "\(minutes)m" // Wording awaiting user review
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

    /// Custom duration picker (reuses the existing slider UI as-is, shown only when custom is selected)
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

    // MARK: - App Selection Card (unified into the shared component AppSelectCard, same UI in all 3 modes)

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

            // Progress bar
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

            // Stop button → show the confirmation screen
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
        // settle version: show the spinner for at least ~1.8s to reduce the freeze caused by the transition
        // race right after the shield is applied
        Task { await blockingService.startTimerBlockingWithSettle(durationMinutes: selectedMinutes) }
    }
}

// MARK: - Status Banner Row (always-visible indicator row shared by schedule/location)

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

// MARK: - Stop Confirmation View (5-second cooldown + feed-style full-screen quote)

struct StopConfirmationView: View {
    @Binding var isPresented: Bool
    let lang: AppLanguage
    let onConfirm: () -> Void

    /// The unlock challenge assigned to this session.
    /// 🔴 Pass the "value baked in at session start", not the current setting
    ///    (UnlockChallengeService.challenge(forSession:)). If it reads the current value,
    ///    the user can escape just by loosening the setting during the lock
    var challenge: UnlockChallenge = .longPress

    /// Whether aborting lowers the completion rate. Passed in from outside so the schedule can use it too
    /// (it used to read TimerManager directly, so it was timer-only)
    var affectsCompletionRateOverride: Bool? = nil

    /// The dream is observed from UserAuthService (existing in-app source). The App Group mirror is being
    /// implemented in parallel by another agent, so this view only reads the in-app @Published value.
    @ObservedObject private var userAuth = UserAuthService.shared

    @State private var quote: Quote?
    // Real device feedback round 11 (2026-07-16): removed "wait 5 seconds, then tap" and switched to
    // ending by long press only. A long press is more active friction than waiting (you cannot end it
    // unless you keep pressing by your own choice)
    @State private var isHolding = false
    @State private var holdProgress: Double = 0
    /// Our own timing of the 2-second long press (real device feedback round 15: fix for the gesture's
    /// completion callback not firing because of redraws)
    @State private var holdTask: Task<Void, Never>?
    @State private var showDeclaration = false
    /// 🔴 Decide the pages to show only once, at the moment it opens, and keep them in the request.
    ///    If shuffled() is called inside the fullScreenCover every time, the order is rebuilt each time
    ///    HomeView re-evaluates body every second, and the record of viewed pages resets
    ///    (showed up on a real device on 2026-08-29 as "it changes by itself" and "stuck at 2 left")
    @State private var scrollRequest: ScrollChallengeRequest?

    /// Number of seconds of long press needed to end
    private let holdSeconds: Double = 2.0

    @ObservedObject private var timerManager = TimerManager.shared

    /// Whether aborting this session lowers the completion rate.
    /// Definition in 033: the completion rate denominator is only "timer locks planned for 10 minutes or
    /// more". Short timers are not in the denominator, so showing the warning would be a lie
    private var affectsCompletionRate: Bool {
        if let affectsCompletionRateOverride { return affectsCompletionRateOverride }
        return (timerManager.currentConfig?.durationMinutes ?? 0) >= 10
    }

    /// The declared dream (empty string / not declared is treated as nil). The dream is real data; no
    /// placeholder is made
    private var dreamText: String? {
        guard let trimmed = userAuth.dream?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        ZStack {
            // If there is a dream, pure black (the quote background is not used, so the dream text is the main
            // element). Only if no dream is declared, fall back to the same quote background as the feed, as
            // before
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

                // Center: dream as the main element (if declared) / quote fallback (if not declared)
                VStack(spacing: 24) {
                    // Real device feedback round 12 (idea 1 "ending is a ritual") + round 14 fix: during the long press
                    // **only the dream block** fades out (the confirmation text and the bottom buttons stay, confirmed
                    // by the user). Driven by holdProgress, so it comes back when released
                    VStack(spacing: 20) {
                        if let dreamText {
                            VStack(spacing: 10) {
                                Text(lang == .japanese ? "あなたの目標" : "Your goal") // Wording awaiting user review
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                    .tracking(1.5)

                                // Real device feedback round 13: the dream is the main element of this screen, so make it one size
                                // larger (25→30 bold)
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

                    Text(lang == .japanese ? "本当にセッションを終了しますか?" : "End this session?") // Wording awaiting user review
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    // F1: Removed the "ending will break your N-day streak" warning.
                    // TimerManager.stopTimer() records the session as status="aborted" with duration, and
                    // get_streak_days treats the day as continued if there is a record that day, so this warning was
                    // factually wrong.

                    // Ending is a long press right under the dream (moved from the bottom button group so the fade is
                    // visible just above the finger, real device feedback round 12)
                    endSessionControl

                    // 2026-07-31 real device feedback: the completion rate really does drop, so tell the user (prevents
                    // "I didn't know that"). Unlike the removed streak warning, this is a fact. It sits "below" the long
                    // press link = treated as a note, with no color (the user rejected gold as too loud).
                    // Per the definition in 033, only "timers planned for 10 minutes or more" are in the completion rate
                    // denominator, so show it only for those sessions = never show a false warning
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

                // Bottom: 2-button layout (the end link moved right under the dream, real device feedback round 12).
                // Round 14: these do not fade out during the long press either (only the dream block fades,
                // confirmed by the user)
                VStack(spacing: 18) {
                    // Real device feedback round 11: "続ける" ("Continue") is odd in the context of stopping a lock →
                    // "作業に戻る" ("Back to work")
                    PrimaryButton(lang == .japanese ? "作業に戻る" : "Back to work") { // Wording awaiting user review
                        dismiss()
                    }

                    // Alternative path instead of ending: jump to the recommended feed and show other people's progress
                    // (2026-07-16 user request. The session does not end = a variant of continue)
                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .switchToFeedTab, object: nil)
                    } label: {
                        // 2026-08-04 confirmed by the user: "他の人" ("other people") → "ライバル" ("rivals"). Matches the
                        // wording of the core loop
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
                // 🔴 Keep working after all = cancel the unlock and close the interruption screen too (the lock
                // continues)
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

    // MARK: - End Session Control (end method per challenge)

    /// Show a different end method depending on the assigned challenge.
    /// 🔴 Unimplemented challenges fall back to long press. If nothing is shown here, the unlock method
    /// disappears and the user is stuck.
    ///    (Push-ups and squats were removed on 2026-08-29. See the comment at the top of UnlockChallenge)
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

    /// How many items to show in the scroll challenge. ⚠️ Value to tune after testing on a real device
    private static let scrollRequiredCount = 5

    /// The scroll challenge being shown.
    /// 🔴 Hold the pages in it so that "presenting" and "content" cannot be separated.
    ///    If they are separate @State values, the content is empty for a moment when the presentation
    ///    runs first, and "見せるものがありません" ("Nothing to show") flashes briefly
    ///    (2026-08-29 real device report)
    struct ScrollChallengeRequest: Identifiable {
        let id = UUID()
        let pages: [ScrollChallengeView.Page]
    }

    /// 🔴 Fix the pages before opening, then present.
    ///    Images are in random order every time (a fixed first image gets familiar quickly), but
    ///    the shuffle happens "only once at the moment it opens", not on every render
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
            // 🔴 2026-09-09 user report: it used to take from the top with prefix(), so
            //    the cached feed was reused and **the same posts** appeared every time
            //    (only image mode was shuffled(); post mode was missed).
            //    Showing the same things repeatedly makes users used to it, the friction disappears, and this
            //    challenge loses its purpose.
            //
            //    ⚠️ Do not refetch here. recommendedFeed is the same array as the feed tab, and
            //    refetching on every unlock moves the tab's scroll position and content.
            //    Shuffling the pool on hand gives enough variety (picks 15 out of 20).
            //
            //    🔴 Shuffle "only once at the moment it opens". HomeView re-evaluates body every second,
            //    so shuffling on every render loses the record of viewed pages
            //    (the cause of the "stuck at 2 left" bug hit on 2026-08-29)
            pages = FeedService.shared.recommendedFeed
                .shuffled()
                .prefix(Self.scrollRequiredCount * 3)
                .map { ScrollChallengeView.Page.post($0) }
        }
        // 🔴 Present it as-is even if empty. Leave it to "見せるものがありません" ("Nothing to show") in
        // ScrollChallengeView.
        //    On 2026-09-09 "fall back to long press if empty" was nearly added but was reverted:
        //    turning on airplane mode makes the feed fetch fail and drop to long press, so
        //    it would be **a loophole that lets anyone lower the difficulty on purpose**.
        //    Giving a friction feature an offline bypass defeats its purpose.
        //    0 images is warned about in red text in the selection sheet, and is the user's own setup
        //    mistake in the first place.
        //
        // Present only after the content is fixed
        scrollRequest = ScrollChallengeRequest(pages: pages)
    }

    /// Pill that opens a challenge. Matches the look of the long press pill
    private func challengePill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title) // ⚠️ Wording awaiting user review
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

    /// Hard mode: show no unlock method.
    /// 🔴 Do not write "nothing you do can unlock it". Deleting the app does unlock it, so that is a lie.
    ///    Stay with "this mode cannot be unlocked", which is true inside the app, and
    ///    build the deterrent with "deleting it erases all your records"
    private var hardModeNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            // ⚠️ Wording awaiting user review
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

    // MARK: - End Session Link (end only by long press, real device feedback round 11)

    // Real device feedback round 13: a plain text link left users unsure "where to press", so it became
    // a small pill. During the long press the inside of the pill fills from the left, and when it is
    // full the session ends
    private var endSessionLink: some View {
        Text(lang == .japanese ? "長押しで終了" : "Hold to end") // Wording awaiting user review
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(isHolding ? 0.95 : 0.6))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background {
                // Real device feedback round 14: with a partial-width Capsule for the fill, its curvature did not
                // match the outline and the left edge looked like it stuck out, so it was changed to clip a
                // Rectangle to the pill shape
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
        // Real device feedback round 15: the completion callback on reaching minimumDuration sometimes does
        // not fire on a screen that keeps redrawing during the long press (redrawn every frame as the fade
        // progresses) → the real cause of the "bar is full but it does not end" bug. The gesture now only
        // detects the press (minimumDuration: .infinity), and the 2-second timing is done by our own Task.
        // Cancelling on small finger movements is also eased by a larger maximumDistance
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 90) {
            // Because of .infinity, perform never fires (completion is decided on the holdTask side)
        } onPressingChanged: { pressing in
            isHolding = pressing
            if pressing {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.linear(duration: holdSeconds)) { holdProgress = 1 }
                holdTask?.cancel()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
                    guard !Task.isCancelled, isHolding else { return }
                    // Fully held → end confirmed (success haptics)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onConfirm()
                    withAnimation { isPresented = false }
                }
            } else {
                // Released midway → discard the timing and reset (also runs when the end succeeds, but harmless
                // since it is dismissed right after)
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

    // Pick from the liked list first. If empty, fall back to a random pick from all.
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
