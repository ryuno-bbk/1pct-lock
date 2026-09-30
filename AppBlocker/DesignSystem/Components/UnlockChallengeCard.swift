//
//  UnlockChallengeCard.swift
//  AppBlocker
//
//  The card for choosing the "解除方法" ("unlock method"), and the selection sheet that comes up from it.
//
//  🔴 It is placed right after modeSegment in HomeView (a position shared by the 3 modes).
//     It needs to be inserted in only 1 place and shows for all of timer/schedule/location.
//     The idea of putting it inside the schedule edit sheet was rejected: people who have already set
//     up their schedules never open the edit sheet again, so the headline feature would be invisible
//     (pointed out by the user 2026-08-28).
//     ⚠️ Decide the final position after looking at a real device. It can be moved by moving just 1 line.
//
//  🔴 Add nothing to the interruption screen. Showing options and a paywall to someone who is trying to
//     escape is a bad idea, so choosing happens only "when starting".
//

import SwiftUI

// MARK: - Card (same look as AppSelectCard)

struct UnlockChallengeCard: View {
    let challenge: UnlockChallenge
    let lang: AppLanguage
    /// 🔴 Do not allow changes while a lock is running.
    ///    The session has the challenge from the start baked in, so changing only the setting while it runs
    ///    causes the mismatch "the card says push-ups but it is actually long press",
    ///    and the card would be lying (real device report 2026-08-28).
    ///    In that case, show "the challenge actually imposed", not the setting value
    var isLocked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: { if !isLocked { action() } }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AppColors.secondaryBackground)
                        .frame(width: 34, height: 34)
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(lang == .japanese ? "解除方法" : "How to unlock") // Wording pending user review
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    if isLocked {
                        // ⚠️ Wording pending user review
                        Text(lang == .japanese ? "ロック中は変更できません" : "Can't change while locked")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text(challenge.title(lang))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary)
                    Image(systemName: isLocked ? "lock.fill" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Selection sheet (same "comes up from the bottom" form as the schedule edit card)

struct UnlockChallengeSheet: View {
    let lang: AppLanguage
    /// Whether the user has Pro. If false, show a lock on Pro challenges, and tapping goes to the paywall
    let hasPro: Bool
    @Binding var selected: UnlockChallenge
    let onRequestPro: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Registration screen opened from the + of "自分の画像を見る" ("View my images")
    @State private var showImageLibrary = false
    @ObservedObject private var imageStore = UnlockImageStore.shared

    /// 🔴 Do not show challenges that are not implemented. If one were picked, there would be no way to unlock
    private var options: [UnlockChallenge] {
        UnlockChallenge.pickable.filter(\.isImplemented)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // 🔴 Say first what this screen decides.
                    //    "解除方法" ("How to unlock") alone does not tell you what it is about (2026-08-29 real device feedback)
                    // ⚠️ Wording pending user review
                    Text(lang == .japanese
                         ? "アプリの制限を解除しようとした時に、\n何をすれば解除できるかを決めます"
                         : "Choose what you must do to lift the app block")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 8)

                    ForEach(options) { option in
                        row(for: option)
                    }
                }
                .padding(16)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(lang == .japanese ? "解除方法" : "How to unlock") // Wording pending user review
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lang == .japanese ? "完了" : "Done") { dismiss() } // Wording pending user review
                }
            }
            .sheet(isPresented: $showImageLibrary) {
                UnlockImageLibraryView(lang: lang)
            }
        }
    }

    private func row(for option: UnlockChallenge) -> some View {
        let isLocked = option.requiresPro && !hasPro
        let isSelected = option == selected

        return Button {
            if isLocked {
                onRequestPro()
            } else {
                selected = option
            }
        } label: {
            HStack(spacing: 12) {
                // 🔴 The icon is in a fixed-width column separate from the text (2026-09-05).
                //    Mixing it into the same HStack as the title shifts the wrap position for each method
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AppColors.secondaryBackground)
                        .frame(width: 34, height: 34)
                    Image(systemName: option.icon)
                        .font(.system(size: 15))
                        .foregroundColor(isLocked ? AppColors.accent : AppColors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.title(lang))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)
                        // 🔴 2026-09-05 real device feedback: before, it had a gray lock icon + opacity 0.55 on the whole row,
                        //    so "the thing we most want to show was the darkest".
                        //    Bring Pro challenges forward instead of sinking them (the badge is inverted to draw the eye)
                        if isLocked {
                            Text("PRO")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(AppColors.background)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppColors.accent))
                        }
                    }
                    Text(option.detail(lang))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                // 🔴 Show + only for image scroll (user specified 2026-08-29).
                //    Without registering from here there is nothing to show, so put the entry point inside the row
                if option == .imageScroll {
                    // 🔴 "+3" looks like addition (2026-08-29 real device feedback).
                    //    Use a form that reads as a number of images, and always show it, even at 0 images
                    //    (with 0 images you cannot unlock, so if you do not notice that you get stuck)
                    Button {
                        showImageLibrary = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(lang == .japanese
                                 ? "\(imageStore.imageIds.count)枚"
                                 : "\(imageStore.imageIds.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(imageStore.imageIds.isEmpty
                                         ? AppColors.error
                                         : AppColors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AppColors.secondaryBackground))
                    }
                    .buttonStyle(.plain)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppColors.accent)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppColors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? AppColors.accent.opacity(0.6)
                                    // Pro challenges keep their presence with a frame even when not owned (do not sink them)
                                    : (isLocked ? AppColors.accent.opacity(0.35) : .clear),
                                    lineWidth: 1.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
