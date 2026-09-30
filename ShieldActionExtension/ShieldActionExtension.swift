//
//  ShieldActionExtension.swift
//  ShieldActionExtension
//
//  Created by Ryunosuke Ishigami on 2026/01/31.
//
//  Button actions of the Shield screen
//
//  Q7 finalized (2026-05-14): secondaryButton removed
//  → secondaryButtonLabel: nil already set in ShieldConfigurationExtension (not shown in the UI)
//  → the secondaryButtonPressed case stays for switch exhaustiveness, but does nothing
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
            // Removed: never shown
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
