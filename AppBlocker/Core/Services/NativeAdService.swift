//
//  NativeAdService.swift
//  AppBlocker
//
//  Loading/holding AdMob native ads (introduced with ads v1 on 2026-07-31).
//  Policy (project-admob-v1-plan):
//    - Insert only in the feed screens (recommended/following). Never shown on any other surface
//    - No ATT = all requests fixed to non-personalized (publisherPrivacyPersonalizationState)
//    - Never introduce rewarded video or full-screen interstitials
//    - A class fully separate from FeedService (does not pollute the feed fetch logic)
//
//  Slot approach: each "after the Nth item" in the feed gets a slot number (0,1,2…), and
//  the slot→ad mapping is kept stable by indexing into the loaded array. Even when scrolling
//  back and forth, the same slot shows the same ad (shuffling would invite accidental taps).
//

import Foundation
import Combine  // Required for @Published/ObservableObject (lesson from 2026-07-05: it crashes with only Foundation)
import GoogleMobileAds

@MainActor
final class NativeAdService: NSObject, ObservableObject {

    static let shared = NativeAdService()

    /// How often to insert "1 slot every N items" in the feed. The population is thin, so do not pack too
    /// many (initial value 10 as planned)
    static let adInterval = 10

    /// Ad unit ID. ⚠️ Debug builds must always use Google's official test unit.
    /// If a production unit is shown on a real device during development and you tap it yourself, Google
    /// flags it as "invalid traffic", and in the worst case suspends the account = the whole revenue path
    /// is lost. This branch prevents that accident structurally (leaves no room for a human to forget to
    /// swap it).
    ///
    /// ⚠️ TestFlight/App Store builds are Release, so they get the production unit. Do not tap ads that appear
    /// on your own device in a distributed build. If you keep using a real device,
    /// register your device ID in MobileAds.shared.requestConfiguration.testDeviceIdentifiers
    /// (paste the identifier shown in the console on first launch)
    private static var adUnitID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/3986624511"  // Google's official test unit (always a dummy ad)
        #else
        return "ca-app-pub-5685067595656519/2918224217"  // Production: Feed Native
        #endif
    }

    /// Number fetched together in 1 request (SDK max is 5). Enough for one screen of scrolling
    private static let adsPerRequest = 5

    /// Loaded ads. Referenced in rotation with slot number % count
    @Published private(set) var loadedAds: [NativeAd] = []

    private var adLoader: AdLoader?
    private var isLoading = false
    private var sdkStarted = false
    /// Do not retry without limit after failures (prevents hitting it on every scroll due to bad signal etc.)
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    private override init() {
        super.init()
    }

    /// SDK init. Runs only once, when the feed first requests an ad
    /// (not mixed into the launch sequence: ads are a feed-only feature, so they must not slow down the
    /// fastest launch path)
    private func startSDKIfNeeded() {
        guard !sdkStarted else { return }
        sdkStarted = true
        // Whether personalization is allowed for the whole session.
        // While AdTrackingConsent.isEnabled == false (default), always .disabled = same behavior as at
        // introduction. Without this the SDK tries to use identifiers outside the context, which contradicts
        // the App Privacy declaration
        MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState =
            AdTrackingConsent.shared.allowsPersonalizedAds ? .enabled : .disabled

        // Upper limit for the content rating of served ads. Since we declare 13+ in ASC,
        // showing mature (MA) ads would contradict the declaration, so cap at T (teen).
        // As a side effect, ads that do not fit the brand (strongly gambling-like ones etc.) also decrease.
        // tagForChildDirectedTreatment is not set = not a children's app (not available to users under 13)
        MobileAds.shared.requestConfiguration.maxAdContentRating = .teen

        MobileAds.shared.start()
    }

    /// Call when the feed is shown. If not loaded or out of inventory, start fetching (duplicate requests
    /// are guarded)
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

        // Double setting as insurance: also state non-personalized (npa=1) per request.
        // Same meaning as requestConfiguration (whole session), but so that one survives even if the code
        // changes in the future. Remove this fixed value only when ATT permission has been granted (no
        // permission = npa=1 as before)
        let request = Request()
        if !AdTrackingConsent.shared.allowsPersonalizedAds {
            let extras = Extras()
            extras.additionalParameters = ["npa": "1"]
            request.register(extras)
        }
        loader.load(request)
    }

    /// The ad for slot number (0,1,2…). nil if there is no inventory (= that slot is not drawn)
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
        // With a multi-ad request, this failure arrives for the "remaining number that could not be fetched",
        // then didFinishLoading comes. If even 1 was fetched, it counts as a success in practice (decided on
        // the didFinishLoading side)
        print("⚠️ NativeAdService: ad load failed: \(error.localizedDescription)")
        Task { @MainActor in
            self.isLoading = false
            if self.loadedAds.isEmpty {
                self.consecutiveFailures += 1
            }
        }
    }
}
