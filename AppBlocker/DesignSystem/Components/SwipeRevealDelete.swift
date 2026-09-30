//
//  SwipeRevealDelete.swift
//  AppBlocker
//
//  Row wrapper that shows a red delete button on the right with a left swipe (2026-07-15 real device
//  feedback). Used outside List (a VStack inside a ScrollView), so swipeActions cannot be used; this
//  is a custom implementation.
//  The delete confirmation (alert) must be done in the caller's onDelete. It is not shown here.
//

import SwiftUI

struct SwipeRevealDelete<Content: View>: View {
    let onDelete: () -> Void
    /// Tap on the row body (fires only when closed).
    /// ⚠️ Do not put a Button inside content: a Button registers a tap at the same time as the
    /// simultaneousGesture drag, and misfires into a screen transition the moment you swipe
    /// (2026-07-15 real device feedback). TapGesture naturally fails with swipe distance, so taps are
    /// received with it here
    var onTap: (() -> Void)? = nil
    /// Blocks deleting by swipe. Used so a schedule whose blocking is running cannot be deleted
    /// (deleting is also a path to "escape the current blocking". 2026-08-28).
    /// ⚠️ Keep onTap alive: the goal is not to make it untouchable but to change where it leads
    var isSwipeDisabled: Bool = false
    @ViewBuilder let content: Content

    @State private var offsetX: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 68

    var body: some View {
        ZStack(alignment: .trailing) {
            // Behind: the delete button (touchable only when open)
            Button {
                close()
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AppColors.error))
            }
            .buttonStyle(.plain)
            .opacity(offsetX < -6 ? 1 : 0)

            content
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isOpen else { return } // When open, the overlay has the role of closing
                    onTap?()
                }
                // When open, put a transparent layer over the body so a tap only closes it
                // (prevents mistakes. With allowsHitTesting(false) the closing tap itself would also die, hence this
                // approach).
                // ⚠️ Always attach overlay before .offset: offset does not move the layout frame, so
                // if attached after, the layer stays at the original position (= over the trash) even when open,
                // eats the delete button's taps, and causes the bug "it only closes and cannot delete" (2026-07-15
                // real device feedback)
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offsetX)
                // To coexist with vertical scrolling, react only after it has moved a certain amount.
                // Using highPriority instead of simultaneousGesture would eat vertical scrolling, so it is not allowed
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local)
                        .onChanged { value in
                            guard !isSwipeDisabled else { return }
                            // Only pick up horizontally dominant drags (does not interfere with vertical scrolling)
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let base: CGFloat = isOpen ? -revealWidth : 0
                            let proposed = base + value.translation.width
                            offsetX = min(0, max(proposed, -revealWidth - 16))
                        }
                        .onEnded { value in
                            guard !isSwipeDisabled else { return }
                            guard abs(value.translation.width) > abs(value.translation.height) else {
                                snap()
                                return
                            }
                            if offsetX < -revealWidth * 0.5 {
                                open()
                            } else {
                                close()
                            }
                        }
                )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: offsetX)
    }

    private func open() {
        isOpen = true
        offsetX = -revealWidth
    }

    private func close() {
        isOpen = false
        offsetX = 0
    }

    private func snap() {
        if isOpen { open() } else { close() }
    }
}
