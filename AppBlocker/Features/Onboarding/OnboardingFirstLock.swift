//
//  OnboardingFirstLock.swift
//  AppBlocker
//
//  オンボーディング最終ステップ: その場で最初のロックを開始させる (2026-09-05 新設)
//
//  🔴 なぜ作るか (実測):
//    オンボは .appSelect (ロックするアプリを選ぶ) で終わっており、
//    「最初のロックを始めさせる」画面が存在しなかった。
//    新規ユーザーのうち最初のロックを始める人の割合が低く、
//    一度ロックした人は課金まで進みやすい。
//    = 伸ばすべきは課金画面ではなく、最初のロックを始めさせること。
//
//  🔴 設計方針:
//    - 決めさせるのは「時間」だけ。モードも解除方法も聞かない
//      (解除方法をここに出す案はユーザー判断で不採用 = ノイズになる)
//    - アプリ選択カードも置く。前ページで「あとで選ぶ」を押した人は
//      選択が空のままで、そのままではロックを開始できないため (ユーザー指摘)
//    - プリセットは既存ホームと同じ 30/60/120 + カスタム。新しい概念を作らない
//    - 既定の解除方法は 2秒長押しなので、初日に詰むことはない
//    - 「あとで」は残す。インストール直後の人のアプリを強制的に止めると
//      その場でアンインストールされる危険がある。ただし目立たせない
//
//  ⚠️ 文言はユーザー添削待ち
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

    /// ホーム (HomeView.presetMinutes) と同じ値。次からホームで同じものを見つけられるように揃える
    private let presetMinutes: [Int] = [30, 60, 120]

    private var isJa: Bool { lang == .japanese }

    private var totalCount: Int {
        blockingService.selectedApps.applicationTokens.count
            + blockingService.selectedApps.categoryTokens.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            // ⚠️ 文言はユーザー添削待ち (「今すぐ作業を始める」案もあり)
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

                Button(isJa ? "あとで" : "Later") { // 文言はユーザー添削待ち
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
            // ピッカーを閉じた時点で3モード共通の初期値として保存する
            // (.appSelect と同じ扱い。ここで保存しないとロックを開始しても対象が空になる)
            guard !isShown else { return }
            BlockingService.shared.saveInitialSharedSelection(blockingService.selectedApps)
        }
    }

    private var primaryLabel: String {
        if totalCount == 0 {
            return isJa ? "アプリを選択" : "Select apps" // 文言はユーザー添削待ち
        }
        return isJa ? "ロックを開始" : "Start the lock" // 文言はユーザー添削待ち
    }

    // MARK: - 時間カード (ホームの timerSetupCard と同じ見た目に揃える)

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
                pill(label: isJa ? "カスタム" : "Custom", isSelected: showCustom) { // 文言はユーザー添削待ち
                    withAnimation(.easeInOut(duration: 0.2)) { showCustom = true }
                }
            }

            if showCustom {
                Picker("", selection: $selectedMinutes) {
                    // 5分刻み。5時間を超える初回ロックは事故のもとなので上限を切る
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

    /// ホームの presetLabel と同じ表記 (30分 / 1時間 / 2時間)
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

    // MARK: - 開始

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            // settle 版: shield 適用直後の遷移レース由来のフリーズを緩和する
            // (ホームの startTimer と同じ経路を通す)
            await blockingService.startTimerBlockingWithSettle(durationMinutes: selectedMinutes)
            isStarting = false
            onFinish()
        }
    }
}
