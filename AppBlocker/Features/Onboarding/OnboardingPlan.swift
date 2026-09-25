//
//  OnboardingPlan.swift
//  AppBlocker
//
//  ⚠️ 現在フロー未使用 (2026-07-19 ユーザー決定で .plan ステップをオンボから除外)。
//  「プラン」概念がこのアプリに合わないため直行に変更。将来「スケジュールを先に提案 →
//  ユーザーが手直し → 有効化は Pro」ページに作り直す構想があり、その際の下敷きとして残置。
//
//  (旧役割) 診断オンボーディング PHASE 3: プラン生成 → パーソナルプラン提示 → レビュー依頼。
//

import SwiftUI
import StoreKit

struct PlanBuildingStepView: View {
    /// 夢 (空可)。空なら夢の行は出さない
    let dreamText: String
    /// Q5 の選択 (表示名の配列)。空なら汎用文言
    let wastedAppNames: [String]
    /// Q3 の回答 (推奨ロック時間の計算用)。nil なら 2h 固定
    let dailyHours: QuizDailyHours?
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    // @Environment(\.requestReview) は 2026-08-06 に撤去 (Guideline 5.6.3)。
    // オンボーディング中に評価を求めない

    @State private var revealedChecks = 0
    @State private var showPlan = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// 推奨ロック時間 = 自己申告の約35% を 1〜4h に丸め
    private var recommendedLockHours: Int {
        let h = dailyHours?.medianHours ?? 5
        return min(max(Int((h * 0.35).rounded()), 1), 4)
    }

    /// 年間で取り戻す時間
    private var reclaimedHoursPerYear: Int {
        recommendedLockHours * 365
    }

    private var checkItems: [String] {
        let jp = lang == .japanese
        var items: [String] = [jp ? "診断結果を分析" : "Analyzing your answers"]

        let trimmedDream = dreamText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDream.isEmpty {
            let short = trimmedDream.count > 18 ? String(trimmedDream.prefix(18)) + "…" : trimmedDream
            items.append(jp ? "夢「\(short)」を登録" : "Registering your dream: “\(short)”")
        }

        if !wastedAppNames.isEmpty {
            let apps = wastedAppNames.prefix(3).joined(separator: jp ? "・" : ", ")
            items.append(jp ? "\(apps) をロック対象の候補に登録" : "Marking \(apps) as lock candidates")
        } else {
            items.append(jp ? "ロック対象の候補を準備" : "Preparing lock candidates")
        }

        items.append(jp ? "初週のロック戦略を計算" : "Building your first-week strategy")
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 88)

            Text(lang == .japanese ? "あなたのプランを構築中" : "Building your plan")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(checkItems.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: idx < revealedChecks ? "checkmark" : "circle.dotted")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(idx < revealedChecks ? AppColors.textPrimary : AppColors.textTertiary)
                            .frame(width: 16)

                        Text(item)
                            .font(.system(size: 14.5))
                            .foregroundColor(idx < revealedChecks ? AppColors.textPrimary : AppColors.textTertiary)
                    }
                    .animation(.easeOut(duration: 0.25), value: revealedChecks)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            if showPlan {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(AppColors.textTertiary.opacity(0.25))
                        .frame(height: 1)
                        .padding(.vertical, 20)

                    Text(lang == .japanese
                         ? "推奨: 1日\(recommendedLockHours)時間ロックから。"
                         : "Recommended: start with a \(recommendedLockHours)-hour daily lock.")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    Text(lang == .japanese
                         ? "1年続けば \(reclaimedHoursPerYear.formatted())時間 — TOEIC 900 の学習時間 (約1,000時間) と同じ帯域を取り戻す。"
                         : "A year of that reclaims \(reclaimedHoursPerYear.formatted()) hours — the same range it takes to reach TOEIC 900 (~1,000h).")
                        .font(.system(size: 13.5))
                        .foregroundColor(AppColors.textSecondary)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }

            Spacer()

            if showPlan {
                PrimaryButton(lang == .japanese ? "プランを開始する" : "Start my plan", icon: "arrow.right") {
                    // 🔴 2026-08-06 審査リジェクト対応 (Guideline 5.6.3): オンボーディング中の
                    // 評価依頼は禁止。ここは 2026-07-19 に .plan ステップごとフローから外れて
                    // 死んでいるコードだが、将来復活させた時に同じ違反を再導入しないよう
                    // requestReview() の呼び出しを撤去する
                    onContinue()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .transition(.opacity)
            }
        }
        .onAppear { revealSequentially() }
    }

    /// チェックが 600ms 間隔で1つずつ✓になり (計~2.5s)、完了後にプランを表示
    private func revealSequentially() {
        guard revealedChecks == 0 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            revealedChecks = checkItems.count
            showPlan = true
            return
        }
        for i in 0..<checkItems.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.6) {
                revealedChecks = i + 1
                QuizHaptics.light()
            }
        }
        let total = 0.4 + Double(checkItems.count) * 0.6 + 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + total) {
            withAnimation(.easeOut(duration: 0.45)) { showPlan = true }
        }
    }
}
