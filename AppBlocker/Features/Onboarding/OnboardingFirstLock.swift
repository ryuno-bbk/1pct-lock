//
//  OnboardingFirstLock.swift
//  AppBlocker
//
//  Last onboarding step: have the user start their first lock right there (added 2026-09-05)
//
//  🔴 Why this exists (measured):
//    Onboarding ended at .appSelect (choose apps to lock), and
//    there was no screen that "has the user start their first lock".
//    Few new users start a first lock, and
//    people who have locked once are more likely to go on to pay.
//    = What needs to grow is not the paywall but getting people to start the first lock.
//
//  🔴 Design policy:
//    - The user decides only the "time". Mode and unlock method are not asked
//      (the idea of showing unlock methods here was rejected by the user = it would be noise)
//    - The app selection card is also here. People who pressed "あとで選ぶ" ("Choose later") on
//      the previous page have an empty selection and could not start a lock as is (user feedback)
//    - Presets are 30/60/120 + custom, same as the existing home. No new concepts
//    - The default unlock method is a 2-second long press, so nobody gets stuck on day one
//    - Keep "あとで" ("Later"). Forcibly blocking the apps of someone who just installed risks an
//      immediate uninstall. But keep it low-key
//
//  ⚠️ Wording is waiting for the user's review
//

import SwiftUI
import FamilyControls

struct FirstLockStepView: View {
    let lang: AppLanguage
    let onFinish: () -> Void

    @ObservedObject private var blockingService = BlockingService.shared

    @State private var selectedMinutes: Int = 30
    @State private var showCustom = false
    @State private var showPicker = false
    @State private var isStarting = false

    /// Same values as home (HomeView.presetMinutes). Matched so the user finds the same options on home
    /// next time
    private let presetMinutes: [Int] = [30, 60, 120]

    private var isJa: Bool { lang == .japanese }

    private var totalCount: Int {
        blockingService.selectedApps.applicationTokens.count
            + blockingService.selectedApps.categoryTokens.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            // ⚠️ Wording is waiting for the user's review (another candidate: "Start working right now")
            Text(isJa ? "今すぐロックを開始する" : "Start your first lock")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                timerCard
                AppSelectCard(selection: blockingService.selectedApps, lang: lang) {
                    showPicker = true
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                PrimaryButton(primaryLabel) {
                    if totalCount == 0 {
                        showPicker = true
                    } else {
                        start()
                    }
                }
                .disabled(isStarting)

                Button(isJa ? "あとで" : "Later") { // Wording is waiting for the user's review
                    onFinish()
                }
                .font(AppTypography.footnote)
                .foregroundColor(AppColors.textTertiary)
                .disabled(isStarting)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $blockingService.selectedApps)
        .onChange(of: showPicker) { _, isShown in
            // Save as the shared initial value for the 3 modes when the picker closes
            // (same as .appSelect. Without saving here, starting a lock would have no targets)
            guard !isShown else { return }
            BlockingService.shared.saveInitialSharedSelection(blockingService.selectedApps)
        }
    }

    private var primaryLabel: String {
        if totalCount == 0 {
            return isJa ? "アプリを選択" : "Select apps" // Wording is waiting for the user's review
        }
        return isJa ? "ロックを開始" : "Start the lock" // Wording is waiting for the user's review
    }

    // MARK: - Time card (matches the look of timerSetupCard on home)

    private var timerCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("\(selectedMinutes)")
                    .font(.system(size: 64, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(AppColors.textPrimary)
                    .contentTransition(.numericText(value: Double(selectedMinutes)))
                    .animation(.easeInOut(duration: 0.2), value: selectedMinutes)

                Text(L.homeBlockTimeMinutes(lang))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
            }

            HStack(spacing: 8) {
                ForEach(presetMinutes, id: \.self) { preset in
                    pill(label: presetLabel(preset),
                         isSelected: !showCustom && selectedMinutes == preset) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedMinutes = preset
                            showCustom = false
                        }
                    }
                }
                pill(label: isJa ? "カスタム" : "Custom", isSelected: showCustom) { // Wording is waiting for the user's review
                    withAnimation(.easeInOut(duration: 0.2)) { showCustom = true }
                }
            }

            if showCustom {
                Picker("", selection: $selectedMinutes) {
                    // 5-minute steps. A first lock over 5 hours invites accidents, so cap it
                    ForEach(Array(stride(from: 5, through: 300, by: 5)), id: \.self) { m in
                        Text(presetLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 110)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.cardBackground))
    }

    /// Same notation as presetLabel on home ("30分 / 1時間 / 2時間" ("30 min / 1 hr / 2 hr"))
    private func presetLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return isJa ? "\(hours)時間" : "\(hours)h"
        }
        return isJa ? "\(minutes)分" : "\(minutes)m"
    }

    private func pill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? AppColors.background : AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? AppColors.accent : AppColors.secondaryBackground)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Start

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            // settle version: reduces freezes caused by a navigation race right after the shield is applied
            // (goes through the same path as startTimer on home)
            await blockingService.startTimerBlockingWithSettle(durationMinutes: selectedMinutes)
            isStarting = false
            onFinish()
        }
    }
}
