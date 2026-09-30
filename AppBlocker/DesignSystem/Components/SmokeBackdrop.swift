//
//  SmokeBackdrop.swift
//  AppBlocker
//
//  Moving smoke background (procedural FBM in HeroSmoke.metal, no video asset needed, infinite loop).
//  It was originally only for the onboarding hero screen (private inside OnboardingHook.swift), but
//  after 2026-07-30 real-device feedback "the official account background is way too boring" it is
//  also used for the official profile hero, so it was made a shared component (the implementation was
//  only moved, the visual parameters are unchanged).
//
//  Smoke has no shape outlines, so stutter is not noticeable even at 30fps updates (unlike hard edges
//  moving at constant speed), so it is throttled to 1/30 to save battery. With Reduce Motion it is
//  still smoke at time=0.
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

                // Faint glow in the center (adds depth under the smoke)
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
