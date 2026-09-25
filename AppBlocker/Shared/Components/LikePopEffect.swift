//
//  LikePopEffect.swift
//  AppBlocker
//
//  いいねのポップアニメーション (2026-07-25 実機FB「いいねをかっこよく」)。
//  TikTok/Twitter 系の定番モーションを依存ライブラリなしで実装:
//    1. 押した瞬間にハートが沈み込み (0.55x、アニメなしで即時)
//    2. スプリングで 1.0x に跳ね上がる
//    3. 同時に赤の小パーティクル7粒が放射して 0.5s で消える
//  いいね解除 (true→false) では何も出さない (色が戻るだけ)。
//  対象はハートアイコン単体 (数十pt) なので scaleEffect のコストは無視できる
//  (S16 の「巨大Viewへの scaleEffect 禁止」ルールには抵触しない)。
//

import SwiftUI

struct LikePopEffect: ViewModifier {

    let isLiked: Bool
    /// パーティクルの飛距離 (ハートのサイズに合わせて呼び出し側が調整)
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
                // 沈み込みはアニメなしで即時に (経過が見えると鈍く感じる)
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

/// 1回ぶんの放射パーティクル。出現時に外へ飛んで消え、親がトークンごと破棄する
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
    /// いいねボタンのハートに付ける (isLiked が false→true になった瞬間に発火)
    func likePopEffect(isLiked: Bool, particleRadius: CGFloat = 22) -> some View {
        modifier(LikePopEffect(isLiked: isLiked, particleRadius: particleRadius))
    }
}
