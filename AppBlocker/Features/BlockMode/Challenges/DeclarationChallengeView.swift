//
//  DeclarationChallengeView.swift
//  AppBlocker
//
//  解除課題「次にやることを書く」= 実行意図 (if-then プラン)。
//
//  根拠: Gollwitzer & Sheeran (2006) のメタ分析で d=0.65 (94試験)。
//  2024年の更新版では642試験。行動変容で最も実証された技法。
//
//  🔴 聞く内容がこの機能の全て:
//    「解除したら何をするか」ではなく「**休憩が終わったら何をやるか**」を聞く。
//    前者の正直な答えは「スクロールする」で、聞く意味が無い (2026-08-29 ユーザー指摘)。
//    スクロールしたい衝動は認めた上で、その先に作業を置かせる。
//
//  ⚠️ TextField は必ずこの小さな View に閉じ込めておくこと。
//     大きな View に直接置くと実機で描画が重くなる (feedback_swiftui_performance)。
//

import SwiftUI

struct DeclarationChallengeView: View {

    let lang: AppLanguage
    /// 書き終えて解除に進む
    let onCompleted: () -> Void
    /// やめて中断画面に戻る
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var ja: Bool { lang == .japanese }

    /// 空白だけで通せないようにする。長さは求めない (書く行為自体が目的)
    private var canConfirm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                prompt
                field
                Spacer(minLength: 0)
                confirmButton
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
        }
        .task {
            // 開いた瞬間に入力できる状態にする (1タップ減らす)
            try? await Task.sleep(nanoseconds: 350_000_000)
            isFocused = true
        }
    }

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 42, height: 42)
            }
            Spacer()
        }
    }

    // ⚠️ 文言はユーザー添削待ち
    private var prompt: some View {
        VStack(spacing: 10) {
            Text(ja ? "休憩が終わったら、何をやりますか" : "After the break, what will you do?")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(ja ? "1行でいい" : "One line is enough")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.bottom, 28)
    }

    private var field: some View {
        TextField("", text: $text, axis: .vertical)
            .focused($isFocused)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.white)
            .tint(AppColors.accent)
            .lineLimit(1...4)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }

    private var confirmButton: some View {
        Button {
            isFocused = false
            onCompleted()
        } label: {
            Text(ja ? "ロックを解除する" : "Unlock") // 文言はユーザー添削待ち
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(canConfirm ? .black : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(canConfirm ? Color.white : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canConfirm)
    }
}
