//
//  PostLockPromptView.swift
//  AppBlocker
//
//  投稿完了後、[ロックして作業を始める] を押した人だけに表示するモーダル。
//  ホームのタイマーブロックとほぼ同一の UI (ヒーロー数字 + プリセット + アプリ選択) をシートに載せ、
//  その場でタイマーブロックを開始する。「言葉」だけで終わらせず「行動」に接続するための導線
//  (全員自動表示ではない)。
//
//  実機FB第9弾: 旧「15/30/60ピル+ボタンだけ」のシートは簡素すぎるため全面改装。
//  アプリ未選択時の専用分岐は廃止し、AppSelectCard がその状態表示を担う (HomeView.swift 445-592行を参照)。
//

import SwiftUI
import FamilyControls

struct PostLockPromptView: View {
    /// ロック開始成功時に呼ばれる (呼び出し側でこのモーダルを閉じ、フロー全体も dismiss する)
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
            // 実機FB第10弾 (2026-07-15): 煽りコピー撤去 + 半画面シートに収まるようコンパクト化
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
                        // settle 版で開始し、完了後にフロー全体を閉じる (ホームのカウントダウンへ)
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
        // 実機FB第10弾: 全画面は余白だらけだったので半画面程度に (中身が .medium より
        // わずかに背が高いので 0.6。カスタムスライダー展開時や小型機は .large まで引き上げ可能。
        // 中身は ScrollView なので溢れてもスクロールできる)
        .presentationDetents([.fraction(0.6), .large])
        // sheet は独立階層のため、ホーム側のオーバーレイが被らない。ここにも出す
        .overlay {
            if blockingService.isPreparingLock {
                PreparingLockOverlay(lang: lang)
            }
        }
        .animation(.easeOut(duration: 0.2), value: blockingService.isPreparingLock)
    }

    // MARK: - Timer Setup Card (HomeView.timerSetupCard と同一構成。共通部品化は今回見送り)

    private var timerSetupCard: some View {
        VStack(spacing: 16) {
            // 大きな時間表示 (ヒーロー)。半画面シートに収めるためホーム(72pt)より一回り小さい56pt
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

    /// カスタム時間ピッカー (ホームと同一のスライダー UI をそのまま流用)
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

    // MARK: - App Selection Card (共通部品 AppSelectCard、HomeView と同一)

    private var appSelectionCard: some View {
        AppSelectCard(selection: blockingService.selectedApps, lang: lang) {
            showingPicker = true
        }
    }
}
