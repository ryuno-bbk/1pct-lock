//
//  TotalActivityView.swift
//  UsageReportExtension
//
//  オンボ診断のレポート View 2つ (比較チャート / 使用量トップ3)。
//  拡張はメインアプリの AppColors を import できないため、ブランドトークンを
//  ここにハードコードする (AppColors.swift と一致させること):
//    背景 #000000 / オフホワイト #F2EFE7 / 弱調 #97928A / 最弱 #6E6A63 / カード #17171B
//  ⚠️ 背景は必ず不透明で塗る: 本体側は「このレポートが描画されない時に下の
//  プレースホルダが透けて見える」フォールバック構造なので、描画された時は
//  完全に覆う必要がある。
//

import SwiftUI
import FamilyControls
import ManagedSettings

// ブランドトークン (AppColors と一致)
private let inkColor = Color(red: 242/255, green: 239/255, blue: 231/255)   // #F2EFE7
private let secondaryColor = Color(red: 151/255, green: 146/255, blue: 138/255) // #97928A
private let tertiaryColor = Color(red: 110/255, green: 106/255, blue: 99/255)   // #6E6A63
private let cardColor = Color(red: 23/255, green: 23/255, blue: 27/255)     // #17171B
private let barGrayColor = Color(red: 42/255, green: 42/255, blue: 48/255)  // #2A2A30

/// 分 → "7h 18m"。日本語でも単位は英語表記に統一する
/// (「7時間18分」は横幅を食いすぎてチャートの余白が崩れる — 2026-07-15 実機FB、リファレンス準拠)
private func durationLabel(minutes: Int, jp: Bool) -> String {
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// L28: スクリーンタイムの記録が端末に全く無い (実測0分 かつ トップアプリ0件)。
/// この場合「実際の使用時間 0m」や空のトップ3カードをそのまま描画すると壊れて見えるため、
/// 呼び出し側 (Comparison/TopApps 両方) で空状態に差し替える
private extension UsageConfiguration {
    var hasNoUsageHistory: Bool { actualDailyMinutes == 0 && apps.isEmpty }
}

/// 空状態の共通表示 (L28)。拡張はメインアプリの L enum を import できないためローカル文字列
private struct EmptyUsageHistoryView: View {
    let jp: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(jp ? "まだデータがありません" : "No data yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(inkColor)
            Text(jp ? "スクリーンタイムの記録が貯まると表示されます" : "This appears once Screen Time has some history")
                .font(.system(size: 13))
                .foregroundColor(tertiaryColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 比較チャート (予想 vs 実測)

struct ComparisonReportView: View {
    let config: UsageConfiguration

    private var jp: Bool { config.isJapanese }

    /// 予想の +20% を超えていたら比較チャート (2本棒) を出す
    private var isOverEstimate: Bool {
        config.estimateDailyMinutes > 0 &&
        Double(config.actualDailyMinutes) > Double(config.estimateDailyMinutes) * 1.2
    }

    /// 「8時間以上」(予想の最上ブラケット = 480分) と答えた人は、実測がそれを超えていても
    /// 本人に驚きは無い (16時間の自覚があって 8+ を選んでいる) ので、
    /// ショック見出しは出さない (2026-07-17 ユーザー指定の条件分岐)
    private var isTopBracketEstimate: Bool {
        config.estimateDailyMinutes >= 480
    }

    private var showsShockHeadline: Bool { isOverEstimate && !isTopBracketEstimate }

    private var headline: String {
        if showsShockHeadline {
            return jp ? "予想より多く\n使っています" : "You're using more\nthan you thought"
        } else {
            // 予想が合っていた / 予想の方が多かった / 8時間以上と自覚済み → 淡々と事実の提示
            return jp ? "実際の使用時間" : "Your actual\nscreen time" // 文言はユーザー添削待ち
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 上の 72pt は本体側の戻るボタン+プログレスバー (OnboardingTopNav) を
            // 避けるための余白。少ないと見出しがナビに重なる (2026-07-13 実機FB)
            Spacer().frame(height: 72)

            if config.hasNoUsageHistory {
                // L28: スクリーンタイム履歴が0件の端末 (実機/シミュレータの初回起動直後など)
                Spacer()
                EmptyUsageHistoryView(jp: jp)
                Spacer()
            } else {
                // リファレンス準拠 (2026-07-15 実機FB): 見出しは sans 太字。
                // serif の濫用をやめる方針 (かっこいい書体を無理に使うと逆にダサい)
                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                Spacer()

                // 比較 (予想vs実測の2本棒) はショック演出が成立する時だけ。
                // 8時間以上と自覚済み / 予想的中の場合は比較自体が不要で、実測の1本棒のみ出す
                // (2026-07-17 ユーザー指定)
                if showsShockHeadline {
                    comparisonBars
                } else {
                    singleBar
                }

                // チャートを画面中央でなく下寄せにして間延びを消す (2026-07-15 実機FB: 余白が空きすぎ)
                Spacer().frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black) // 不透明必須 (下のプレースホルダを覆う)
    }

    private let maxChartHeight: CGFloat = 230
    private let minBarHeight: CGFloat = 28

    private func barHeight(minutes: Int, referenceMax: Int) -> CGFloat {
        guard referenceMax > 0 else { return minBarHeight }
        let ratio = CGFloat(minutes) / CGFloat(referenceMax)
        return max(maxChartHeight * ratio, minBarHeight)
    }

    private var comparisonBars: some View {
        let refMax = Int(Double(max(config.actualDailyMinutes, config.estimateDailyMinutes, 1)) * 1.08)
        // 列幅120/130固定+間隔10 (2026-07-17 実機FB: 棒同士の隙間が空きすぎると指摘され28→10に短縮)。
        // 列幅はそのまま維持 — 「1日の平均使用時間」ラベルが折り返さず収まる最小幅のため
        // リファレンス準拠: 数値ラベルは sans 太字、棒はやや太め、ラベルは棒の直下
        return HStack(alignment: .bottom, spacing: 10) {
            VStack(spacing: 12) {
                Text(durationLabel(minutes: config.estimateDailyMinutes, jp: jp))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 12)
                    .fill(barGrayColor)
                    .frame(width: 76, height: barHeight(minutes: config.estimateDailyMinutes, referenceMax: refMax))
                Text(jp ? "自分の予想" : "Your guess") // 文言はリファレンス準拠 (2026-07-15)
                    .font(.system(size: 13))
                    .foregroundColor(tertiaryColor)
                    .lineLimit(1)
            }
            .frame(width: 120)

            VStack(spacing: 12) {
                Text(durationLabel(minutes: config.actualDailyMinutes, jp: jp))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                RoundedRectangle(cornerRadius: 12)
                    .fill(inkColor)
                    .frame(width: 76, height: barHeight(minutes: config.actualDailyMinutes, referenceMax: refMax))
                Text(jp ? "1日の平均使用時間" : "Daily average") // 文言はリファレンス準拠 (2026-07-15)
                    .font(.system(size: 13))
                    .foregroundColor(tertiaryColor)
                    .lineLimit(1)
            }
            .frame(width: 130)
        }
        .frame(maxWidth: .infinity)
    }

    private var singleBar: some View {
        VStack(spacing: 12) {
            Text(durationLabel(minutes: config.actualDailyMinutes, jp: jp))
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(inkColor)
                .monospacedDigit()
            RoundedRectangle(cornerRadius: 12)
                .fill(inkColor)
                .frame(width: 84, height: 220)
            Text(jp ? "1日の平均使用時間" : "Daily average") // 文言はリファレンス準拠 (2026-07-15)
                .font(.system(size: 13))
                .foregroundColor(tertiaryColor)
        }
    }
}

// MARK: - 使用量トップ3

struct TopAppsReportView: View {
    let config: UsageConfiguration

    private var jp: Bool { config.isJapanese }

    var body: some View {
        VStack(spacing: 0) {
            // 本体側の戻るボタン+プログレスバーを避ける余白
            Spacer().frame(height: 72)

            if config.hasNoUsageHistory {
                // L28: スクリーンタイム履歴が0件の端末では空のトップ3カードを描画しない
                Spacer()
                EmptyUsageHistoryView(jp: jp)
                Spacer()
            } else {
                Text(jp ? "最近最も\n使っているアプリ" : "Apps you use\nthe most")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 36)

                card

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black) // 不透明必須 (下のプレースホルダを覆う)
    }

    /// バーの固定幅。GeometryReader は Report 描画コンテキストで行が縦に伸びる
    /// レイアウトバグの原因になったため一切使わず、全て固定寸法で組む (2026-07-13 実機FB)
    private let barWidth: CGFloat = 280

    private var card: some View {
        let maxMinutes = config.apps.map(\.totalMinutes).max() ?? 1

        return VStack(alignment: .leading, spacing: 16) {
            // 値は1日平均のまま、タイトルは短く (リファレンス準拠 2026-07-15)
            Text(jp ? "使用量トップ 3" : "Top 3 by usage")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(secondaryColor)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            VStack(spacing: 22) {
                ForEach(config.apps) { app in
                    row(app: app, maxMinutes: maxMinutes)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(cardColor))
        .padding(.horizontal, 24)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 競合準拠の行: [アイコン+名前 ... 時間] の1行 + その下に全幅バー
    private func row(app: TopAppEntry, maxMinutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let token = app.token {
                    Label(token)
                        .labelStyle(TopAppLabelStyle())
                } else {
                    Text(app.fallbackName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(inkColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(durationLabel(minutes: app.totalMinutes, jp: jp))
                    .font(.system(size: 14))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            bar(ratio: Double(app.totalMinutes) / Double(max(maxMinutes, 1)))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bar(ratio: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(tertiaryColor.opacity(0.18))
                .frame(width: barWidth, height: 6)
            Capsule()
                .fill(inkColor)
                .frame(width: barWidth * CGFloat(max(min(ratio, 1), 0)), height: 6)
        }
    }
}

/// Label(ApplicationToken) のアイコン+タイトルをブランドトーンで整える
private struct TopAppLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: 40, height: 40)
            configuration.title
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(inkColor)
                .lineLimit(1)
        }
    }
}
