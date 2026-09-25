//
//  OnboardingModeration.swift
//  AppBlocker
//
//  診断オンボーディング PHASE 0.5: モデレーションポリシー。
//  フィードプレビュー (「あなたを高める投稿だけが流れる」) の直後に置き、
//  「こういう投稿は流れてこない / 削除される」を実例で見せる。
//  1% が「規律のSNS」であること (= 誘惑・自堕落コンテンツを弾く) をオンボ段階で宣言し、
//  期待値を揃える + ブランドの厳格さを印象づける。
//  画像はテキスト焼き込み済み (OnboardingFeedAssets.moderate)。無ければグラデーション。
//

import SwiftUI

struct ModerationPolicyStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// カルーセルのカード幅 (画面の58%)。2:3 アスペクトで高さは自動 (幅×1.5)。
    /// 58% = iPhone SE でも カード高 + 見出し + CTA が収まる上限付近
    private var cardWidth: CGFloat { UIScreen.main.bounds.width * 0.58 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 64)

            // 2026-07-25 FB: タイトル/サブタイトル/キャプションの行間がでかすぎ → spacing を詰める。
            // 強調行の余分な top padding も撤去して3行を均等な近さに
            VStack(spacing: 5) {
                // 2026-07-29 ユーザー指示: ライブ審査 (合格も見せる) ページになったため
                // 「これらは流れてこない」→「AIがコンテンツを監査している」が伝わるタイトルへ
                Text(lang == .japanese ? "全ての投稿をAIが審査する" : "Every post is screened by AI") // 文言はユーザー添削待ち
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(lang == .japanese
                     ? "酒、夜更かし、ジャンクフード、遊び、エンターテイメント"
                     : "Booze, late nights, junk food, games, entertainment")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // AI モデレーションの明言をこのページの強調行にする (2026-07-17 ユーザーFB第2弾:
                // 「あなたの脳を腐らせない」単体行は削除し、こちらを強調に昇格) // 文言はユーザー添削待ち
                Text(lang == .japanese
                     ? "脳を腐らせる投稿はAIと運営が弾く"
                     : "AI and moderators remove brain-rot posts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            Spacer().frame(height: 8)

            // ライブ審査演出 (2026-07-29 実機FB: フック画面からここへ移設+拡大)。
            // 「これらは流れてこない」の主張を、投稿がスキャン→判定→弾かれる出来事として見せる。
            // 旧・横スクロールカルーセル (9枚) は JudgmentFeedView に置き換え
            // (ロールバック用に ModerationCard は残置)
            JudgmentFeedView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer().frame(height: 8)

            PrimaryButton(lang == .japanese ? "わかった、始める" : "Got it — let's go", icon: "arrow.right") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

/// 削除対象カード: 画像を暗く落とし、赤い「削除」タグ + 斜線で「弾かれる」を視覚化
private struct ModerationCard: View {
    let imageName: String
    let lang: AppLanguage

    var body: some View {
        ZStack {
            Group {
                if UIImage(named: imageName) != nil {
                    Color.clear.overlay(
                        Image(imageName).resizable().aspectRatio(contentMode: .fill)
                    )
                } else {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipped()
            .saturation(0.5)
            .overlay(Color.black.opacity(0.45))

            // 赤い「削除」バッジ
            VStack {
                HStack {
                    Spacer()
                    Text(lang == .japanese ? "削除" : "Removed")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppColors.error.opacity(0.9)))
                        .padding(8)
                }
                Spacer()
            }
        }
        .aspectRatio(2.0/3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.error.opacity(0.35), lineWidth: 1)
        )
    }
}
