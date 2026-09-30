//
//  KeyboardDismissTap.swift
//  AppBlocker
//
//  App-wide "tap anywhere other than a text input to close the keyboard" (2026-07-25 real-device
//  feedback: in inputs such as the place name, the keyboard could not be closed and the only option
//  was to scroll to the save button).
//  Adding onTapGesture per screen misses some screens, so this uses the standard UIKit approach of
//  adding one UITapGestureRecognizer to the key window to cover everything at once.
//
//  - cancelsTouchesInView = false: taps on buttons etc. pass through as is (not stolen)
//  - shouldRecognizeSimultaneouslyWith = true: coexists with SwiftUI gestures
//  - shouldReceive touch: does not fire for taps on the text input view itself (moving the cursor, etc.)
//

import UIKit

enum KeyboardDismissTap {

    private static var installed = false

    /// Add exactly one tap detector to the key window. If the window does not exist yet, wait a little and
    /// retry
    static func installIfNeeded(retriesLeft: Int = 5) {
        guard !installed else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                installIfNeeded(retriesLeft: retriesLeft - 1)
            }
            return
        }

        let tap = UITapGestureRecognizer(
            target: Coordinator.shared,
            action: #selector(Coordinator.dismissKeyboard)
        )
        tap.cancelsTouchesInView = false
        tap.delegate = Coordinator.shared
        window.addGestureRecognizer(tap)
        installed = true
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        static let shared = Coordinator()

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Do not close on taps on a text input view (or its internals).
            // The backing view class names of SwiftUI's TextField/TextEditor contain
            // TextField/TextView/TextInput/TextLayout, so the name is checked too
            var view: UIView? = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                let name = String(describing: type(of: current))
                if name.contains("TextField") || name.contains("TextView")
                    || name.contains("TextInput") || name.contains("TextLayout") {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}
