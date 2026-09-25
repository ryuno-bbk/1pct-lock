//
//  OnboardingSignature.swift
//  AppBlocker
//
//  署名ステップ (2026-07-17 追加、dream の直後・nameInput の前)。
//  宣言した目標文をもう一度見せた上で、指で署名させる「儀式」の画面。
//  旧 CommitmentStepView (OnboardingView.swift に未使用のまま残置) と近い発想だが、
//  あちらは夢の宣言そのものが未実装だった頃の名残。こちらは夢が既に確定した後に
//  再度コミットメントを刻ませる位置づけ (サンクコスト強化)。
//

import SwiftUI

/// 署名ストローク1本分の点列
private typealias SignatureStroke = [CGPoint]

struct SignatureStepView: View {
    /// DreamStepView で宣言した目標文。鍵括弧書きで再掲する
    let dreamText: String
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var strokes: [SignatureStroke] = []
    @State private var currentStroke: SignatureStroke = []

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// 1画以上書いていれば true (ストローク確定済み、またはドラッグ中で2点以上動いている)
    private var hasSignature: Bool {
        !strokes.isEmpty || currentStroke.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            // 2026-07-17 第2FB: 「誓いを立てる」路線をやめ、目標を主役として上に大きく置き、
            // 指示は素直に「サインしてください」にする (ユーザー指定)

            // 文言はユーザー添削待ち (「あなたの目標」は Shield / セッション終了画面と同じ語)
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

            // 文言はユーザー添削待ち
            Text(lang == .japanese ? "この目標にサインしてください" : "Sign your name to it.")
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary)
                .padding(.top, 22)

            Spacer()

            signatureCanvas
                .padding(.horizontal, 24)

            Spacer()

            PrimaryButton(
                // 2026-07-17 第2FB: サイン路線に戻す // 文言はユーザー添削待ち
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
                // ベースライン (署名欄らしさを出す点線)
                var baseline = Path()
                let baselineY = size.height - 36
                baseline.move(to: CGPoint(x: 24, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width - 24, y: baselineY))
                context.stroke(
                    baseline,
                    with: .color(AppColors.textTertiary.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )

                // 確定済みストローク + 描画中のストローク
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
            // minimumDistance: 0 で描き始めの1点目から即座に拾う。親の画面遷移スワイプ等は
            // このカード領域の外側にしかないため干渉しない
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
                // 書き始めたら消えるヒント文字
                if !hasSignature {
                    // 文言はユーザー添削待ち
                    Text(lang == .japanese ? "ここに指でサイン" : "Sign here with your finger")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                        .allowsHitTesting(false)
                }
            }

            // 書き直す (署名がある時だけ表示)
            if hasSignature {
                Button {
                    strokes.removeAll()
                    currentStroke = []
                } label: {
                    // 文言はユーザー添削待ち
                    Text(lang == .japanese ? "書き直す" : "Clear")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                }
                .padding(10)
            }
        }
        // 署名画像そのものの保存はしない (行為そのものが目的の儀式)。
        // 将来サムネイル等で使いたくなった場合は ImageRenderer(content: signatureCanvas) で
        // Canvas を書き出せる (DreamStepView 周辺の他の保存処理を参考に)
    }
}
