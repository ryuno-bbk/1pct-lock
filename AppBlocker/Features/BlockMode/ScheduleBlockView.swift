//
//  ScheduleBlockView.swift
//  AppBlocker
//
//  Schedule block settings screen (a Content View embedded inside HomeView)
//  Multiple schedules supported (2026-07-15): limit ScheduleManager.maxSchedules, the app selection is
//  a card shared by all modes.
//  The first one shows the form fully and closes with the "スケジュールを開始" ("Start schedule") CTA
//  (same grammar as the timer).
//  From the second one on, a list + the "スケジュールを追加" ("Add schedule") CTA (2026-07-15 real
//  device feedback).
//

import SwiftUI
import FamilyControls

/// F5: edit target of the wheel picker sheet opened by tapping timeColumn
private enum TimeEditTarget: Identifiable, Hashable {
    case start
    case end
    var id: Self { self }
}

/// Target of the editor sheet (only for editing existing schedules. New ones: the first = inline /
/// from the second on = a sheet with an empty form)
private struct ScheduleEditorState: Identifiable {
    let id = UUID()
    let config: ScheduleConfig?
}

struct ScheduleBlockView: View {
    @ObservedObject var blockingService: BlockingService
    @ObservedObject var scheduleManager = ScheduleManager.shared
    // 2026-07-19 gate policy change: the mode itself can be opened for free and settings can be created
    // (sunk cost). Payment is required only at the moment of "running" (turning ON/starting)
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var showingPicker = false
    @State private var showProPaywall = false
    /// Explanation alert right after saving without paying (conveys in one beat: it is saved, and running
    /// it requires paying)
    @State private var showLockedSavedAlert = false
    @State private var editorState: ScheduleEditorState?
    @State private var scheduleToDelete: ScheduleConfig?
    @State private var showDeleteConfirmation = false
    /// Target of the stop screen shown when tapping a schedule whose blocking is running
    @State private var stopTarget: ScheduleConfig?

    // Reusing the timer's selectedApps caused cross contamination: just opening the schedule tab rewrote
    // the timer selection (2026-07-16 Fable review). Isolated with a local @State, same as LocationBlockView
    @State private var appSelection = FamilyActivitySelection()

    // Edit values for the first one (inline form). Default: 22:00 - 07:00, weekdays
    @State private var inlineStartTime: Date
    @State private var inlineEndTime: Date
    @State private var inlineWeekdays: Set<Int>

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    init(blockingService: BlockingService) {
        self.blockingService = blockingService

        let calendar = Calendar.current
        _inlineStartTime = State(initialValue: calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date())
        _inlineEndTime = State(initialValue: calendar.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())
        _inlineWeekdays = State(initialValue: [2, 3, 4, 5, 6])
    }

    var body: some View {
        VStack(spacing: 24) {
            if scheduleManager.configs.isEmpty {
                // First one: show the form fully and start with the CTA (same structure as the timer, where "what to
                // press" is clear)
                inlineFirstScheduleSection
            } else {
                // From the second one on: list + add CTA
                scheduleListSection
            }

            // App selection (shared by all schedules) at the very bottom = same position as the other modes
            AppSelectCard(
                selection: appSelection,
                lang: lang,
                subtitle: lang == .japanese ? "全スケジュール共通" : "Shared across schedules" // Wording is waiting for the user's review
            ) {
                showingPicker = true
            }
        }
        .familyActivityPicker(
            isPresented: $showingPicker,
            selection: $appSelection
        )
        .sheet(isPresented: $showProPaywall) {
            ProPaywallView(triggeredBy: .schedule)
        }
        // Feedback #11 (2026-07-21): the explanation after saving was upgraded from an alert to a custom
        // sheet. Wording is waiting for the user's review
        .sheet(isPresented: $showLockedSavedAlert) {
            LockedSavedNoticeSheet(
                title: lang == .japanese
                    ? "ロックの実行には 1% エリートが必要です"
                    : "Running locks requires 1% Elite",
                message: lang == .japanese
                    ? "作成したスケジュールは保存されています。有効にするには 1% エリートに参加してください。"
                    : "Your schedule is saved. Join 1% Elite to turn it on.",
                onSeeElite: {
                    // Avoid presentation conflicts between sheets (same reason as LocationBlockView.presentPaywallAfterSheet)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        showProPaywall = true
                    }
                },
                closeTitle: lang == .japanese ? "閉じる" : "Close",
                ctaTitle: L.blockLockedSeeElite(lang)
            )
        }
        .onChange(of: appSelection) { _, newValue in
            // The app selection is shared by all schedules: save changes immediately and also apply them to the
            // running shield (the configs.isEmpty guard was removed: saving itself is harmless, and a selection
            // made before adding the first one should also be persisted)
            scheduleManager.updateSharedSelection(newValue)
        }
        .onAppear {
            // Load the saved app selection (regardless of whether configs exist. The scheduleSelection key is
            // also written by saveInitialSharedSelection, the shared initial value at the end of onboarding)
            if let savedSelection = scheduleManager.loadSelectionFromAppGroup() {
                appSelection = savedSelection
            }
        }
        // Stop screen shown when tapping a schedule whose blocking is running.
        // 🔴 Uses the same StopConfirmationView as the timer. Fixing the difficulty mode in one place
        //    applies to both the timer and schedules (the reason no new screen is added)
        .fullScreenCover(item: $stopTarget) { config in
            StopConfirmationView(
                isPresented: Binding(
                    get: { stopTarget != nil },
                    set: { if !$0 { stopTarget = nil } }
                ),
                lang: lang,
                onConfirm: {
                    // Do not delete the schedule, only end the running occurrence
                    scheduleManager.skipCurrentOccurrence(id: config.id)
                    stopTarget = nil
                },
                challenge: UnlockChallengeService.shared.activeChallenge ?? .longPress,
                // The denominator of the completion rate is only "timer locks planned for 10 minutes or more" (033),
                // so stopping a schedule does not lower it
                affectsCompletionRateOverride: false
            )
        }
        .sheet(item: $editorState) { state in
            ScheduleEditorView(
                existing: state.config,
                canSave: hasSelection,
                onSave: { config in
                    // Not paying: let them save, but always save as OFF and show the paywall right there
                    // (the created settings remain = sunk cost. Turning it ON requires paying)
                    var config = config
                    if !proAccess.canAccess(.schedule) && config.isEnabled {
                        config.isEnabled = false
                        presentLockedSavedNotice()
                    }
                    if state.config == nil {
                        // A-7: settle version. Adding inside the time window has a race where the shield is applied
                        // immediately, so insert an interval where PreparingLockOverlay blocks input
                        Task { await blockingService.startScheduleBlockingWithSettle(config: config, apps: appSelection) }
                    } else {
                        blockingService.updateScheduleBlocking(config: config, apps: appSelection)
                    }
                },
                onDelete: state.config.map { config in
                    { blockingService.removeScheduleBlocking(id: config.id) }
                }
            )
        }
        .alert(lang == .japanese ? "スケジュールを削除" : "Delete schedule", isPresented: $showDeleteConfirmation) { // Wording is waiting for the user's review
            Button(lang == .japanese ? "キャンセル" : "Cancel", role: .cancel) { }
            Button(lang == .japanese ? "削除" : "Delete", role: .destructive) {
                if let config = scheduleToDelete {
                    blockingService.removeScheduleBlocking(id: config.id)
                }
            }
        } message: {
            if let config = scheduleToDelete {
                Text(lang == .japanese
                     ? "\(ScheduleRowCard.timeRangeText(config)) (\(ScheduleRowCard.weekdaySummary(config.weekdays, lang: lang))) を削除しますか?"
                     : "Delete \(ScheduleRowCard.timeRangeText(config)) (\(ScheduleRowCard.weekdaySummary(config.weekdays, lang: lang)))?") // Wording is waiting for the user's review
            }
        }
    }

    // MARK: - Section Label (11pt uppercase tracking)

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(AppColors.textTertiary)
    }

    // MARK: - First one: inline form + start CTA

    private var inlineFirstScheduleSection: some View {
        VStack(spacing: 24) {
            ScheduleFormSections(
                startTime: $inlineStartTime,
                endTime: $inlineEndTime,
                selectedWeekdays: $inlineWeekdays
            )

            VStack(spacing: 8) {
                PrimaryButton(
                    lang == .japanese ? "スケジュールを開始" : "Start schedule", // Wording is waiting for the user's review
                    icon: "calendar.badge.checkmark",
                    isDisabled: !canStartInline
                ) {
                    startInlineSchedule()
                }

                if !hasSelection {
                    Text(lang == .japanese
                         ? "下の「ブロックするアプリ」を選択すると開始できます"
                         : "Pick your apps under \"Apps to block\" to get started") // Wording is waiting for the user's review
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else if !isInlineDurationValid {
                    // L14: for extremely short schedules such as start=end, show the reason before starting
                    // (saving itself is also rejected in ScheduleManager.addSchedule, but disabling the CTA prevents it
                    // earlier)
                    Text(L.scheduleTooShort(ScheduleManager.minScheduleDurationMinutes, lang))
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var canStartInline: Bool {
        hasSelection && !inlineWeekdays.isEmpty && isInlineDurationValid
    }

    /// L14: whether the times in the current inline form are at least the minimum length
    /// (ScheduleManager.minScheduleDurationMinutes)
    private var isInlineDurationValid: Bool {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: inlineStartTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: inlineEndTime)
        let duration = ScheduleManager.durationMinutes(for: ScheduleConfig(
            startHour: startComponents.hour ?? 0,
            startMinute: startComponents.minute ?? 0,
            endHour: endComponents.hour ?? 0,
            endMinute: endComponents.minute ?? 0
        ))
        return duration >= ScheduleManager.minScheduleDurationMinutes
    }

    private func startInlineSchedule() {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: inlineStartTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: inlineEndTime)

        var config = ScheduleConfig(
            startHour: startComponents.hour ?? 22,
            startMinute: startComponents.minute ?? 0,
            endHour: endComponents.hour ?? 7,
            endMinute: endComponents.minute ?? 0,
            weekdays: Array(inlineWeekdays)
        )
        // Not paying: save the settings themselves as OFF (sunk cost), then the explanation sheet → a path to
        // view Elite
        if !proAccess.canAccess(.schedule) {
            config.isEnabled = false
            presentLockedSavedNotice()
        }
        // A-7: settle version (starting inside the time window applies the shield immediately)
        Task { await blockingService.startScheduleBlockingWithSettle(config: config, apps: appSelection) }
    }

    /// Feedback #11: show the explanation sheet after saving without paying. On both the editor and inline
    /// paths, show it after the previous sheet (editor sheet etc.) has fully closed (avoids presentation
    /// conflicts. Same reason and same 0.55 seconds as LocationBlockView's presentPaywallAfterSheet)
    private func presentLockedSavedNotice() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            showLockedSavedAlert = true
        }
    }

    // MARK: - From the second one on: list + add CTA

    private var scheduleListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionLabel(L.scheduleSectionLabel(lang))
                Spacer()
                Text("\(scheduleManager.configs.count)/\(ScheduleManager.maxSchedules)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(AppColors.textTertiary)
            }

            VStack(spacing: 10) {
                ForEach(scheduleManager.configs) { config in
                    // Taps (edit) are received by SwipeRevealDelete's onTap
                    // (with a Button inside the card, a tap registers at the moment of a swipe and the edit sheet opens
                    // by mistake)
                    let isRunning = scheduleManager.isShieldActive
                        && scheduleManager.isWithinSchedule(config: config)
                        && !scheduleManager.isSkipped(config: config)

                    SwipeRevealDelete(
                        onDelete: {
                            scheduleToDelete = config
                            showDeleteConfirmation = true
                        },
                        onTap: {
                            // 🔴 While blocking is running, do not allow editing. Send the user to the stop screen instead.
                            //    Editing the schedule is also a path to "escape the current blocking"
                            //    (shifting the time would unlock it).
                            //    Once the current occurrence is ended, editing becomes possible, so the user is not stuck
                            if isRunning {
                                stopTarget = config
                            } else {
                                editorState = ScheduleEditorState(config: config)
                            }
                        },
                        isSwipeDisabled: isRunning
                    ) {
                        ScheduleRowCard(
                            config: config,
                            isActive: isRunning,
                            isRunning: isRunning,
                            isLockedByPaywall: !proAccess.canAccess(.schedule),
                            onLockedTap: { showProPaywall = true },
                            onToggle: { isEnabled in
                                // Switching to ON = the moment of running, so gate on payment here (OFF is always allowed.
                                // Normally not reachable because the lock icon is shown, but this is insurance for a leftover ON right
                                // after a subscription expires, etc.)
                                if isEnabled && !proAccess.canAccess(.schedule) {
                                    showProPaywall = true
                                } else {
                                    scheduleManager.setScheduleEnabled(id: config.id, isEnabled: isEnabled)
                                }
                            }
                        )
                    }
                }

                if scheduleManager.configs.count < ScheduleManager.maxSchedules {
                    // Make it stand out like a CTA (2026-07-15 real device feedback: with a dashed button, it was unclear
                    // what to press)
                    PrimaryButton(
                        lang == .japanese ? "スケジュールを追加" : "Add schedule", // Wording is waiting for the user's review
                        icon: "plus"
                    ) {
                        editorState = ScheduleEditorState(config: nil)
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var hasSelection: Bool {
        !appSelection.applicationTokens.isEmpty ||
        !appSelection.categoryTokens.isEmpty
    }
}

// MARK: - Schedule Row Card (one row in the list)

private struct ScheduleRowCard: View {
    let config: ScheduleConfig
    let isActive: Bool
    /// Do not let the toggle be touched while blocking is running.
    /// 🔴 Instead of a toggle that does not respond, pass the tap through to the row's gesture and
    ///    send the user to the stop screen (the toggle is the first thing people reach for when they want
    ///    to stop, so do not kill it. Connect it to the right destination)
    var isRunning: Bool = false
    /// Non-paying gate: if true, show LockedToggleBadge instead of the toggle, and a tap opens the paywall
    /// (conveys "not usable" on the spot better than a toggle that bounces back. 2026-07-19 user idea)
    let isLockedByPaywall: Bool
    let onLockedTap: () -> Void
    let onToggle: (Bool) -> Void

    // Added because, like ScheduleFormSections, it does not have lang (2026-07-22 English support)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// Feedback #11: show the bottom strip and lock icon only when not paying AND OFF (= this card cannot
    /// run)
    private var isLocked: Bool {
        isLockedByPaywall && !config.isEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Taps (edit) are handled by SwipeRevealDelete's onTap (no Button: swipe misfires)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.timeRangeText(config))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    HStack(spacing: 6) {
                        if isActive {
                            Circle()
                                .fill(AppColors.success)
                                .frame(width: 6, height: 6)
                        }
                        Text(Self.weekdaySummary(config.weekdays, lang: lang))
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Feedback #11 revised (2026-07-22 real device feedback): dim only the info column. Dimming the
                // toggle/lock badge to 55% too makes it so dark that "you cannot tell what the button is" (the main
                // cause in the first version)
                .opacity(config.isEnabled ? 1 : 0.55)

                if isLocked {
                    LockedToggleBadge(action: onLockedTap)
                } else {
                    Toggle("", isOn: Binding(
                        get: { config.isEnabled },
                        set: { onToggle($0) }
                    ))
                    .labelsHidden()
                    .tint(AppColors.primaryFallback)
                    // While blocking, the toggle itself has no hit area → the row's tap picks it up and goes to the stop
                    // screen
                    .allowsHitTesting(!isRunning)
                }
            }
            .padding(16)

            if isLocked {
                // Feedback #11 revised: the first version with a solid CTA color fill was rejected by the user → quiet
                // strip (see LockedRunStrip)
                LockedRunStrip(lang: lang, action: onLockedTap)
            }
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    static func timeRangeText(_ config: ScheduleConfig) -> String {
        String(format: "%02d:%02d → %02d:%02d", config.startHour, config.startMinute, config.endHour, config.endMinute)
    }

    static func weekdaySummary(_ weekdays: [Int], lang: AppLanguage) -> String {
        let set = Set(weekdays)
        if set == Set([2, 3, 4, 5, 6]) { return L.weekdaySummaryWeekdays(lang) }
        if set == Set(1...7) { return L.weekdaySummaryEveryday(lang) }
        if set == Set([1, 7]) { return L.weekdaySummaryWeekend(lang) }
        return weekdays.sorted()
            .compactMap { day -> String? in
                let name = L.weekdayShortName(day, lang)
                return name.isEmpty ? nil : name
            }
            .joined(separator: L.weekdaySummarySeparator(lang))
    }
}

// MARK: - Schedule Form Sections (time + weekdays. Shared by the inline first one and the editor
// sheet)

private struct ScheduleFormSections: View {
    @Binding var startTime: Date
    @Binding var endTime: Date
    @Binding var selectedWeekdays: Set<Int>

    /// F5: removed the transparent DatePicker trick. Holds the edit target of the wheel picker opened in a
    /// sheet
    @State private var editingTime: TimeEditTarget?

    // Same implementation as ScheduleBlockView itself (added because this view does not have lang,
    // 2026-07-22 English support)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    private let weekdayNumbers = [1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        VStack(spacing: 24) {
            timeSection
            weekdaySection
        }
        .sheet(item: $editingTime) { target in
            timeEditSheet(for: target)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(AppColors.textTertiary)
    }

    // MARK: - Time Section

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel(L.scheduleTimeSectionLabel(lang))

            HStack(spacing: 12) {
                // Start time (tap to open the wheel picker sheet)
                timeColumn(time: startTime, target: .start)

                Text("→")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(AppColors.textTertiary)

                // End time
                timeColumn(time: endTime, target: .end)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
            )
        }
    }

    /// F5: removed the transparent DatePicker trick (opacity 0.011).
    /// The serif time text itself is the button, and tapping it opens the wheel picker sheet.
    private func timeColumn(time: Date, target: TimeEditTarget) -> some View {
        Button {
            editingTime = target
        } label: {
            Text(timeString(time))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// F5: stopped allocating a DateFormatter on every call. Format directly from the time components
    private func timeString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// F5: edit target of the wheel picker sheet (start/end)
    private func timeEditSheet(for target: TimeEditTarget) -> some View {
        let binding: Binding<Date> = target == .start ? $startTime : $endTime
        return VStack(spacing: 20) {
            Text(target == .start ? L.timeEditStart(lang) : L.timeEditEnd(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 24)

            DatePicker(
                "",
                selection: binding,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .tint(AppColors.textPrimary)
            .environment(\.colorScheme, .dark)

            Button {
                editingTime = nil
            } label: {
                Text(L.timeEditDone(lang))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.92))
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea())
        // Header (24+18) + picker 216 + done button (50+24) + spacing 40 ≈ 372pt.
        // With 320 the header at the top gets cut off (real device feedback 2026-07-15), so 400 from
        // measurement + margin
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Weekday Section

    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel(L.scheduleRepeatSectionLabel(lang))

            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(weekdayNumbers, id: \.self) { day in
                        WeekdayButton(
                            label: L.weekdayInitial(day, lang),
                            isSelected: selectedWeekdays.contains(day)
                        ) {
                            if selectedWeekdays.contains(day) {
                                selectedWeekdays.remove(day)
                            } else {
                                selectedWeekdays.insert(day)
                            }
                        }
                    }
                }

                // Quick selection
                HStack(spacing: 8) {
                    QuickSelectButton(
                        title: L.weekdaySummaryWeekdays(lang),
                        isActive: selectedWeekdays == [2, 3, 4, 5, 6]
                    ) {
                        selectedWeekdays = [2, 3, 4, 5, 6]
                    }

                    QuickSelectButton(
                        title: L.weekdaySummaryEveryday(lang),
                        isActive: selectedWeekdays == [1, 2, 3, 4, 5, 6, 7]
                    ) {
                        selectedWeekdays = [1, 2, 3, 4, 5, 6, 7]
                    }

                    QuickSelectButton(
                        title: L.weekdaySummaryWeekend(lang),
                        isActive: selectedWeekdays == [1, 7]
                    ) {
                        selectedWeekdays = [1, 7]
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
            )
        }
    }
}

// MARK: - Schedule Editor (sheet for adding the second one on / editing existing ones)

private struct ScheduleEditorView: View {
    let existing: ScheduleConfig?
    let canSave: Bool
    let onSave: (ScheduleConfig) -> Void
    let onDelete: (() -> Void)?

    /// Confirmation alert for the edit screen's delete button (2026-07-25 real device feedback: it deleted
    /// immediately)
    @State private var showDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss

    // 2026-07-17: this sheet had hardcoded Japanese, so English support was added (fixes 17 items without
    // English)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    @State private var startTime: Date
    @State private var endTime: Date
    @State private var selectedWeekdays: Set<Int>

    init(
        existing: ScheduleConfig?,
        canSave: Bool,
        onSave: @escaping (ScheduleConfig) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.existing = existing
        self.canSave = canSave
        self.onSave = onSave
        self.onDelete = onDelete

        let calendar = Calendar.current
        if let existing {
            _startTime = State(initialValue: calendar.date(from: DateComponents(
                hour: existing.startHour,
                minute: existing.startMinute
            )) ?? Date())
            _endTime = State(initialValue: calendar.date(from: DateComponents(
                hour: existing.endHour,
                minute: existing.endMinute
            )) ?? Date())
            _selectedWeekdays = State(initialValue: Set(existing.weekdays))
        } else {
            // Default: 22:00 - 07:00, weekdays
            _startTime = State(initialValue: calendar.date(from: DateComponents(hour: 22, minute: 0)) ?? Date())
            _endTime = State(initialValue: calendar.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())
            _selectedWeekdays = State(initialValue: [2, 3, 4, 5, 6])
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(existing == nil
                     ? (lang == .japanese ? "スケジュールを追加" : "Add Schedule")
                     : (lang == .japanese ? "スケジュールを編集" : "Edit Schedule")) // Wording is waiting for the user's review
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 28)

                ScheduleFormSections(
                    startTime: $startTime,
                    endTime: $endTime,
                    selectedWeekdays: $selectedWeekdays
                )

                // Save/delete
                actionSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // 2026-07-25 real device feedback: swipe-left delete in the list had a confirmation, but the edit
        // screen's delete button deleted immediately. Delete confirmation follows the design rule of always
        // using a centered .alert
        .alert(lang == .japanese ? "スケジュールを削除" : "Delete schedule", isPresented: $showDeleteConfirm) { // Wording is waiting for the user's review
            Button(lang == .japanese ? "キャンセル" : "Cancel", role: .cancel) { }
            Button(lang == .japanese ? "削除" : "Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(lang == .japanese ? "このスケジュールを削除しますか?" : "Delete this schedule?") // Wording is waiting for the user's review
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                lang == .japanese ? "保存" : "Save", // Wording is waiting for the user's review
                icon: "checkmark.circle.fill",
                isDisabled: !canSaveNow
            ) {
                onSave(buildConfig())
                dismiss()
            }

            if !canSave {
                // Show why it cannot be saved without selecting apps (same pattern as adding a place)
                Text(lang == .japanese ? "先にブロックするアプリを選択してください" : "Pick the apps to block first") // Wording is waiting for the user's review
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else if !isDurationValid {
                // L14: for extremely short schedules such as start=end, show the reason before saving
                Text(L.scheduleTooShort(ScheduleManager.minScheduleDurationMinutes, lang))
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            if onDelete != nil {
                // Delete schedule (muted destructive outline).
                // Not an immediate delete. Confirm with a centered alert first (2026-07-25 real device feedback)
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                        Text(lang == .japanese ? "スケジュールを削除" : "Delete schedule") // Wording is waiting for the user's review
                            .font(AppTypography.buttonMedium)
                    }
                    .foregroundColor(AppColors.error)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(AppColors.error.opacity(0.4), lineWidth: 1)
                    )
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Save

    private var canSaveNow: Bool {
        canSave && !selectedWeekdays.isEmpty && isDurationValid
    }

    /// L14: whether the times in the current form are at least the minimum length
    /// (ScheduleManager.minScheduleDurationMinutes)
    private var isDurationValid: Bool {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        let duration = ScheduleManager.durationMinutes(for: ScheduleConfig(
            startHour: startComponents.hour ?? 0,
            startMinute: startComponents.minute ?? 0,
            endHour: endComponents.hour ?? 0,
            endMinute: endComponents.minute ?? 0
        ))
        return duration >= ScheduleManager.minScheduleDurationMinutes
    }

    private func buildConfig() -> ScheduleConfig {
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)

        return ScheduleConfig(
            id: existing?.id ?? UUID(),
            startHour: startComponents.hour ?? 22,
            startMinute: startComponents.minute ?? 0,
            endHour: endComponents.hour ?? 7,
            endMinute: endComponents.minute ?? 0,
            weekdays: Array(selectedWeekdays),
            isEnabled: existing?.isEnabled ?? true
        )
    }
}

// MARK: - Weekday Button

private struct WeekdayButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? AppColors.background : AppColors.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isSelected ? AppColors.primaryFallback : Color.clear)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.clear : AppColors.textTertiary.opacity(0.4), lineWidth: 1)
                        )
                )
        }
    }
}

// MARK: - Quick Select Button

private struct QuickSelectButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? AppColors.background : AppColors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isActive ? AppColors.primaryFallback : AppColors.secondaryBackground)
                )
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        ScheduleBlockView(blockingService: BlockingService.shared)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
    }
    .background(AppColors.background)
}
