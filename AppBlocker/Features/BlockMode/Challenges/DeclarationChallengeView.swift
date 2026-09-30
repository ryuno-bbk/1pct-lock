//
//  DeclarationChallengeView.swift
//  AppBlocker
//
//  Unlock challenge "次にやることを書く" ("Write what you will do next") = implementation
//  intention (if-then plan).
//
//  Basis: meta-analysis by Gollwitzer & Sheeran (2006), d=0.65 (94 studies).
//  The 2024 update covers 642 studies. The best-proven technique for behavior change.
//
//  🔴 What it asks is the whole feature:
//    Ask not "what will you do after unlocking" but "**what will you do when the break is over**".
//    The honest answer to the first is "scroll", so there is no point asking it (2026-08-29 user
//    feedback). Accept the urge to scroll, and make the user put the work after it.
//
//  ⚠️ Always keep the TextField inside this small View.
//     Placing it directly in a large View makes rendering heavy on a real device
//     (feedback_swiftui_performance).
//

import SwiftUI

struct DeclarationChallengeView: View {

    let lang: AppLanguage
    /// Finished writing, go on to unlock
    let onCompleted: () -> Void
    /// Give up and go back to the interruption screen
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var ja: Bool { lang == .japanese }

    /// Do not allow only whitespace. No length required (the act of writing is the point)
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
            // Make it ready for input the moment it opens (one less tap)
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

    // ⚠️ Wording is waiting for the user's review
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
            Text(ja ? "ロックを解除する" : "Unlock") // Wording is waiting for the user's review
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
