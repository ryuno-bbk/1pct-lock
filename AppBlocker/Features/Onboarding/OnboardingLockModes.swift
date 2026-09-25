//
//  OnboardingLockModes.swift
//  AppBlocker
//
//  3つのロックモード (タイマー / スケジュール / 位置情報) をオンボーディングで1枚だけ見せる。
//
//  Why (2026-08-06 ユーザー指摘):
//  従来のオンボは「なぜやめるべきか」(診断→ショック→夢→署名) だけを説き、
//  このアプリが何をするのかを一度も見せないままペイウォールへ到達していた。
//  = 何を売っているか見せずに売っている状態だった。
//
//  置き場所は「ショック → 覚悟」の直後 (ユーザー指定)。
//  「人生を変える覚悟はできていますか?」の次に「これがその手段だ」を出す並びになる。
//
//  レイアウトの決定 (モックを4案→3案→3案と出した末の結論):
//  - モード名は大きく、**改行しない**。承認済み App Store スクショの見出しと同じ字組み
//    (heavy / トラッキング詰め / nowrap) を使う。仕様は _builder/decorate.html の .headline
//  - 説明はモード名の下に小さく AppColors.textSecondary で置く (スクショの .sub と同じ)
//  - 🔴 アイコンは文字の**背後**に特大で置き、画面右端から見切れさせる。
//    横に並べるとその幅だけモード名を小さくするしかなくなるため
//    (「アイコンを大きく」と「文字を大きく」を両立させるための配置)
//  - 罫線は画面端まで通す。左右 24pt の内側で止めるとリスト感が出る
//
//  ⚠️ アイコンは .background に置くこと。ZStack に入れると 96pt のアイコンが行の高さを
//     決めてしまい、3行で画面からあふれる
//  ⚠️ scaleEffect は使わない (2026-07 実機で10fpsになった経験。opacity + offset のみ)
//

import SwiftUI

// MARK: - Step View

struct LockModesStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// 段階的リビール。行が上から順に入り、最後に CTA が出る (ShockLossStepView と同じ作法)
    @State private var revealedRows = 0
    @State private var showCTA = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    private var modes: [LockModeCopy] { LockModeCopy.all(lang) }

    var body: some View {
        VStack(spacing: 0) {
            // 上ナビ (戻る + 2px 進捗バー) を避ける固定余白。
            // 他のクイズ画面と同じ 64pt に揃えている (OnboardingTopNav は 44pt + 上余白 16pt)
            Spacer().frame(height: 64)

            // ページ見出し。モード名 (21pt) より一段大きくしてタイトルとして立たせる。
            // 28pt = AppTypography.title1 と同寸で、オンボ他画面の見出しと揃う
            Text(LockModeCopy.heading(lang))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .tracking(-0.6)
                .foregroundColor(AppColors.textPrimary)
                // 「このアプリのロック方法」= 11文字。28pt でも最小幅の iPhone に収まる
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            Spacer(minLength: 20)

            // 罫線とアイコンを画面端まで届かせるため、この塊だけ横パディングを持たない
            VStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    LockModeRow(mode: mode, isFirst: index == 0)
                        .opacity(revealedRows > index ? 1 : 0)
                        .offset(y: revealedRows > index ? 0 : 10)
                }
            }

            Spacer(minLength: 20)

            PrimaryButton(LockModeCopy.next(lang), icon: "arrow.right") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(showCTA ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LockModesBackdrop())
        .onAppear(perform: runReveal)
    }

    /// 上の行から 0.13 秒間隔で入れ、全部出てから CTA を出す
    private func runReveal() {
        guard revealedRows == 0 else { return }
        for index in modes.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(index)) {
                withAnimation(.easeOut(duration: 0.45)) { revealedRows = index + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(modes.count) + 0.25) {
            withAnimation(.easeOut(duration: 0.45)) { showCTA = true }
        }
    }
}

// MARK: - 1行

private struct LockModeRow: View {
    let mode: LockModeCopy
    let isFirst: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isFirst { hairline }

            VStack(alignment: .leading, spacing: 5) {
                Text(mode.title)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .tracking(-0.4)
                    .foregroundColor(AppColors.textPrimary)
                    // ⚠️ 改行させない。日本語8文字 (タイマーブロック) が現状の最長
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(mode.subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 19)
            // 特大アイコンは背景として敷く。.background は親の大きさに影響しないので、
            // 行の高さはあくまで文字が決める (ZStack だとアイコンが高さを決めてしまう)
            .background(alignment: .trailing) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 74, weight: .ultraLight))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                AppColors.textPrimary.opacity(0.30),
                                AppColors.textPrimary.opacity(0.07)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // 画面右端から見切れさせる (端で切れることで「大きい」が伝わる)
                    .offset(x: 18)
                    .allowsHitTesting(false)
            }
            .clipped()

            hairline
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppColors.textPrimary.opacity(0.09))
            .frame(height: 1)
    }
}

// MARK: - 背景

/// 黒地 + 霧。App Store スクショの仕様 (「背景 = 黒 + 霧。それ以外の背景要素は入れない」) に合わせる。
/// ⚠️ blur / material は使わない (全面ブラーは実機で重い)。RadialGradient を重ねるだけ
private struct LockModesBackdrop: View {
    var body: some View {
        ZStack {
            AppColors.background

            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.16),
                startRadius: 0,
                endRadius: 300
            )
            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.05), .clear],
                center: UnitPoint(x: 0.18, y: 0.58),
                startRadius: 0,
                endRadius: 250
            )
            RadialGradient(
                colors: [AppColors.textPrimary.opacity(0.045), .clear],
                center: UnitPoint(x: 0.86, y: 0.86),
                startRadius: 0,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 文言

/// 🔴 日本語はユーザーが口頭で指定したもの (2026-08-06)。勝手に言い換えない。
/// 英語は仮訳 — ネイティブ総点検の対象。 // 文言はユーザー添削待ち
struct LockModeCopy: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String

    static func heading(_ lang: AppLanguage) -> String {
        lang == .japanese ? "このアプリのロック方法" : "How 1% locks your apps" // 文言はユーザー添削待ち
    }

    static func next(_ lang: AppLanguage) -> String {
        lang == .japanese ? "次へ" : "Continue"
    }

    static func all(_ lang: AppLanguage) -> [LockModeCopy] {
        [
            LockModeCopy(
                id: "timer",
                symbol: "timer",
                title: lang == .japanese ? "タイマーブロック" : "Timer Block",
                subtitle: lang == .japanese
                    ? "ワンタップで決めた時間だけ集中"
                    : "One tap locks your apps for as long as you choose"
            ),
            LockModeCopy(
                id: "schedule",
                symbol: "calendar",
                title: lang == .japanese ? "スケジュール制限" : "Schedule",
                subtitle: lang == .japanese
                    ? "設定した曜日の決めた時間帯に自動でロック"
                    : "Locks automatically on the days and hours you set"
            ),
            LockModeCopy(
                id: "location",
                symbol: "mappin.and.ellipse",
                title: lang == .japanese ? "位置情報ロック" : "Location Lock",
                subtitle: lang == .japanese
                    ? "集中すると決めた場所に入った瞬間にロック"
                    : "Locks the moment you arrive at a place you chose to focus"
            )
        ]
    }
}

#Preview {
    LockModesStepView(onContinue: {})
}
