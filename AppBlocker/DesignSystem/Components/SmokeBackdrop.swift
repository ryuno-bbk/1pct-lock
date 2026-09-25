//
//  SmokeBackdrop.swift
//  AppBlocker
//
//  動く煙の背景 (HeroSmoke.metal の手続き生成FBM、動画アセット不要・無限ループ)。
//  元はオンボーディングのヒーロー画面専用 (OnboardingHook.swift 内 private) だったが、
//  2026-07-30 実機FB「公式アカウントの背景がつまんなすぎる」で公式プロフィールヒーローにも
//  使うため共有コンポーネント化 (実装は移動のみ、見た目パラメータ不変)。
//
//  煙は形の輪郭を持たないため 30fps 更新でもカクつきは知覚されない (等速の硬いエッジ移動とは
//  違う) — バッテリー優先で 1/30 に間引く。Reduce Motion 時は time=0 の静止煙。
//

import SwiftUI

struct SmokeBackdrop: View {
    @State private var startDate = Date()

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppColors.background

                if reduceMotion {
                    smokeRect(size: geo.size, time: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        smokeRect(size: geo.size,
                                  time: context.date.timeIntervalSince(startDate))
                    }
                }

                // 中央のかすかなグロウ (煙の下地に奥行きを足す)
                RadialGradient(
                    colors: [Color(white: 0.10), .clear],
                    center: .center, startRadius: 10, endRadius: 340
                )
                .blendMode(.screen)
            }
        }
    }

    private func smokeRect(size: CGSize, time: TimeInterval) -> some View {
        Rectangle()
            .fill(Color.black)
            .colorEffect(ShaderLibrary.heroSmoke(
                .float2(Float(size.width), Float(size.height)),
                .float(Float(time))
            ))
    }
}
