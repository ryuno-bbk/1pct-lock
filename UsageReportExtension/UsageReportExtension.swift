//
//  UsageReportExtension.swift
//  UsageReportExtension
//
//  オンボーディング診断用のレポート拡張エントリポイント。
//  本体アプリ側の DeviceActivityReport(...) の Context と rawValue が一致した
//  シーンだけがシステムに描画される。
//

import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct UsageReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        // シーンは2つだが、本体側の DeviceActivityReport は常に単一インスタンスで
        // context を切り替える (実機検証で確定した唯一動く構成。詳細は
        // TotalActivityReport.swift のコメント参照)
        OnboardingComparisonReport { config in
            ComparisonReportView(config: config)
        }
        OnboardingTopAppsReport { config in
            TopAppsReportView(config: config)
        }
    }
}
