//
//  AppSelectCard.swift
//  AppBlocker
//
//  Shared "ブロックするアプリ" ("Apps to block") card (redesign that unifies the 3 modes, 2026-07-15).
//  Placed with the same look and in the same position (right above the CTA / at the bottom) in all
//  modes: timer/schedule/location.
//  Previously the 3 modes each had a pill with a different design and were inconsistent (real-device
//  feedback).
//

import SwiftUI
import FamilyControls

struct AppSelectCard: View {
    let selection: FamilyActivitySelection
    let lang: AppLanguage
    /// Extra line (e.g. "全スケジュール共通" ("Shared by all schedules")). Hidden if nil
    var subtitle: String? = nil
    let action: () -> Void

    private var totalCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AppColors.secondaryBackground)
                        .frame(width: 34, height: 34)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(lang == .japanese ? "ブロックするアプリ" : "Apps to block") // Text waiting for user review
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text(trailingText)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(totalCount > 0 ? AppColors.textSecondary : AppColors.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trailingText: String {
        if totalCount > 0 {
            return lang == .japanese ? "\(totalCount)個" : "\(totalCount)"
        }
        return lang == .japanese ? "選択する" : "Select" // Text waiting for user review
    }
}
