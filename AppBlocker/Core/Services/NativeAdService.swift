//
//  NativeAdService.swift
//  AppBlocker
//
//  AdMob ネイティブ広告のロード/保持 (2026-07-31 広告v1導入)。
//  方針 (project-admob-v1-plan):
//    - フィード画面 (おすすめ/フォロー中) のみに差し込む。他の面には一切出さない
//    - ATT は出さない = 全リクエストを非パーソナライズ固定 (publisherPrivacyPersonalizationState)
//    - 報酬型動画・全画面インタースティシャルは絶対に導入しない
//    - FeedService とは完全に別クラス (フィード取得ロジックを汚さない)
//
//  スロット方式: フィードの「N件目の後」ごとにスロット番号 (0,1,2…) が振られ、
//  スロット→広告の対応はロード済み配列へのインデックスで安定させる。スクロールで
//  行き来しても同じスロットには同じ広告が出る (シャッフルされるとタップ誤爆を誘発するため)。
//

import Foundation
import Combine  // @Published/ObservableObject に必須 (2026-07-05 の教訓: Foundation だけでは落ちる)
import GoogleMobileAds

@MainActor
final class NativeAdService: NSObject, ObservableObject {

    static let shared = NativeAdService()

    /// フィードで「何件ごとに1枠」差し込むか。母数が薄いので詰めすぎない (初期値は計画どおり10)
    static let adInterval = 10

    /// 広告ユニットID。⚠️ デバッグビルドでは必ず Google 公式のテストユニットを使う。
    /// 開発中の実機で本番ユニットを表示して自分でタップすると、Google は「無効なトラフィック」
    /// と判定し、最悪アカウント停止 = 収益経路ごと失う。この分岐がその事故を構造的に防ぐ
    /// (人間が差し替えを忘れる余地を残さない)。
    ///
    /// ⚠️ TestFlight/App Store ビルドは Release のため本番ユニットが入る。配信ビルドで
    /// 自分の端末に出た広告はタップしないこと。継続的に実機で触るなら
    /// MobileAds.shared.requestConfiguration.testDeviceIdentifiers に自端末IDを登録する
    /// (初回起動時のコンソールに出る識別子を貼る)
    private static var adUnitID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/3986624511"  // Google 公式テストユニット (常にダミー広告)
        #else
        return "ca-app-pub-5685067595656519/2918224217"  // 本番: Feed Native
        #endif
    }

    /// 1回のリクエストでまとめて取る件数 (SDK 上限は5)。1画面分のスクロールで足りる量
    private static let adsPerRequest = 5

    /// ロード済み広告。スロット番号 % count でローテーション参照する
    @Published private(set) var loadedAds: [NativeAd] = []

    private var adLoader: AdLoader?
    private var isLoading = false
    private var sdkStarted = false
    /// 失敗時の再試行を無制限にしない (電波状況等で毎スクロールごとに叩くのを防ぐ)
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    private override init() {
        super.init()
    }

    /// SDK 初期化。フィードが最初に広告を要求した時に一度だけ走らせる
    /// (起動シーケンスに混ぜない: 広告はフィード限定機能で、起動の最速経路を汚さないため)
    private func startSDKIfNeeded() {
        guard !sdkStarted else { return }
        sdkStarted = true
        // セッション全体のパーソナライズ可否。
        // AdTrackingConsent.isEnabled == false (既定) の間は常に .disabled = 導入時と同じ挙動。
        // これが無いと SDK はコンテキスト外の識別子利用を試み、App Privacy の申告と食い違う
        MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState =
            AdTrackingConsent.shared.allowsPersonalizedAds ? .enabled : .disabled

        // 配信される広告の内容レーティング上限。ASC で 13+ を申告している以上、
        // 成人向け (MA) の広告が出るのは申告と矛盾するため T (ティーン) で頭を打つ。
        // 副次効果としてブランドに合わない広告 (射幸性の強いもの等) も減る。
        // tagForChildDirectedTreatment は設定しない = 児童向けアプリではない (13歳未満は利用不可)
        MobileAds.shared.requestConfiguration.maxAdContentRating = .teen

        MobileAds.shared.start()
    }

    /// フィード表示時に呼ぶ。未ロード or 在庫ゼロなら取得を開始する (多重リクエストはガード)
    func preloadIfNeeded() {
        guard loadedAds.isEmpty, !isLoading,
              consecutiveFailures < Self.maxConsecutiveFailures else { return }
        startSDKIfNeeded()
        isLoading = true

        let options = MultipleAdsAdLoaderOptions()
        options.numberOfAds = Self.adsPerRequest

        let loader = AdLoader(
            adUnitID: Self.adUnitID,
            rootViewController: nil,
            adTypes: [.native],
            options: [options]
        )
        loader.delegate = self
        adLoader = loader

        // 保険の二重指定: リクエスト単位でも非パーソナライズ (npa=1) を明示する。
        // requestConfiguration (セッション全体) と同義だが、将来コードが動いても片方が生き残るように。
        // ATT で許可が取れている時だけこの固定を外す (許可が無い = 従来どおり npa=1)
        let request = Request()
        if !AdTrackingConsent.shared.allowsPersonalizedAds {
            let extras = Extras()
            extras.additionalParameters = ["npa": "1"]
            request.register(extras)
        }
        loader.load(request)
    }

    /// スロット番号 (0,1,2…) に対応する広告。在庫が無ければ nil (= その枠は描画しない)
    func ad(forSlot slot: Int) -> NativeAd? {
        guard !loadedAds.isEmpty else { return nil }
        return loadedAds[slot % loadedAds.count]
    }
}

// MARK: - NativeAdLoaderDelegate

extension NativeAdService: NativeAdLoaderDelegate {

    nonisolated func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        Task { @MainActor in
            self.loadedAds.append(nativeAd)
        }
    }

    nonisolated func adLoaderDidFinishLoading(_ adLoader: AdLoader) {
        Task { @MainActor in
            self.isLoading = false
            if !self.loadedAds.isEmpty {
                self.consecutiveFailures = 0
            }
        }
    }

    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        // 複数件リクエストでは「取れなかった残数」ぶんこの失敗が届き、その後 didFinishLoading が来る。
        // 1件でも取れていれば運用上は成功扱い (didFinishLoading 側で判定)
        print("⚠️ NativeAdService: ad load failed: \(error.localizedDescription)")
        Task { @MainActor in
            self.isLoading = false
            if self.loadedAds.isEmpty {
                self.consecutiveFailures += 1
            }
        }
    }
}
