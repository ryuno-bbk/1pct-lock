//
//  LockedSavedNoticeSheet.swift
//  AppBlocker
//
//  Real-device feedback #11 (2026-07-21, Fable's proposal confirmed by the user): lock UX improvements
//  for non-paying users.
//  1) LockedToggleBadge: unify the lock display on list cards to "OFF toggle + padlock badge"
//     (it tells "this cannot be used" on the spot better than a lock icon that just bounces back)
//  2) LockedSavedNoticeSheet: upgrade the explanation shown right after a non-paying user saves, from
//     an alert to a custom sheet
//     (tells "it is saved, but running it needs a purchase" in one beat, and hands off to the paywall)
//
//  Shared component used by both ScheduleBlockView (ScheduleRowCard) and LocationBlockView.
//

import SwiftUI

// MARK: - Locked Toggle Badge (toggle for non-paying users on list cards)

/// A button with the same shape as an iOS toggle in the OFF state + a padlock badge on the bottom right.
/// It tells "a toggle you cannot touch" through its shape itself (2026-07-21 feedback #11).
/// 2026-07-22 real-device feedback: the first version (track white 8% + knob textTertiary) was too dark
/// and was rejected as "I can't tell what button this is" → brightened it to match a real iOS OFF
/// toggle (gray track + near-white knob).
/// Note: do not include this badge in the caller's "dimming of disabled rows (opacity 0.55)"
/// (including it sinks it further to 55% brightness, which was the main reason the first version was
/// dark).
struct LockedToggleBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 51, height: 31)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(AppColors.textSecondary)
                        .frame(width: 27, height: 27)
                        .padding(2)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(AppColors.background)
                        .padding(3)
                        .background(Circle().fill(AppColors.textPrimary))
                        .offset(x: 4, y: 4)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Locked Run Strip (explanation strip at the bottom edge of a locked card)

/// A full-width tappable strip shown at the bottom edge of a card whose run is locked (tap → paywall).
/// 2026-07-22 real-device feedback: the first version's full off-white fill had the same color as the
/// real CTAs (PrimaryButton such as Add Schedule) and competed with them for attention, and it also made
/// the padlock badge next to it look sunk in comparison, so the user rejected it.
/// Changed to a quiet style (light base + textSecondary + smaller + trailing chevron).
/// Do not use the CTA color (AppColors.primaryFallback flat fill) in this path.
struct LockedRunStrip: View {
    let lang: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(L.blockLockedStripText(lang))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Locked Saved Notice Sheet (explanation sheet after saving)

/// Explanation sheet shown right after a non-paying user saves a schedule/place (old: alert).
/// The caller passes title/message as finished strings after branching on lang (this sheet itself has
/// no lang).
struct LockedSavedNoticeSheet: View {
    let title: String
    let message: String
    let onSeeElite: () -> Void
    @Environment(\.dismiss) private var dismiss
    // lang is not needed because it is included in the caller's strings. Only the close button label is
    // received as the closeTitle argument
    let closeTitle: String
    let ctaTitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.white.opacity(0.08)))

            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            PrimaryButton(ctaTitle) {
                dismiss()
                onSeeElite()
            }

            Button(closeTitle) {
                dismiss()
            }
            .font(AppTypography.footnote)
            .foregroundColor(AppColors.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        // 2026-07-25 real-device feedback: the background was painted only to the height of the VStack, so the
        // gap to the fixed detent looked like a band of the system default color. The whole sheet now uses the
        // app background color, and the detent was expanded to 400 so that long English text fits.
        // Real-device feedback round 2: when aligned to the top, the empty space gathers at the bottom, so the
        // content is centered in the card
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(AppColors.background.ignoresSafeArea())
        .presentationBackground(AppColors.background)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preview

#Preview {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LockedSavedNoticeSheet(
                title: "ロックの実行には 1% エリートが必要です",
                message: "作成したスケジュールは保存されています。有効にするには 1% エリートに参加してください。",
                onSeeElite: {},
                closeTitle: "閉じる",
                ctaTitle: "1% エリートを見る"
            )
        }
}
