//
//  NavigationSwipeBack.swift
//  AppBlocker
//
//  2 improvements to swipe back:
//  1. Replace the delegate: "always allow swipe back if there are 2 or more screens in the stack"
//     (so edge-swipe does not die even with a custom bar setup)
//  2. Full width: the OS standard interactivePopGestureRecognizer only responds at the left edge of the
//     screen (~20pt). Forward its internal targets ("targets") to a full-width UIPanGestureRecognizer
//     so a right swipe from the middle of the screen also goes back to the previous screen.
//     Guards against misfires:
//       - Does not fire at the root (viewControllers.count == 1)
//       - Only allows a start that is rightward and mostly horizontal (|vx| > |vy|)
//         → coexists with the vertically scrolling feed
//       - If there is a "horizontally scrollable UIScrollView" under the touch point, it yields
//         → prevents full-width back from fighting with paging back in multi-image carousels (TabView
//           .page) or horizontal thumbnail scrolling. Even in this case, the edge-swipe at the left
//           edge of the screen still works as before, so the way back is not lost
//

import UIKit

private let fullWidthBackGestureName = "arete.fullWidthBackGesture"

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        installFullWidthBackGesture()
    }

    /// Forward the internal targets of interactivePopGestureRecognizer to a full-width pan.
    /// "targets" is a private key, but this is a widely used pattern as the only lightweight way
    /// to keep using the OS implementation of the transition animation.
    private func installFullWidthBackGesture() {
        guard view.gestureRecognizers?.contains(where: { $0.name == fullWidthBackGestureName }) != true,
              let edgeGesture = interactivePopGestureRecognizer,
              let targets = edgeGesture.value(forKey: "targets") else { return }

        let pan = UIPanGestureRecognizer()
        pan.name = fullWidthBackGestureName
        pan.setValue(targets, forKey: "targets")
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1 else { return false }

        // The full-width pan only picks up "rightward, mostly horizontal" movement (does not interfere with
        // vertical scrolling)
        if gestureRecognizer.name == fullWidthBackGestureName,
           let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: pan.view)
            guard velocity.x > 0 && abs(velocity.x) > abs(velocity.y) else { return false }

            // If the touch point is over a horizontally scrollable area (carousel etc.),
            // prefer paging back and do not fire full-width back (edge-swipe survives as a separate recognizer)
            let location = pan.location(in: view)
            if let hitView = view.hitTest(location, with: nil),
               hasHorizontallyScrollableAncestor(of: hitView) {
                return false
            }
            return true
        }

        return true
    }

    /// Walk up from hitView to our own view; true if a horizontally scrollable UIScrollView is in between.
    /// (contentSize.width > bounds.width = there is something that actually moves horizontally. The
    /// vertical feed's UIScrollView has matching widths, so it does not qualify)
    private func hasHorizontallyScrollableAncestor(of hitView: UIView) -> Bool {
        var current: UIView? = hitView
        while let v = current, v !== view {
            if let scroll = v as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                return true
            }
            current = v.superview
        }
        return false
    }
}
