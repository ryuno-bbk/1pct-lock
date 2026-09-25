//
//  NavigationSwipeBack.swift
//  AppBlocker
//
//  スワイプバックの改善 2 点:
//  1. delegate 差し替え: 「スタックに 2 画面以上あれば常にスワイプバックを許可」
//     (カスタムバー構成でも edge-swipe が死なないように)
//  2. 全幅化: OS 標準の interactivePopGestureRecognizer は画面左端 (~20pt) でしか
//     反応しない。その内部ターゲット ("targets") を全幅の UIPanGestureRecognizer に
//     転送し、画面中央からの右スワイプでも 1 つ前の画面へ戻れるようにする。
//     誤爆防止のガード:
//       - ルート (viewControllers.count == 1) では発火しない
//       - 右向き かつ 横優勢 (|vx| > |vy|) の開始のみ許可
//         → 縦スクロールフィードとは共存する
//       - タッチ位置の下に「横スクロール可能な UIScrollView」がある場合は譲る
//         → 複数枚カルーセル (TabView .page) やサムネ横スクロールのページ戻りと
//           全幅バックの取り合いを防ぐ。この場合も画面左端の edge-swipe は
//           従来どおり生きているので、戻る手段は失われない
//

import UIKit

private let fullWidthBackGestureName = "arete.fullWidthBackGesture"

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        installFullWidthBackGesture()
    }

    /// interactivePopGestureRecognizer の内部ターゲットを全幅パンへ転送する。
    /// "targets" は非公開キーだが、遷移アニメーションを OS 実装のまま使える
    /// 唯一の軽量な方法として広く使われているパターン。
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

        // 全幅パンは「右向き・横優勢」の動きだけ拾う (縦スクロールを邪魔しない)
        if gestureRecognizer.name == fullWidthBackGestureName,
           let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: pan.view)
            guard velocity.x > 0 && abs(velocity.x) > abs(velocity.y) else { return false }

            // タッチ位置が横スクロール可能な領域 (カルーセル等) の上なら、
            // ページ戻りを優先して全幅バックは発火させない (edge-swipe は別レコグナイザで生存)
            let location = pan.location(in: view)
            if let hitView = view.hitTest(location, with: nil),
               hasHorizontallyScrollableAncestor(of: hitView) {
                return false
            }
            return true
        }

        return true
    }

    /// hitView から自身の view まで遡り、横スクロール可能な UIScrollView が挟まっていれば true。
    /// (contentSize.width > bounds.width = 横に動く実体がある。縦フィードの UIScrollView は
    /// 幅が一致するので該当しない)
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
