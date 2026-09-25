//
//  PreparingLockOverlay.swift
//  AppBlocker
//
//  ロック開始直後に最低 ~1.8s 表示する「準備中」オーバーレイ。
//  目的は2つ:
//   1. shield 適用直後にホームへ遷移すると固まる症状の緩和 (揮発ウィンドウ中の操作を封じる)
//   2. 待たされる体感を「準備している」フィードバックに変える
//  BlockingService.isPreparingLock フラグで表示制御する。
//  完全モノクロ (AppColors 準拠、金色不使用)。
//

import SwiftUI

struct PreparingLockOverlay: View {
    let lang: AppLanguage

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColors.textPrimary)

                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
            }
        }
        // オーバーレイ自体がヒットテストを奪い、下の UI への操作を封じる (遷移レース防止)
        .contentShape(Rectangle())
        .transition(.opacity)
    }

    private var label: String {
        lang == .japanese ? "ロックを準備中…" : "Preparing your lock…"
    }
}
