//
//  KeyboardDismissTap.swift
//  AppBlocker
//
//  アプリ全域の「テキスト入力以外をタップしたらキーボードを閉じる」(2026-07-25 実機FB:
//  場所の名前入力などでキーボードが閉じられず、保存ボタンまでスクロールするしかなかった)。
//  画面ごとに onTapGesture を仕込む方式は漏れが出るため、key window に
//  UITapGestureRecognizer を1本挿す UIKit の定石で一括対応する。
//
//  - cancelsTouchesInView = false: ボタン等のタップはそのまま素通しする (奪わない)
//  - shouldRecognizeSimultaneouslyWith = true: SwiftUI 側のジェスチャと共存する
//  - shouldReceive touch: テキスト入力ビュー自身へのタップ (カーソル移動など) では発火しない
//

import UIKit

enum KeyboardDismissTap {

    private static var installed = false

    /// key window にタップ検知を1本だけ挿す。ウィンドウ未生成なら少し待って再試行する
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
            // テキスト入力ビュー (とその内部) へのタップでは閉じない。
            // SwiftUI の TextField/TextEditor はバッキングビューのクラス名に
            // TextField/TextView/TextInput/TextLayout を含むため名前でも判定する
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
