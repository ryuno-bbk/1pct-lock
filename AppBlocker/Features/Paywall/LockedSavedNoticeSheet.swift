//
//  LockedSavedNoticeSheet.swift
//  AppBlocker
//
//  実機FB#11 (2026-07-21 ユーザー確定 Fable案): 無課金ロックUX改善。
//  1) LockedToggleBadge — 一覧カードのロック錠表示を「OFFトグル+錠前バッジ」に統一
//     (跳ね返るだけのロック錠アイコンより「使えない状態」がその場で伝わる)
//  2) LockedSavedNoticeSheet — 無課金で保存した直後の説明を alert からカスタムシートに格上げ
//     (「保存はされている・実行には課金が要る」を一拍で伝え、ペイウォール導線へ渡す)
//
//  ScheduleBlockView (ScheduleRowCard) / LocationBlockView の両方から使う共有コンポーネント。
//

import SwiftUI

// MARK: - Locked Toggle Badge (一覧カードの無課金トグル)

/// iOS トグルと同形状の OFF 状態 + 右下に錠前バッジを重ねたボタン。
/// トグルなのに触れない、を形そのもので伝える (2026-07-21 FB#11)。
/// 2026-07-22 実機FB: 初版 (トラック白8% + ノブ textTertiary) は暗すぎて「何のボタンか
/// わからない」と却下 → 実物の iOS OFF トグル (灰トラック+白寄りノブ) に寄せて明度を上げた。
/// 注意: 呼び出し側の「無効行の減光 (opacity 0.55)」にこのバッジを含めないこと
/// (含めると 55% 明度でさらに沈む — 初版が暗かった主因)。
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

// MARK: - Locked Run Strip (ロックカード下端の説明ストリップ)

/// 実行ロック中カードの下端に出す全幅タップ可のストリップ (タップでペイウォール)。
/// 2026-07-22 実機FB: 初版のオフホワイト全面塗りは本物の CTA (スケジュールを追加等の
/// PrimaryButton) と同色で視線を食い合い、隣のロック錠バッジも相対的に沈むためユーザー却下。
/// 静音スタイル (薄い地 + textSecondary + 小さめ + 末尾シェブロン) に変更。
/// CTA 色 (AppColors.primaryFallback ベタ塗り) はこの導線では使わないこと。
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

// MARK: - Locked Saved Notice Sheet (保存後の説明シート)

/// 無課金でスケジュール/場所を保存した直後に出す説明シート (旧: alert)。
/// title/message は呼び出し側で lang 分岐を終えた完成文字列を渡す (このシート自体は lang を持たない)。
struct LockedSavedNoticeSheet: View {
    let title: String
    let message: String
    let onSeeElite: () -> Void
    @Environment(\.dismiss) private var dismiss
    // lang は呼び出し側の文字列に含まれるため不要。閉じるボタンラベルだけ引数 closeTitle で受ける
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
        // 2026-07-25 実機FB: 背景を VStack の高さだけ塗っていたため、固定 detent との差分が
        // システム標準色の帯になって見えていた。シート全面をアプリ背景色にし、
        // 英語の長文でも収まるよう detent を 400 に拡張。
        // 実機FB2周目: 上寄せだと下に余白が固まって見えるため、中身はカード中央に置く
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
