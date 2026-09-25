//
//  ScheduleBlockView.swift
//  AppBlocker
//
//  スケジュールブロック設定画面（HomeView 内に埋め込まれる Content View）
//  複数スケジュール対応 (2026-07-15): 上限 ScheduleManager.maxSchedules、アプリ選択は全モード共通カード。
//  1 個目はフォームを全面に出して「スケジュールを開始」CTA で引き締める (タイマーと同じ文法)。
//  2 個目以降は一覧+「スケジュールを追加」CTA (2026-07-15 実機FB)。
//

import SwiftUI
import FamilyControls

/// F5: timeColumn タップで開くホイールピッカーシートの編集対象
private enum TimeEditTarget: Identifiable, Hashable {
    case start
    case end
    var id: Self { self }
}

/// エディタシートの対象 (既存スケジュールの編集専用。新規は 1 個目=インライン / 2 個目以降=空フォームのシート)
private struct ScheduleEditorState: Identifiable {
    let id = UUID()
    let config: ScheduleConfig?
}

struct ScheduleBlockView: View {
    @ObservedObject var blockingService: BlockingService
    @ObservedObject var scheduleManager = ScheduleManager.shared
    // 2026-07-19 ゲート方針転換: モード自体は無料で開けて設定も作れる (サンクコスト)。
    // 課金を要求するのは「実行 (ONにする/開始する)」の瞬間だけ
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var showingPicker = false
    @State private var showProPaywall = false
    /// 無課金で保存した直後の説明アラート (保存はされている・実行には課金、を一拍で伝える)
    @State private var showLockedSavedAlert = false
    @State private var editorState: ScheduleEditorState?
    @State private var scheduleToDelete: ScheduleConfig?
    @State private var showDeleteConfirmation = false
    /// 遮断が走っている予定をタップした時に出す中断画面の対象
    @State private var stopTarget: ScheduleConfig?

    // タイマーの selectedApps 流用でスケジュールタブを開くだけにタイマー選択が書き換わる
    // クロス汚染があった (2026-07-16 Fableレビュー)。LocationBlockView と同じくローカル @State で隔離する
    @State private var appSelection = FamilyActivitySelection()

    // 1 個目 (インラインフォーム) の編集値。デフォルト: 22:00 - 07:00、平日
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
                // 1 個目: フォームを全面に出して CTA で開始 (タイマーと同じ「どこを押すか」が明確な構造)
                inlineFirstScheduleSection
            } else {
                // 2 個目以降: 一覧 + 追加 CTA
                scheduleListSection
            }

            // アプリ選択 (全スケジュール共通) は最下部 = 他モードと同じ位置
            AppSelectCard(
                selection: appSelection,
                lang: lang,
                subtitle: lang == .japanese ? "全スケジュール共通" : "Shared across schedules" // 文言はユーザー添削待ち
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
        // FB#11 (2026-07-21): 保存後の説明は alert からカスタムシートに格上げ。文言はユーザー添削待ち
        .sheet(isPresented: $showLockedSavedAlert) {
            LockedSavedNoticeSheet(
                title: lang == .japanese
                    ? "ロックの実行には 1% エリートが必要です"
                    : "Running locks requires 1% Elite",
                message: lang == .japanese
                    ? "作成したスケジュールは保存されています。有効にするには 1% エリートに参加してください。"
                    : "Your schedule is saved. Join 1% Elite to turn it on.",
                onSeeElite: {
                    // シート同士の presentation 衝突回避 (LocationBlockView.presentPaywallAfterSheet と同じ理由)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        showProPaywall = true
                    }
                },
                closeTitle: lang == .japanese ? "閉じる" : "Close",
                ctaTitle: L.blockLockedSeeElite(lang)
            )
        }
        .onChange(of: appSelection) { _, newValue in
            // アプリ選択は全スケジュール共通: 変更を即保存し、稼働中の shield にも反映する
            // (configs.isEmpty ガードは撤去 — 保存自体は無害で、1個目追加前の選択も永続化されるべき)
            scheduleManager.updateSharedSelection(newValue)
        }
        .onAppear {
            // 保存されたアプリ選択を読み込み (configs の有無に関わらず。scheduleSelection キーは
            // オンボ末尾の共有初期値 saveInitialSharedSelection でも書かれるため)
            if let savedSelection = scheduleManager.loadSelectionFromAppGroup() {
                appSelection = savedSelection
            }
        }
        // 遮断が走っている予定をタップした時の中断画面。
        // 🔴 タイマーと同じ StopConfirmationView を使う。難易度モードを1箇所直せば
        //    タイマーとスケジュールの両方に効く (画面を新設しない理由)
        .fullScreenCover(item: $stopTarget) { config in
            StopConfirmationView(
                isPresented: Binding(
                    get: { stopTarget != nil },
                    set: { if !$0 { stopTarget = nil } }
                ),
                lang: lang,
                onConfirm: {
                    // 予定は消さず、走っている回だけを終わらせる
                    scheduleManager.skipCurrentOccurrence(id: config.id)
                    stopTarget = nil
                },
                challenge: UnlockChallengeService.shared.activeChallenge ?? .longPress,
                // 完遂率の母数は「予定10分以上のタイマーロック」のみ (033) なので
                // スケジュールの中断では下がらない
                affectsCompletionRateOverride: false
            )
        }
        .sheet(item: $editorState) { state in
            ScheduleEditorView(
                existing: state.config,
                canSave: hasSelection,
                onSave: { config in
                    // 無課金: 保存はさせるが必ず OFF で保存し、その場でペイウォール
                    // (作った設定は残る = サンクコスト。ONにするには課金)
                    var config = config
                    if !proAccess.canAccess(.schedule) && config.isEnabled {
                        config.isEnabled = false
                        presentLockedSavedNotice()
                    }
                    if state.config == nil {
                        // A-7: settle 版。時間帯内での追加は即座に shield 適用が走るレースがあるため、
                        // PreparingLockOverlay で操作を封じる間隔を挟む
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
        .alert(lang == .japanese ? "スケジュールを削除" : "Delete schedule", isPresented: $showDeleteConfirmation) { // 文言はユーザー添削待ち
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
                     : "Delete \(ScheduleRowCard.timeRangeText(config)) (\(ScheduleRowCard.weekdaySummary(config.weekdays, lang: lang)))?") // 文言はユーザー添削待ち
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

    // MARK: - 1 個目: インラインフォーム + 開始 CTA

    private var inlineFirstScheduleSection: some View {
        VStack(spacing: 24) {
            ScheduleFormSections(
                startTime: $inlineStartTime,
                endTime: $inlineEndTime,
                selectedWeekdays: $inlineWeekdays
            )

            VStack(spacing: 8) {
                PrimaryButton(
                    lang == .japanese ? "スケジュールを開始" : "Start schedule", // 文言はユーザー添削待ち
                    icon: "calendar.badge.checkmark",
                    isDisabled: !canStartInline
                ) {
                    startInlineSchedule()
                }

                if !hasSelection {
                    Text(lang == .japanese
                         ? "下の「ブロックするアプリ」を選択すると開始できます"
                         : "Pick your apps under \"Apps to block\" to get started") // 文言はユーザー添削待ち
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else if !isInlineDurationValid {
                    // L14: 開始=終了などの極端に短いスケジュールは開始前に理由を明示する
                    // (保存自体は ScheduleManager.addSchedule 側でも弾かれるが、CTA を無効化して先に防ぐ)
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

    /// L14: 現在のインラインフォームの時刻が最小長 (ScheduleManager.minScheduleDurationMinutes) 以上か
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
        // 無課金: 設定自体は OFF で保存 (サンクコスト) し、説明シート → エリートを見る導線
        if !proAccess.canAccess(.schedule) {
            config.isEnabled = false
            presentLockedSavedNotice()
        }
        // A-7: settle 版 (時間帯内での開始は即 shield 適用が走るため)
        Task { await blockingService.startScheduleBlockingWithSettle(config: config, apps: appSelection) }
    }

    /// FB#11: 無課金保存後の説明シートを出す。エディタ/インラインどちらの経路でも、直前のシート
    /// (エディタシート等) が閉じ切ってから表示する (presentation 衝突回避。LocationBlockView の
    /// presentPaywallAfterSheet と同じ理由・同じ 0.55 秒)
    private func presentLockedSavedNotice() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            showLockedSavedAlert = true
        }
    }

    // MARK: - 2 個目以降: 一覧 + 追加 CTA

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
                    // タップ (編集) は SwipeRevealDelete の onTap で受ける
                    // (カード内 Button だとスワイプの瞬間にタップ成立して編集シートが誤爆する)
                    let isRunning = scheduleManager.isShieldActive
                        && scheduleManager.isWithinSchedule(config: config)
                        && !scheduleManager.isSkipped(config: config)

                    SwipeRevealDelete(
                        onDelete: {
                            scheduleToDelete = config
                            showDeleteConfirmation = true
                        },
                        onTap: {
                            // 🔴 遮断が走っている間は編集させず、中断画面へ送る。
                            //    予定の編集も「今の遮断から逃げる」経路になるため
                            //    (時間をずらせば解除できてしまう)。
                            //    今の回を終えれば編集できるようになるので詰まない
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
                                // ONへの切替 = 実行の瞬間なのでここで課金ゲート (OFFはいつでも可。
                                // 通常はロック錠表示で到達しないが、購読失効直後の残存ON等の保険)
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
                    // CTA 級に目立たせる (2026-07-15 実機FB: 破線ボタンでは何を押すか分からない)
                    PrimaryButton(
                        lang == .japanese ? "スケジュールを追加" : "Add schedule", // 文言はユーザー添削待ち
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

// MARK: - Schedule Row Card (一覧の 1 行)

private struct ScheduleRowCard: View {
    let config: ScheduleConfig
    let isActive: Bool
    /// 遮断が走っている間はトグルを触らせない。
    /// 🔴 反応しないトグルにするのではなく、タップを行のジェスチャに素通りさせて
    ///    中断画面へ送る (止めたい人が最初に指を伸ばすのはトグルなので、
    ///    そこを殺さず正しい行き先に繋ぐ)
    var isRunning: Bool = false
    /// 無課金ゲート: true ならトグルの代わりに LockedToggleBadge を出し、タップでペイウォール
    /// (跳ね返るトグルより「使えない状態」がその場で伝わる — 2026-07-19 ユーザー案)
    let isLockedByPaywall: Bool
    let onLockedTap: () -> Void
    let onToggle: (Bool) -> Void

    // ScheduleFormSections と同じく lang を持たないため追加 (2026-07-22 英語化対応)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// FB#11: 無課金 かつ OFF (=このカードは実行できない) の時だけ下端ストリップとロック錠を出す
    private var isLocked: Bool {
        isLockedByPaywall && !config.isEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // タップ (編集) は SwipeRevealDelete 側の onTap で処理する (Button 禁止 — スワイプ誤爆)
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
                // FB#11改 (2026-07-22 実機FB): 減光は情報列のみ。トグル/ロック錠バッジまで
                // 55% にすると「何のボタンかわからない」暗さになる (初版の主因)
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
                    // 遮断中はトグル自身が当たり判定を持たない → 行のタップが拾って中断画面へ
                    .allowsHitTesting(!isRunning)
                }
            }
            .padding(16)

            if isLocked {
                // FB#11改: CTA色ベタ塗り初版はユーザー却下 → 静音ストリップ (LockedRunStrip 参照)
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

// MARK: - Schedule Form Sections (時刻 + 曜日。インライン 1 個目とエディタシートで共有)

private struct ScheduleFormSections: View {
    @Binding var startTime: Date
    @Binding var endTime: Date
    @Binding var selectedWeekdays: Set<Int>

    /// F5: 透過 DatePicker トリックを廃止し、シートで開くホイールピッカーの編集対象を保持する
    @State private var editingTime: TimeEditTarget?

    // ScheduleBlockView 本体と同じ実装 (このビューは lang を持たないため追加、2026-07-22 英語化対応)
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
                // 開始時刻（タップでホイールピッカーのシートを開く）
                timeColumn(time: startTime, target: .start)

                Text("→")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(AppColors.textTertiary)

                // 終了時刻
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

    /// F5: 透過 DatePicker トリック (opacity 0.011) を廃止。
    /// セリフ体の時刻テキストをそのままボタンにし、タップでホイールピッカーのシートを開く。
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

    /// F5: DateFormatter を呼び出しごとに確保していたのをやめ、時刻コンポーネントから直接整形する
    private func timeString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// F5: ホイールピッカーシートの編集対象 (開始/終了)
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
        // ヘッダ(24+18)+ピッカー216+完了ボタン(50+24)+spacing 40 ≈ 372pt。
        // 320 だと上端のヘッダが見切れる (実機FB 2026-07-15) ため実測+余裕で 400
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

                // クイック選択
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

// MARK: - Schedule Editor (2 個目以降の追加 / 既存の編集シート)

private struct ScheduleEditorView: View {
    let existing: ScheduleConfig?
    let canSave: Bool
    let onSave: (ScheduleConfig) -> Void
    let onDelete: (() -> Void)?

    /// 編集画面の削除ボタンの確認 alert (2026-07-25 実機FB: 即時削除だった)
    @State private var showDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss

    // 2026-07-17: このシートは日本語ハードコードだったため英語対応 (英語なし17件の解消)
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
            // デフォルト: 22:00 - 07:00、平日
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
                     : (lang == .japanese ? "スケジュールを編集" : "Edit Schedule")) // 文言はユーザー添削待ち
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 28)

                ScheduleFormSections(
                    startTime: $startTime,
                    endTime: $endTime,
                    selectedWeekdays: $selectedWeekdays
                )

                // 保存/削除
                actionSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // 2026-07-25 実機FB: 一覧の左スワイプ削除には確認があるのに、編集画面の削除ボタンは
        // 即時削除だった。削除確認は中央 .alert 統一の設計ルールに合わせる
        .alert(lang == .japanese ? "スケジュールを削除" : "Delete schedule", isPresented: $showDeleteConfirm) { // 文言はユーザー添削待ち
            Button(lang == .japanese ? "キャンセル" : "Cancel", role: .cancel) { }
            Button(lang == .japanese ? "削除" : "Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(lang == .japanese ? "このスケジュールを削除しますか?" : "Delete this schedule?") // 文言はユーザー添削待ち
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                lang == .japanese ? "保存" : "Save", // 文言はユーザー添削待ち
                icon: "checkmark.circle.fill",
                isDisabled: !canSaveNow
            ) {
                onSave(buildConfig())
                dismiss()
            }

            if !canSave {
                // アプリ未選択では保存できない理由を明示 (場所追加と同じパターン)
                Text(lang == .japanese ? "先にブロックするアプリを選択してください" : "Pick the apps to block first") // 文言はユーザー添削待ち
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else if !isDurationValid {
                // L14: 開始=終了などの極端に短いスケジュールは保存前に理由を明示する
                Text(L.scheduleTooShort(ScheduleManager.minScheduleDurationMinutes, lang))
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            if onDelete != nil {
                // スケジュールを削除（ミュートした destructive アウトライン）。
                // 即時削除ではなく中央 alert で確認してから (2026-07-25 実機FB)
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                        Text(lang == .japanese ? "スケジュールを削除" : "Delete schedule") // 文言はユーザー添削待ち
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

    /// L14: 現在のフォームの時刻が最小長 (ScheduleManager.minScheduleDurationMinutes) 以上か
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
