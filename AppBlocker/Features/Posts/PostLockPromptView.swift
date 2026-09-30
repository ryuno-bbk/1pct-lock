//
//  PostLockPromptView.swift
//  AppBlocker
//
//  Modal shown after posting, only to people who pressed the "ロックして作業を始める"
//  ("Lock and start working") button.
//  It puts almost the same UI as the home timer block (hero number + presets + app selection) in a
//  sheet and starts a timer block right there. An entry point that connects "words" to "action"
//  instead of ending at words (not shown to everyone automatically).
//
//  Real device feedback round 9: the old sheet ("15/30/60 pills + a button only") was too plain, so
//  it was fully redone. The special branch for no apps selected was removed, and AppSelectCard shows
//  that state (see HomeView.swift lines 445-592).
//

import SwiftUI
import FamilyControls

struct PostLockPromptView: View {
    /// Called when the lock starts successfully (the caller closes this modal and dismisses the whole
    /// flow too)
    let onLockStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blockingService = BlockingService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var selectedMinutes: Int = 30
    @State private var showCustomDurationPicker = false
    @State private var showingPicker = false

    private let presetMinutes: [Int] = [30, 60, 120]

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var hasAppsSelected: Bool {
        !blockingService.selectedApps.applicationTokens.isEmpty ||
        !blockingService.selectedApps.categoryTokens.isEmpty
    }

    var body: some View {
        ScrollView {
            // Real device feedback round 10 (2026-07-15): removed the pushy copy + made it compact enough to fit
            // in a half-height sheet
            VStack(spacing: 16) {
                Text(PostFlowStrings.lockPromptHeadline(lang))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                timerSetupCard
                appSelectionCard

                VStack(spacing: 12) {
                    PrimaryButton(
                        PostFlowStrings.lockStartCTA(lang),
                        isDisabled: !hasAppsSelected
                    ) {
                        // Start with the settle version, then close the whole flow when done (to the countdown on home)
                        Task {
                            await blockingService.startTimerBlockingWithSettle(durationMinutes: selectedMinutes)
                            onLockStarted()
                        }
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text(PostFlowStrings.lockLaterCTA(lang))
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(AppColors.background)
        .familyActivityPicker(
            isPresented: $showingPicker,
            selection: $blockingService.selectedApps
        )
        // Real device feedback round 10: full screen was mostly empty space, so about half height (the
        // content is slightly taller than .medium, so 0.6. With the custom slider expanded or on small
        // devices it can go up to .large. The content is a ScrollView, so it scrolls if it overflows)
        .presentationDetents([.fraction(0.6), .large])
        // A sheet is a separate hierarchy, so the overlay on the home side does not cover it. Show it here too
        .overlay {
            if blockingService.isPreparingLock {
                PreparingLockOverlay(lang: lang)
            }
        }
        .animation(.easeOut(duration: 0.2), value: blockingService.isPreparingLock)
    }

    // MARK: - Timer Setup Card (same structure as HomeView.timerSetupCard. Making it a shared component
    // is postponed for now)

    private var timerSetupCard: some View {
        VStack(spacing: 16) {
            // Large time display (hero). 56pt, one size smaller than home (72pt), to fit in the half-height sheet
            HStack {
                Spacer()
                VStack(spacing: 2) {
                    Text("\(selectedMinutes)")
                        .font(.system(size: 56, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(AppColors.textPrimary)
                        .contentTransition(.numericText(value: Double(selectedMinutes)))
                        .animation(.easeInOut(duration: 0.2), value: selectedMinutes)

                    Text(L.homeBlockTimeMinutes(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)
                }
                Spacer()
            }

            presetPillsRow

            if showCustomDurationPicker {
                customDurationPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
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
                label: lang == .japanese ? "カスタム" : "Custom", // Wording is waiting for the user's review
                isSelected: showCustomDurationPicker
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCustomDurationPicker = true
                }
            }
        }
    }

    /// Label for the preset time pills (e.g. "30分 / 1時間 / 2時間" ("30 min / 1 hr / 2 hr"))
    private func presetLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return lang == .japanese ? "\(hours)時間" : "\(hours)h" // Wording is waiting for the user's review
        }
        return lang == .japanese ? "\(minutes)分" : "\(minutes)m" // Wording is waiting for the user's review
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

    /// Custom time picker (reuses the same slider UI as home)
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

    // MARK: - App Selection Card (shared component AppSelectCard, same as HomeView)

    private var appSelectionCard: some View {
        AppSelectCard(selection: blockingService.selectedApps, lang: lang) {
            showingPicker = true
        }
    }
}
