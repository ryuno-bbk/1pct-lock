//
//  OnboardingPlan.swift
//  AppBlocker
//
//  ⚠️ Not used in the flow right now (the .plan step was removed from onboarding by user decision
//  2026-07-19). The "plan" concept does not fit this app, so the flow goes straight on. There is an
//  idea to rebuild it later as a page "suggest a schedule first → the user adjusts it → enabling it
//  is Pro", so it is kept as the base for that.
//
//  (Old role) Diagnostic onboarding PHASE 3: generate plan → show personal plan → ask for a review.
//

import SwiftUI
import StoreKit

struct PlanBuildingStepView: View {
    /// Dream (can be empty). If empty, the dream row is not shown
    let dreamText: String
    /// Choices from Q5 (array of display names). If empty, generic text
    let wastedAppNames: [String]
    /// Answer to Q3 (to calculate the recommended lock time). If nil, fixed at 2h
    let dailyHours: QuizDailyHours?
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    // @Environment(\.requestReview) was removed on 2026-08-06 (Guideline 5.6.3).
    // Do not ask for a rating during onboarding

    @State private var revealedChecks = 0
    @State private var showPlan = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// Recommended lock time = about 35% of the self-reported time, rounded to 1-4h
    private var recommendedLockHours: Int {
        let h = dailyHours?.medianHours ?? 5
        return min(max(Int((h * 0.35).rounded()), 1), 4)
    }

    /// Hours won back per year
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
                    // 🔴 Fix for the 2026-08-06 App Review rejection (Guideline 5.6.3): asking for a rating during
                    // onboarding is forbidden. This is dead code, removed from the flow together with the .plan step on
                    // 2026-07-19, but the requestReview() call is removed so the same violation is not reintroduced if
                    // it is brought back in the future
                    onContinue()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .transition(.opacity)
            }
        }
        .onAppear { revealSequentially() }
    }

    /// Checks turn into ✓ one at a time at 600ms intervals (about 2.5s total), then the plan is shown
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
