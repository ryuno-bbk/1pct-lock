//
//  TotalActivityReport.swift
//  UsageReportExtension
//
//  オンボーディング診断用の DeviceActivityReport シーン2つ。
//  - onboardingComparison: 予想 (自己申告) vs 実測の比較チャート
//  - onboardingTopApps:    使用量トップ3 (実アプリのアイコン+名前は Label(token) で
//                          この拡張の中でだけ描画できる)
//
//  データの流れ:
//  - 実測値 (DeviceActivityResults) はこの拡張の外に持ち出せない (Apple のプライバシー制約)。
//    そのため見出し・チャートまで全部この拡張内の View で描く。
//  - 自己申告 (予想) は本体アプリが App Group に書き、ここで読む
//    (Report 拡張は App Group への書き込みは不可だが読み取りは可能)。
//  - Context の rawValue は本体の DeviceActivityReport(...) 側と完全一致が必要 (固定文字列)。
//

import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI

// App Group (メインアプリの AppGroupConstants と一致させること。拡張からは import 不可のためハードコード)
private let appGroupID = "group.com.ryunosuke.appblocker.shared"
private let keyEstimateMinutes = "onboardingEstimateMinutes"
private let keyOnboardingLang = "onboardingLanguage"
private let keyRevealPhase = "onboardingRevealPhase"

extension DeviceActivityReport.Context {
    /// 予想 vs 実測の比較 (オンボ診断)
    static let onboardingComparison = Self("onboardingComparison")
    /// 使用量トップ3 (オンボ診断)
    static let onboardingTopApps = Self("onboardingTopApps")
    // 実機検証の経緯 (2026-07-13):
    // - 本体に DeviceActivityReport を2インスタンス置く → 2個目が白紙 (iOS の既知の癖)
    // - 単一インスタンス + context 切替 → ✅ 両方描画できた (20:24 実機確認)
    // - 1シーン統合 + フィルタ微変更で再クエリ → ❌ 切替のたび数秒の再クエリ空白が
    //   入りプレースホルダが透ける (20:41 実機で退行確認)
    // → 結論: 「シーン2つ + 本体は単一インスタンスで context だけ切替」が正解
}

// MARK: - 共有ヘルパー

/// App Group から自己申告の1日予想 (分) を読む。未設定は 0
func loadEstimateMinutes() -> Int {
    UserDefaults(suiteName: appGroupID)?.integer(forKey: keyEstimateMinutes) ?? 0
}

/// App Group から言語 ("japanese"/"english") を読む。未設定は日本語扱い
func loadIsJapanese() -> Bool {
    let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: keyOnboardingLang)
    return raw != "english"
}

// MARK: - 統合シーン (比較 + トップ3)

struct TopAppEntry: Identifiable {
    let id = UUID()
    let token: ApplicationToken?
    let fallbackName: String
    /// 期間合計 (分)
    let totalMinutes: Int
}

struct UsageConfiguration {
    /// "comparison" or "topApps" (本体が App Group に書くフェーズフラグ)
    let phase: String
    /// 実測の1日平均 (分)
    let actualDailyMinutes: Int
    /// 自己申告の1日予想 (分)。0 = 未設定
    let estimateDailyMinutes: Int
    let apps: [TopAppEntry]
    let isJapanese: Bool
}

/// 共通集計 (1パスで合計とアプリ別の両方)
private func buildUsageConfiguration(_ data: DeviceActivityResults<DeviceActivityData>, phase: String) async -> UsageConfiguration {
    var total: TimeInterval = 0
    var dayCount = 0
    var seconds: [ApplicationToken?: TimeInterval] = [:]
    var names: [ApplicationToken?: String] = [:]

    for await d in data {
        for await segment in d.activitySegments {
            total += segment.totalActivityDuration
            dayCount += 1
            for await category in segment.categories {
                for await app in category.applications {
                    let key = app.application.token
                    seconds[key, default: 0] += app.totalActivityDuration
                    if names[key] == nil {
                        names[key] = app.application.localizedDisplayName ?? "App"
                    }
                }
            }
        }
    }

    let days = Double(max(dayCount, 1))
    let dailyAvgMinutes = Int((total / days) / 60)
    // アプリ別も「1日平均」に揃える (週合計だと 58時間 のような桁になり
    // 比較画面の1日平均と混乱する。2026-07-13 実機FB)
    let top = seconds
        .sorted { $0.value > $1.value }
        .prefix(3)
        .map { TopAppEntry(token: $0.key, fallbackName: names[$0.key] ?? "App", totalMinutes: Int(($0.value / days) / 60)) }

    return UsageConfiguration(
        phase: phase,
        actualDailyMinutes: dailyAvgMinutes,
        estimateDailyMinutes: loadEstimateMinutes(),
        apps: Array(top),
        isJapanese: loadIsJapanese()
    )
}

struct OnboardingComparisonReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .onboardingComparison
    let content: (UsageConfiguration) -> ComparisonReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageConfiguration {
        await buildUsageConfiguration(data, phase: "comparison")
    }
}

struct OnboardingTopAppsReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .onboardingTopApps
    let content: (UsageConfiguration) -> TopAppsReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageConfiguration {
        await buildUsageConfiguration(data, phase: "topApps")
    }
}
