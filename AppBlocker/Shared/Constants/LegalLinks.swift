//
//  LegalLinks.swift
//  AppBlocker
//
//  利用規約 / プライバシーポリシー / サポート連絡先の定数 (M6/M15/M26 対応、2026-07-22)。
//  参照箇所: AppleSignInStepView (同意文言) / SettingsListView (About セクション) /
//  RevenueCatConfig.Legal (ペイウォールの規約・プライバシー行)。
//
//  2026-07-30 本番公開済み (ソースは LegalSite/、Vercel プロジェクト onepercent-legal)。
//  文面を変えたいときは LegalSite/ を編集して `vercel deploy --prod` — URL は不変。
//  英語版は /en/terms・/en/privacy (アプリ内リンクは日本語版に固定、ページ上部で EN 切替可)。
//  Public repository: replace supportEmail with your own support address.
//

import Foundation

enum LegalLinks {

    /// 利用規約の公開 URL
    static let termsURL = URL(string: "https://onepercent-legal.vercel.app/terms")!

    /// プライバシーポリシーの公開 URL
    static let privacyURL = URL(string: "https://onepercent-legal.vercel.app/privacy")!

    /// サポート用メールアドレス (設定 > お問い合わせ の mailto: 先)
    static let supportEmail = "support@example.com"

    /// お問い合わせ行で開く mailto: URL (件名なしのプレーンな新規メール)
    static var supportMailURL: URL? {
        URL(string: "mailto:\(supportEmail)")
    }
}
