//
//  RevenueCatConfig.swift
//  AppBlocker
//
//  RevenueCat の定数 (2026-07-18 ユーザーがダッシュボードで設定した値)。
//  Public SDK Key はアプリに埋め込む前提の公開キー (秘密情報ではない)。
//  Secret Key (sk_) や In-App Purchase Key (.p8) は絶対にリポジトリへ入れないこと。
//

import Foundation
// SPM の RevenueCat がターゲットに正しくリンクされているかの検証を兼ねる
// (2026-07-18 パッケージ追加直後の確認。本格利用は PurchaseService から)
import RevenueCat

enum RevenueCatConfig {
    /// Public SDK Key (Apple)。RevenueCat → API keys → appl_...
    static let apiKey = "appl_RCPtBnrpBaYNDrRBskkzwqlXwgj"

    /// 課金状態を1本で表す entitlement ID (monthly / yearly / lifetime 全てがこれを付与)。
    /// 注意: RevenueCat ダッシュボードで実際に作られた識別子は "1% Pro" (スペース込み)。
    /// 識別子は作成後に変更不可のため、コード側をこれに合わせている (2026-07-19 サンドボックスで発覚)。
    /// Supabase/functions/revenuecat-webhook/index.ts の PRO_ENTITLEMENT と常に一致させること。
    static let proEntitlementID = "1% Pro"

    /// App Store Connect の製品ID (Offerings 経由で取得するため通常は直接参照しない。
    /// デバッグ・ログ用の参照値)
    enum ProductID {
        static let monthly  = "onepercent.pro.monthly"
        static let yearly   = "onepercent.pro.yearly"
        static let lifetime = "onepercent.pro.lifetime"
    }

    enum Legal {
        /// 自前の利用規約 (2026-07-30 公開。Apple 必須の EULA 最低条項は規約第13条に収録済みのため
        /// Apple 標準EULA から差し替え)
        static let termsOfUse = LegalLinks.termsURL
        /// プライバシーポリシー (2026-07-30 公開。審査必須のペイウォール表示が有効化される)
        static let privacyPolicy: URL? = LegalLinks.privacyURL
    }
}
