//
//  FeedInteractionViews.swift
//  AppBlocker
//
//  Small interaction subviews shared by the swipe feed cards (FeedItemCard / FilteredFeedCard /
//  AuthorFeedCard).
//  - FollowPlusButton: follow button overlaid under the avatar (press → switches to a check →
//    fades out)
//  - DoubleTapHeartBurst: one heart particle that floats up from the double-tapped point
//
//  Attaching scaleEffect directly to a huge View is forbidden, so both complete their animation
//  inside these small independent subviews (lesson from the S16 real device 10fps incident).
//

import SwiftUI

// MARK: - Follow Plus Button (for the overlay under the avatar)

/// Round follow badge overlaid on the avatar.
/// The old design (ink fill + white border) blended into white backgrounds and was disliked, so it
/// is inverted: fill = textPrimary (off-white), icon/outer ring painted with background (ink).
/// On press: haptic + the icon switches to checkmark (symbolEffect) → held 0.9s →
/// fades out with opacity + scale over 0.25s and disappears (opacity only with reduceMotion).
/// The caller must include this View in the tree only while `showFollowBadge` is false
/// (when it reappears after an unfollow, it is recreated as a fresh instance and its state resets
/// naturally).
struct FollowPlusButton: View {
    var size: CGFloat = 22
    let onTap: () -> Void

    @State private var didTap = false
    @State private var isHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Keep the visible frame/position as is, and widen only the hit area beyond the circle's diameter
    /// to secure a tap target equivalent to 44pt (following the S16 lesson of not attaching scaleEffect
    /// directly to a huge View, this is done entirely inside this badge subview).
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

// MARK: - Double Tap Heart Burst (one heart that floats up from the double-tap position)

/// Like particle that appears only at the double-tapped point.
/// The caller handles multiple simultaneous bursts with an array managed by UUID per point, and
/// removes each from the array after the animation ends (about 0.65s).
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

/// One element for managing the double-tap heart array (tap point + identifier)
struct HeartBurstToken: Identifiable {
    let id = UUID()
    let position: CGPoint
}
