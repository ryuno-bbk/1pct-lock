//
//  OnboardingSignature.swift
//  AppBlocker
//
//  Signature step (added 2026-07-17, right after dream and before nameInput).
//  A "ritual" screen that shows the declared goal text again and has the user sign it with a finger.
//  Similar in idea to the old CommitmentStepView (left unused in OnboardingView.swift), but that one
//  is a leftover from when the dream declaration itself was not implemented yet. This one is meant to
//  make the user engrave the commitment again after the dream is already fixed (sunk cost
//  reinforcement).
//

import SwiftUI

/// Point list for one signature stroke
private typealias SignatureStroke = [CGPoint]

struct SignatureStepView: View {
    /// Goal text declared in DreamStepView. Shown again inside quotation brackets
    let dreamText: String
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var strokes: [SignatureStroke] = []
    @State private var currentStroke: SignatureStroke = []

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// true if at least one stroke has been drawn (a finished stroke, or a stroke in progress that has moved
    /// 2 or more points)
    private var hasSignature: Bool {
        !strokes.isEmpty || currentStroke.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            // 2026-07-17 feedback round 2: dropped the "make a vow" direction; the goal is the main element, placed
            // large at the top, and the instruction is simply "please sign" (user-specified)

            // Text waiting for user review ("あなたの目標" ("Your goal") is the same word as on the Shield / session
            // end screen)
            Text(lang == .japanese ? "あなたの目標" : "Your goal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textTertiary)

            Text("「\(dreamText)」")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .padding(.horizontal, 28)
                .padding(.top, 10)

            // Text waiting for user review
            Text(lang == .japanese ? "この目標にサインしてください" : "Sign your name to it.")
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary)
                .padding(.top, 22)

            Spacer()

            signatureCanvas
                .padding(.horizontal, 24)

            Spacer()

            PrimaryButton(
                // 2026-07-17 feedback round 2: back to the signing direction // Text waiting for user review
                lang == .japanese ? "サインして進む" : "Sign and continue",
                icon: "checkmark",
                isDisabled: !hasSignature
            ) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
    }

    private var signatureCanvas: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .frame(height: 180)

            Canvas { context, size in
                // Baseline (a dotted line to make it look like a signature field)
                var baseline = Path()
                let baselineY = size.height - 36
                baseline.move(to: CGPoint(x: 24, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width - 24, y: baselineY))
                context.stroke(
                    baseline,
                    with: .color(AppColors.textTertiary.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )

                // Finished strokes + the stroke being drawn
                for stroke in strokes + [currentStroke] {
                    guard let first = stroke.first else { continue }
                    var path = Path()
                    path.move(to: first)
                    for point in stroke.dropFirst() {
                        path.addLine(to: point)
                    }
                    context.stroke(
                        path,
                        with: .color(AppColors.textPrimary),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .frame(height: 180)
            .contentShape(Rectangle())
            // minimumDistance: 0 picks up the very first point immediately. The parent's screen-transition swipe
            // etc. only exist outside this card area, so they do not interfere
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        currentStroke.append(value.location)
                    }
                    .onEnded { _ in
                        if !currentStroke.isEmpty {
                            strokes.append(currentStroke)
                            currentStroke = []
                        }
                    }
            )
            .overlay(alignment: .center) {
                // Hint text that disappears once you start writing
                if !hasSignature {
                    // Text waiting for user review
                    Text(lang == .japanese ? "ここに指でサイン" : "Sign here with your finger")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                        .allowsHitTesting(false)
                }
            }

            // Redo (shown only when there is a signature)
            if hasSignature {
                Button {
                    strokes.removeAll()
                    currentStroke = []
                } label: {
                    // Text waiting for user review
                    Text(lang == .japanese ? "書き直す" : "Clear")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                }
                .padding(10)
            }
        }
        // The signature image itself is not saved (a ritual where the act itself is the purpose).
        // If we want to use it later for a thumbnail etc., ImageRenderer(content: signatureCanvas) can
        // export the Canvas (see the other save logic around DreamStepView)
    }
}
