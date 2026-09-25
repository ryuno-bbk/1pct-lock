//
//  FeedInteractionViews.swift
//  AppBlocker
//
//  スワイプフィード系カード (FeedItemCard / FilteredFeedCard / AuthorFeedCard) 共通の
//  インタラクション用小型サブビュー。
//  - FollowPlusButton: アバター下に重ねるフォローボタン (押下 → チェックへ切替 → フェードアウト)
//  - DoubleTapHeartBurst: ダブルタップした座標から浮かび上がるハートパーティクル 1 個分
//
//  巨大 View への scaleEffect 直付けは禁止のため、どちらもこの独立した小さな subview 内で
//  アニメーションを完結させる (S16 実機 10fps 事故の教訓)。
//

import SwiftUI

// MARK: - Follow Plus Button (アバター下オーバーレイ用)

/// アバターに重ねる円形フォローバッジ。
/// 旧デザイン (墨塗り+白枠) は白背景と同化して不評だったため反転:
/// fill = textPrimary (オフホワイト)、アイコン/外周リングは background (墨) で塗る。
/// 押すと haptic + アイコンを checkmark に切替 (symbolEffect) → 0.9 秒保持 →
/// 0.25 秒で opacity + scale フェードアウトして消える (reduceMotion 時は opacity のみ)。
/// 呼び出し側は `showFollowBadge` が false の間だけこの View をツリーに含めること
/// (フォロー解除で再表示される時に真新しいインスタンスとして再生成され、状態が自然にリセットされる)。
struct FollowPlusButton: View {
    var size: CGFloat = 22
    let onTap: () -> Void

    @State private var didTap = false
    @State private var isHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 見た目のフレーム/位置はそのままに、タップ判定領域だけ円の直径を広げて
    /// 44pt 相当のタップターゲットを確保する (S16: 巨大 View への scaleEffect 直付け禁止の
    /// 教訓に倣い、このバッジ subview 内だけで完結させる)。
    private struct ExpandedHitArea: Shape {
        var inset: CGFloat
        func path(in rect: CGRect) -> Path {
            Circle().path(in: rect.insetBy(dx: -inset, dy: -inset))
        }
    }

    var body: some View {
        Button {
            guard !didTap else { return }

            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            withAnimation(.easeOut(duration: 0.2)) {
                didTap = true
            }

            onTap()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if reduceMotion {
                    isHidden = true
                } else {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isHidden = true
                    }
                }
            }
        } label: {
            Image(systemName: didTap ? "checkmark" : "plus")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(AppColors.background)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(AppColors.textPrimary))
                .overlay(Circle().stroke(AppColors.background, lineWidth: 2.5))
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(ExpandedHitArea(inset: 11))
        .disabled(didTap)
        .scaleEffect((isHidden && !reduceMotion) ? 0.5 : 1.0)
        .opacity(isHidden ? 0 : 1.0)
        .allowsHitTesting(!didTap)
    }
}

// MARK: - Double Tap Heart Burst (ダブルタップ位置から浮かぶハート 1 個)

/// ダブルタップした座標のみに現れる、いいねパーティクル。
/// 呼び出し側は座標ごとに UUID 管理した配列で複数同時発生に対応し、
/// アニメーション終了 (約 0.65 秒) 後に配列から取り除くこと。
struct DoubleTapHeartBurst: View {
    let position: CGPoint

    @State private var scale: CGFloat = 0
    @State private var yOffset: CGFloat = 0
    @State private var opacity: Double = 1

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 32))
            .foregroundColor(.red)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(x: position.x, y: position.y + yOffset)
            .allowsHitTesting(false)
            .onAppear { animate() }
    }

    private func animate() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            scale = 1.0
            withAnimation(.easeOut(duration: 0.35).delay(0.15)) {
                opacity = 0
            }
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            scale = 1.2
        }
        withAnimation(.easeOut(duration: 0.65)) {
            yOffset = -36
            opacity = 0
        }
    }
}

/// ダブルタップハート配列管理用の 1 要素 (タップ座標 + 識別子)
struct HeartBurstToken: Identifiable {
    let id = UUID()
    let position: CGPoint
}
