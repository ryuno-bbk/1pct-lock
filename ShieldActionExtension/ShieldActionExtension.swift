//
//  ShieldActionExtension.swift
//  ShieldActionExtension
//
//  Created by Ryunosuke Ishigami on 2026/01/31.
//
//  Shield画面のボタンアクション処理
//
//  Q7 確定 (2026-05-14): secondaryButton は廃止
//  → ShieldConfigurationExtension で secondaryButtonLabel: nil 設定済み（UI に出ない）
//  → secondaryButtonPressed ケースは switch 網羅のために残すが、何もしない
//

import Foundation
import ManagedSettings

class ShieldActionExtension: ShieldActionDelegate {

    // MARK: - Action Handlers

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            // 廃止済み: 表示されない
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }
}
