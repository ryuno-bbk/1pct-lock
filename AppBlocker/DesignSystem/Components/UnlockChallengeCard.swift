//
//  UnlockChallengeCard.swift
//  AppBlocker
//
//  「解除方法」を選ぶカードと、その下から出る選択シート。
//
//  🔴 置き場所は HomeView の modeSegment 直後 (3モード共通の位置)。
//     挿入は1箇所で済み、タイマー/スケジュール/位置の全部に出る。
//     予定の編集シートの中に入れる案は却下した — 既にスケジュールを設定し終えた人は
//     編集シートを二度と開かないため、目玉機能が見えなくなる (2026-08-28 ユーザー指摘)。
//     ⚠️ 最終的な位置は実機を見てから決める。1行動かすだけで移せる。
//
//  🔴 中断画面には何も足さない。逃げようとしている人に選択肢とペイウォールを
//     並べるのは筋が悪いので、選ぶのは「始めるとき」だけにする。
//

import SwiftUI

// MARK: - カード (AppSelectCard と同じ見た目に揃える)

struct UnlockChallengeCard: View {
    let challenge: UnlockChallenge
    let lang: AppLanguage
    /// 🔴 ロックが走っている間は変更させない。
    ///    セッションには開始時の課題が焼き付いているので、走行中に設定だけ変えると
    ///    「カードは腕立てと言っているのに実際は長押し」というズレが起き、
    ///    カードが嘘をつくことになる (2026-08-28 実機報告)。
    ///    このとき表示するのは設定値ではなく「実際に課されている課題」にする
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
                    Text(lang == .japanese ? "解除方法" : "How to unlock") // 文言はユーザー添削待ち
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    if isLocked {
                        // ⚠️ 文言はユーザー添削待ち
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

// MARK: - 選択シート (スケジュール編集カードと同じ「下から出る」形)

struct UnlockChallengeSheet: View {
    let lang: AppLanguage
    /// Pro を持っているか。false なら Pro 課題に鍵を出し、タップでペイウォールへ
    let hasPro: Bool
    @Binding var selected: UnlockChallenge
    let onRequestPro: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// 「自分の画像を見る」の ＋ から開く登録画面
    @State private var showImageLibrary = false
    @ObservedObject private var imageStore = UnlockImageStore.shared

    /// 🔴 未実装の課題は出さない。選ばれると解除手段が無くなる
    private var options: [UnlockChallenge] {
        UnlockChallenge.pickable.filter(\.isImplemented)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // 🔴 この画面が何を決めているのかを最初に言う。
                    //    「解除方法」だけでは何のことか分からない (2026-08-29 実機フィードバック)
                    // ⚠️ 文言はユーザー添削待ち
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
            .navigationTitle(lang == .japanese ? "解除方法" : "How to unlock") // 文言はユーザー添削待ち
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lang == .japanese ? "完了" : "Done") { dismiss() } // 文言はユーザー添削待ち
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
                // 🔴 アイコンはテキストとは別の固定幅カラム (2026-09-05)。
                //    タイトルと同じ HStack に混ぜると、方法ごとに折り返し位置がズレる
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
                        // 🔴 2026-09-05 実機FB: 以前は灰色の鍵アイコン + 行ごと opacity 0.55 で、
                        //    「一番見せたいものが一番暗い」状態だった。
                        //    Pro 課題は沈めずに前へ出す (バッジは反転させて視線を集める)
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

                // 🔴 画像スクロールだけ ＋ を出す (2026-08-29 ユーザー指定)。
                //    ここから登録しないと見せるものが無いので、行の中に導線を置く
                if option == .imageScroll {
                    // 🔴 「+3」だと足し算に見える (2026-08-29 実機フィードバック)。
                    //    枚数として読める形にし、0枚のときも必ず出す
                    //    (0枚だと解除できないので、そこに気づけないと詰まる)
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
                                    // Pro 課題は未所持でも枠で存在感を残す (沈めない)
                                    : (isLocked ? AppColors.accent.opacity(0.35) : .clear),
                                    lineWidth: 1.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
