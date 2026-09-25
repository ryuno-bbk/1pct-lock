//
//  SwipeRevealDelete.swift
//  AppBlocker
//
//  左スワイプで右側に赤い削除ボタンを出す行ラッパー (2026-07-15 実機FB)。
//  List 外 (ScrollView 内の VStack) で使うため swipeActions は使えず、自前実装。
//  削除の確認 (alert) は呼び出し側の onDelete で行うこと — ここでは出さない。
//

import SwiftUI

struct SwipeRevealDelete<Content: View>: View {
    let onDelete: () -> Void
    /// 行本体のタップ (閉じている時のみ発火)。
    /// ⚠️ content の内側に Button を置かないこと: Button は simultaneousGesture の
    /// ドラッグと同時にタップ成立してしまい、スワイプした瞬間に画面遷移する誤爆になる
    /// (2026-07-15 実機FB)。TapGesture はスワイプ距離で自然に失敗するのでこちらで受ける
    var onTap: (() -> Void)? = nil
    /// スワイプでの削除を封じる。遮断が走っている予定を消させないために使う
    /// (削除も「今の遮断から逃げる」経路になるため。2026-08-28)。
    /// ⚠️ onTap は生かしたままにする — 触れなくするのではなく、行き先を変えるため
    var isSwipeDisabled: Bool = false
    @ViewBuilder let content: Content

    @State private var offsetX: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 68

    var body: some View {
        ZStack(alignment: .trailing) {
            // 背面: 削除ボタン (開いている時だけ触れる)
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
                    guard !isOpen else { return } // 開いている時は overlay が閉じる役を持つ
                    onTap?()
                }
                // 開いた状態では本体の上に透明レイヤーを被せ、タップ=閉じるだけにする
                // (誤操作防止。allowsHitTesting(false) だと閉じるタップ自体も死ぬためこの方式)。
                // ⚠️ overlay は必ず .offset より前に付けること: offset はレイアウト枠を動かさないため、
                // 後に付けると開いた時もレイヤーが元の位置 (=ゴミ箱の上) に残り、
                // 削除ボタンのタップを食って「閉じるだけで消せない」バグになる (2026-07-15 実機FB)
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offsetX)
                // 縦スクロールと共存させるため、ある程度動いてから反応させる。
                // simultaneousGesture ではなく highPriority にすると縦スクロールを食うので不可
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local)
                        .onChanged { value in
                            guard !isSwipeDisabled else { return }
                            // 横優位のドラッグだけ拾う (縦スクロールを妨げない)
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
