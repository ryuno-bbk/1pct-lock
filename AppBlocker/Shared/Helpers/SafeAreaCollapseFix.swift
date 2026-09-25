//
//  SafeAreaCollapseFix.swift
//  AppBlocker
//
//  実機FB#6 (ヘッダー食い込みバグ) の恒久ワークアラウンド。
//
//  確定した事実 (2026-07-25、DebugSafeAreaProbe のスクショ実測):
//    MyProfileView (透過ツールバー + ignoresSafeArea(.top) ヒーロー) から push した画面
//    (投稿フィード/通知) で、まれに上セーフエリア+ナビバーのインセットが丸ごと消え、
//    コンテンツが画面最上端から描画される (y:0 / win:62 — UIKit は正しい値を保持している)。
//    トリガーは投稿シート閉鎖直後の疑い。SwiftUI 内部のバー連携の崩壊で、
//    toolbarBackground(.visible) 明示でも直らないことを実測済み。
//
//  対処: 「UIKit が報告する正しいセーフエリアと、SwiftUI レイアウトの実測値の食い違い」を
//  検知した時だけ、失われた分 (ステータスバー + ナビバー標準高 44pt) を明示的に補う。
//  正常時 (minY > 0) は何もしないため、誤発動は構造上起きない。
//  Release にも含める (計装 DebugSafeAreaProbe とは別物)。
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
        // minY ≈ 0 = 「ナビバーの下に置かれるべき画面がスクリーン最上端に居る」= インセット崩壊。
        // 補正は外側フレームでなく safeAreaPadding (内側) に足すため、補正後も minY は 0 のままで
        // 検知が振動しない。崩壊が自然回復 (minY > 0) したら補正も即座に外す
        let collapsed = minY < 1 && winTop > 1
        let newFix: CGFloat = collapsed ? winTop + 44 : 0
        if topFix != newFix {
            topFix = newFix
            print("🩹 SafeAreaCollapseFix: topFix=\(newFix) (minY=\(minY), win=\(winTop))")
        }
    }

    /// UIKit 側の実測セーフエリア (SwiftUI の崩壊の影響を受けない基準値)
    private static func windowSafeAreaTop() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
}

extension View {
    /// 実機FB#6: MyProfileView から push される画面の root に付ける
    func safeAreaCollapseFix() -> some View {
        modifier(SafeAreaCollapseFix())
    }
}
