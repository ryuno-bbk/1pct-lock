//
//  SafeAreaCollapseFix.swift
//  AppBlocker
//
//  Permanent workaround for real device feedback #6 (header cut-in bug).
//
//  Confirmed facts (2026-07-25, measured from DebugSafeAreaProbe screenshots):
//    On screens pushed from MyProfileView (transparent toolbar + ignoresSafeArea(.top) hero)
//    (post feed/notifications), the top safe area + nav bar insets occasionally disappear
//    completely, and the content is drawn from the very top of the screen (y:0 / win:62: UIKit keeps
//    the correct value).
//    The trigger is suspected to be right after the post sheet closes. It is a breakdown of SwiftUI's
//    internal bar coordination, and we measured that it is not fixed even with an explicit
//    toolbarBackground(.visible).
//
//  Fix: only when a "mismatch between the correct safe area reported by UIKit and the measured
//  SwiftUI layout" is detected, explicitly add back what was lost (status bar + standard nav bar
//  height 44pt).
//  When normal (minY > 0) it does nothing, so false triggers structurally cannot happen.
//  Included in Release too (separate from the DebugSafeAreaProbe instrumentation).
//

import SwiftUI

struct SafeAreaCollapseFix: ViewModifier {

    @State private var topFix: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, topFix)
            .background(
                GeometryReader { geo in
                    let minY = geo.frame(in: .global).minY
                    Color.clear
                        .onAppear { update(minY: minY) }
                        .onChange(of: minY) { _, newValue in update(minY: newValue) }
                }
            )
    }

    private func update(minY: CGFloat) {
        let winTop = Self.windowSafeAreaTop()
        // minY ≈ 0 = "a screen that should sit under the nav bar is at the very top of the screen" = inset
        // collapse. The correction is added to safeAreaPadding (inside), not the outer frame, so minY stays 0
        // after correction and detection does not oscillate. When the collapse recovers naturally (minY > 0),
        // the correction is removed immediately
        let collapsed = minY < 1 && winTop > 1
        let newFix: CGFloat = collapsed ? winTop + 44 : 0
        if topFix != newFix {
            topFix = newFix
            print("🩹 SafeAreaCollapseFix: topFix=\(newFix) (minY=\(minY), win=\(winTop))")
        }
    }

    /// Measured safe area on the UIKit side (a reference value not affected by the SwiftUI collapse)
    private static func windowSafeAreaTop() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
}

extension View {
    /// Real device feedback #6: attach to the root of screens pushed from MyProfileView
    func safeAreaCollapseFix() -> some View {
        modifier(SafeAreaCollapseFix())
    }
}
