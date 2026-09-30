//
//  LikePopEffect.swift
//  AppBlocker
//
//  Like pop animation (2026-07-25 real device feedback "make likes look cool").
//  Implements the standard TikTok/Twitter-style motion with no dependency libraries:
//    1. The heart sinks the moment it is pressed (0.55x, immediately with no animation)
//    2. It springs back up to 1.0x
//    3. At the same time, 7 small red particles radiate out and disappear in 0.5s
//  Unliking (true→false) shows nothing (only the color changes back).
//  The target is just the heart icon (tens of pt), so the cost of scaleEffect is negligible
//  (does not violate the S16 rule "no scaleEffect on huge Views").
//

import SwiftUI

struct LikePopEffect: ViewModifier {

    let isLiked: Bool
    /// Particle travel distance (the caller adjusts it to the heart size)
    var particleRadius: CGFloat = 22

    @State private var popScale: CGFloat = 1
    @State private var burstTokens: [Int] = []
    @State private var burstSeq = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(popScale)
            .background {
                ZStack {
                    ForEach(burstTokens, id: \.self) { _ in
                        LikeBurstParticles(radius: particleRadius)
                    }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: isLiked) { _, nowLiked in
                guard nowLiked else { return }
                // The sink happens immediately with no animation (if you can see it progress, it feels sluggish)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { popScale = 0.55 }
                withAnimation(.interpolatingSpring(stiffness: 380, damping: 13)) {
                    popScale = 1.0
                }

                burstSeq += 1
                let token = burstSeq
                burstTokens.append(token)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    burstTokens.removeAll { $0 == token }
                }
            }
    }
}

/// Radiating particles for one burst. They fly out and vanish on appear, and the parent discards them
/// with the token
private struct LikeBurstParticles: View {

    let radius: CGFloat
    @State private var expand = false

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let angle = Double(i) / 7.0 * 2.0 * .pi - .pi / 2
                Circle()
                    .fill(Color.red)
                    .frame(width: 3.5, height: 3.5)
                    .offset(
                        x: expand ? cos(angle) * radius : 0,
                        y: expand ? sin(angle) * radius : 0
                    )
                    .opacity(expand ? 0 : 0.9)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { expand = true }
        }
    }
}

extension View {
    /// Attach to the heart of the like button (fires the moment isLiked goes false→true)
    func likePopEffect(isLiked: Bool, particleRadius: CGFloat = 22) -> some View {
        modifier(LikePopEffect(isLiked: isLiked, particleRadius: particleRadius))
    }
}
