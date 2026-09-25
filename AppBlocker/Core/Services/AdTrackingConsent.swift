//
//  AdTrackingConsent.swift
//  AppBlocker
//
//  ATT (App Tracking Transparency) でパーソナライズ広告の可否を決める (2026-08-04)。
//
//  背景: 広告は 2026-07-31 の導入時から「ATT を出さない = 全員が非パーソナライズ (NPA)」で
//  固定してある。パーソナライズの方が eCPM は高い (パーソナライズ比で NPA は3〜5割減 [推測寄り])
//  ため、ユーザー判断で ATT を入れられるように実装だけ先に用意した。
//
//  🔴 出荷スイッチは `isEnabled` ただ1つ。false の間は挙動が導入前と完全に同じ
//  (ダイアログを出さない / NPA 固定のまま / ATTrackingManager を一度も呼ばない)。
//

import Foundation
import AppTrackingTransparency

@MainActor
final class AdTrackingConsent {

    static let shared = AdTrackingConsent()

    /// 🔴 ATT を出荷するかどうかの唯一のスイッチ。
    ///
    /// **true にする前に、必ず以下4点を全部済ませること。コードだけでは完結しない。**
    /// 申告と実装が食い違ったまま提出するとリジェクト事由になる。
    ///
    /// 1. `AppBlocker/Info.plist` に `NSUserTrackingUsageDescription` を追加
    ///    (日本語/英語の両方。「なぜ許可が要るか」を具体的に書く。定型文は弾かれ得る)
    /// 2. `AppBlocker/PrivacyInfo.xcprivacy` の `NSPrivacyTracking` を **true** に変更
    ///    ⚠️ `NSPrivacyTrackingDomains` は現状 Google 側から提供されていない
    ///       (GoogleMobileAds.framework の PrivacyInfo.xcprivacy を実測したところ
    ///        `NSPrivacyTracking` / `NSPrivacyTrackingDomains` のキー自体が存在せず、
    ///        全データ種別が `Tracking = false` だった。2026-08-04, SDK v12.14.0)。
    ///       Apple の規則は「`NSPrivacyTrackingDomains` が空でないなら `NSPrivacyTracking` は true」
    ///       であって逆は必須ではないため、**ドメインを列挙せず true だけ立てる形は成立する**。
    ///       ただし ATT 未許可時に iOS がブロックするのは「どれかのマニフェストに列挙された
    ///       ドメイン」なので、列挙しない = ブロックもされない。ここは提出前に要再確認
    /// 3. App Store Connect の「App のプライバシー」で **トラッキング = はい** に変更し、
    ///    追跡に使うデータ種別 (識別子/使用状況データ等) を申告する
    /// 4. プライバシーポリシーを改訂 → `cd LegalSite && vercel deploy --prod`
    ///
    /// ⚠️ 2026-07-30 に「ATT は導入しない」と決めた時の反対理由はまだ生きている:
    ///   ①「スマホ依存を断つアプリ」がトラッキング許可を求めるブランド矛盾
    ///   ② ダイアログが1枚増えてオンボ/初回体験の離脱が増える
    /// 収益面の前提も確認すること — 広告収益は eCPM × インプレッション数なので、
    /// **DAU が薄いローンチ直後は単価が上がっても金額差がほぼ出ない**。
    static let isEnabled = false

    /// ダイアログ要求の多重実行ガード (フィードは何度でも再表示されるため)
    private var hasRequested = false

    private init() {}

    /// パーソナライズ広告を出してよいか。
    /// - `isEnabled == false` の間は常に false = NPA 固定 (導入前と同じ挙動)
    /// - ATT が未許可/未決定/制限中でも false
    var allowsPersonalizedAds: Bool {
        guard Self.isEnabled else { return false }
        return ATTrackingManager.trackingAuthorizationStatus == .authorized
    }

    /// ATT ダイアログを出す。**広告を最初にリクエストする前に await すること**
    /// (先にリクエストしてしまうと初回ぶんが非パーソナライズで確定する)。
    ///
    /// 呼ぶ場所はフィード初表示時。⚠️ オンボ中には出さない — 作り込んだオンボに
    /// システムダイアログを挟むと完了率が落ちる (2026-07-31 の検討時の結論)。
    /// 2回目以降は OS が現在の状態を即返すだけなので副作用は無いが、念のためガードする。
    func requestIfNeeded() async {
        guard Self.isEnabled, !hasRequested else { return }
        hasRequested = true
        // .notDetermined 以外 (既に許可/拒否済み) なら OS はダイアログを出さない。
        // 無駄な呼び出しを避けるため明示的に弾く
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
