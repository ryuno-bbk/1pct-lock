//
//  AppSelectCard.swift
//  AppBlocker
//
//  「ブロックするアプリ」共通カード (3モード統一リデザイン 2026-07-15)。
//  タイマー/スケジュール/位置情報の全モードで同じ見た目・同じ位置 (CTA 直上/最下部) に置く。
//  以前は 3 モードがそれぞれ別デザインのピルを持っていて不統一だった (実機FB)。
//

import SwiftUI
import FamilyControls

struct AppSelectCard: View {
    let selection: FamilyActivitySelection
    let lang: AppLanguage
    /// 補足行 (例: 「全スケジュール共通」)。nil なら非表示
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
                    Text(lang == .japanese ? "ブロックするアプリ" : "Apps to block") // 文言はユーザー添削待ち
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
        return lang == .japanese ? "選択する" : "Select" // 文言はユーザー添削待ち
    }
}
