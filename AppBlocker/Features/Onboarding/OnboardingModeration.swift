//
//  OnboardingModeration.swift
//  AppBlocker
//
//  Diagnostic onboarding PHASE 0.5: moderation policy.
//  Placed right after the feed preview ("only posts that lift you up appear"), it shows
//  with real examples "these kinds of posts never appear / get removed".
//  It declares at the onboarding stage that 1% is "a social network for discipline" (= it filters out
//  temptation and slacker content), to align expectations + make the brand's strictness stick.
//  The images already have the text baked in (OnboardingFeedAssets.moderate). If missing, a gradient.
//

import SwiftUI

struct ModerationPolicyStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// Card width of the carousel (58% of the screen). With a 2:3 aspect ratio the height is automatic
    /// (width × 1.5).
    /// 58% = about the upper limit where card height + heading + CTA still fit even on iPhone SE
    private var cardWidth: CGFloat { UIScreen.main.bounds.width * 0.58 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 64)

            // 2026-07-25 feedback: the line spacing between title/subtitle/caption was too large → tighten spacing.
            // Also removed the extra top padding on the emphasized line so the 3 lines are evenly close
            VStack(spacing: 5) {
                // 2026-07-29 user instruction: this page became a live review page (it also shows passes), so
                // the title changed from "these never appear" to one that says "AI is auditing the content"
                Text(lang == .japanese ? "全ての投稿をAIが審査する" : "Every post is screened by AI") // Copy waiting for user review
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

                // Stating AI moderation is the emphasized line of this page (2026-07-17 user feedback round 2:
                // the standalone line "あなたの脳を腐らせない" ("We won't rot your brain") was deleted and this was
                // promoted to the emphasis) // Copy waiting for user review
                Text(lang == .japanese
                     ? "脳を腐らせる投稿はAIと運営が弾く"
                     : "AI and moderators remove brain-rot posts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            Spacer().frame(height: 8)

            // Live review animation (2026-07-29 real-device feedback: moved here from the hook screen + enlarged).
            // It shows the claim "these never appear" as an event where a post is scanned → judged → rejected.
            // The old horizontal scroll carousel (9 cards) was replaced by JudgmentFeedView
            // (ModerationCard is kept for rollback)
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

/// Card for removed content: darkens the image, and shows "rejected" with a red "削除" ("Removed") tag +
/// a diagonal line
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

            // Red "削除" ("Removed") badge
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
