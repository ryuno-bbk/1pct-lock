//
//  PreparingLockOverlay.swift
//  AppBlocker
//
//  A "preparing" overlay shown for at least ~1.8s right after a lock starts.
//  2 purposes:
//   1. Ease the freeze that happens when navigating home right after the shield is applied (blocks
//      input during the volatile window)
//   2. Turn the feeling of waiting into "it's preparing" feedback
//  Display is controlled by the BlockingService.isPreparingLock flag.
//  Fully monochrome (follows AppColors, no gold).
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
        // The overlay itself takes the hit testing and blocks input to the UI below (prevents a navigation race)
        .contentShape(Rectangle())
        .transition(.opacity)
    }

    private var label: String {
        lang == .japanese ? "ロックを準備中…" : "Preparing your lock…"
    }
}
