//
//  NativeAdCardView.swift
//  AppBlocker
//
//  Sponsored post card in the feed (AdMob native ad, 2026-07-31 ads v1).
//  Matches the same skeleton as FeedListCard (header: icon + name / body line / rounded media / CTA
//  at the bottom), and always shows the "広告" ("Ad") badge (a legal obligation under Japan's
//  stealth marketing rule of the Premiums and Representations Act, in force 2023-10. Never remove it).
//
//  Because of the constraints of tap tracking and asset registration, the whole card must be built
//  with GoogleMobileAds' NativeAdView (UIKit). The SwiftUI side wraps it with UIViewRepresentable and
//  computes the height from the proposed width with systemLayoutSizeFitting. The SDK places the
//  AdChoices icon at the top right automatically (when adChoicesView is not set).
//

import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - SwiftUI slot (draws nothing if there is no inventory = the whole slot disappears)

struct FeedAdSlot: View {
    /// Which ad slot in the feed this is (0,1,2...). Keeps the slot → ad mapping stable
    let slot: Int

    @ObservedObject private var adService = NativeAdService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        if let nativeAd = adService.ad(forSlot: slot) {
            NativeAdCardRepresentable(nativeAd: nativeAd, isJapanese: lang == .japanese)
        }
    }
}

// MARK: - UIViewRepresentable

private struct NativeAdCardRepresentable: UIViewRepresentable {
    let nativeAd: NativeAd
    let isJapanese: Bool

    func makeUIView(context: Context) -> FeedNativeAdView {
        FeedNativeAdView()
    }

    func updateUIView(_ uiView: FeedNativeAdView, context: Context) {
        uiView.configure(with: nativeAd, isJapanese: isJapanese)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FeedNativeAdView, context: Context) -> CGSize? {
        // Let AutoLayout solve the height for the width proposed by LazyVStack (screen width).
        // On the first pass, where the width is not fixed yet, compute provisionally with the screen width
        // (the card is always full width, so it is effectively the same)
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // ceil is required: AutoLayout's solution comes back with decimals, and if SwiftUI's rounding assigns
        // a height lower by less than 1pt, the CTA at the bottom sticks out of the view bounds by a subpixel.
        // AdMob's native ad validator detects this as "Advertiser assets outside native ad view"
        // (it was actually flagged on a real device on 2026-07-31). Round up so it always fits
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - UIKit card body

/// Copy of FeedListCard's look (UIKit). Colors are hardcoded with the same values as AppColors
/// (background #000000 / textPrimary #F2EFE7 / textSecondary #97928A / textTertiary #6E6A63)
final class FeedNativeAdView: NativeAdView {

    private let iconImageView = UIImageView()
    private let nameLabel = UILabel()
    private let adBadgeLabel = UILabel()
    private let bodyLabel = UILabel()
    private let mediaContainerView = MediaView()
    private let ctaLabel = UILabel()
    private var mediaAspectConstraint: NSLayoutConstraint?

    private static let textPrimary = UIColor(red: 0xF2 / 255.0, green: 0xEF / 255.0, blue: 0xE7 / 255.0, alpha: 1)
    private static let textSecondary = UIColor(red: 0x97 / 255.0, green: 0x92 / 255.0, blue: 0x8A / 255.0, alpha: 1)
    private static let textTertiary = UIColor(red: 0x6E / 255.0, green: 0x6A / 255.0, blue: 0x63 / 255.0, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    private func buildLayout() {
        backgroundColor = .black

        // Header: icon (34pt circle) + headline (in the author name position) + "広告" ("Ad") badge
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.layer.cornerRadius = 17
        iconImageView.clipsToBounds = true
        iconImageView.contentMode = .scaleAspectFill
        iconImageView.backgroundColor = Self.textSecondary

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = Self.textPrimary
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        adBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        adBadgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        adBadgeLabel.textColor = Self.textTertiary
        adBadgeLabel.layer.borderColor = Self.textTertiary.cgColor
        adBadgeLabel.layer.borderWidth = 1
        adBadgeLabel.layer.cornerRadius = 4
        adBadgeLabel.textAlignment = .center
        adBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        adBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Body line (in the position of the post title row, max 2 lines)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = Self.textPrimary.withAlphaComponent(0.92)
        bodyLabel.numberOfLines = 2

        // Media (rounded corners 18 = same as the images of other cards. Height varies with the media's real
        // ratio)
        mediaContainerView.translatesAutoresizingMaskIntoConstraints = false
        mediaContainerView.layer.cornerRadius = 18
        mediaContainerView.clipsToBounds = true
        mediaContainerView.backgroundColor = .black

        // CTA: a white capsule in the same family as the follow pill (full width)
        ctaLabel.translatesAutoresizingMaskIntoConstraints = false
        ctaLabel.font = .systemFont(ofSize: 14, weight: .bold)
        ctaLabel.textColor = .black
        ctaLabel.backgroundColor = Self.textPrimary
        ctaLabel.textAlignment = .center
        ctaLabel.layer.cornerRadius = 21
        ctaLabel.clipsToBounds = true

        addSubview(iconImageView)
        addSubview(nameLabel)
        addSubview(adBadgeLabel)
        addSubview(bodyLabel)
        addSubview(mediaContainerView)
        addSubview(ctaLabel)

        NSLayoutConstraint.activate([
            // Header (FeedListCard: leading 14 / top 9 / bottom 8)
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            iconImageView.widthAnchor.constraint(equalToConstant: 34),
            iconImageView.heightAnchor.constraint(equalToConstant: 34),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 9),
            nameLabel.centerYAnchor.constraint(equalTo: iconImageView.centerYAnchor),

            adBadgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            adBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            adBadgeLabel.centerYAnchor.constraint(equalTo: iconImageView.centerYAnchor),
            adBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            adBadgeLabel.heightAnchor.constraint(equalToConstant: 20),

            // Body line (horizontal 14, 8 below the header / 9 above the media = the spacing feel of titleRow)
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 8),

            // Media (full width, rounded corners only = cardless layout)
            mediaContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mediaContainerView.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 9),

            // CTA (12 below the media, closes the height at the bottom edge)
            ctaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            ctaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ctaLabel.topAnchor.constraint(equalTo: mediaContainerView.bottomAnchor, constant: 12),
            ctaLabel.heightAnchor.constraint(equalToConstant: 42),
            {
                // Lower the priority of only the bottom constraint by one step: even if SwiftUI assigns a height
                // slightly different from AutoLayout's ideal height, instead of breaking the other constraints (the
                // chain from the top) and pushing the CTA out of the view, this constraint quietly loosens and all
                // assets stay inside the bounds
                let bottom = ctaLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
                bottom.priority = UILayoutPriority(999)
                return bottom
            }(),
        ])

        // Register the assets with the SDK (without this, taps/impressions are not tracked, which violates the
        // policy)
        iconView = iconImageView
        headlineView = nameLabel
        bodyView = bodyLabel
        mediaView = mediaContainerView
        callToActionView = ctaLabel
        // adChoicesView is not set = the SDK places the AdChoices icon at the top right of the media
        // automatically
    }

    func configure(with ad: NativeAd, isJapanese: Bool) {
        // Showing "広告" ("Ad") is a legal obligation (Japan's stealth marketing rule). It is localized, but
        // no condition to hide it is ever added
        adBadgeLabel.text = isJapanese ? " 広告 " : " Ad "

        nameLabel.text = ad.headline
        iconImageView.image = ad.icon?.image

        bodyLabel.text = ad.body
        bodyLabel.isHidden = (ad.body ?? "").isEmpty

        ctaLabel.text = ad.callToAction
        ctaLabel.isHidden = (ad.callToAction ?? "").isEmpty

        mediaContainerView.mediaContent = ad.mediaContent

        // Media height = real aspect ratio (w/h). Clamped between 4:5 (tallest) and
        // 1.91:1 (widest) so the feed rhythm is not broken. A ratio of 0 (not fetched) is treated as 1.91:1
        // (the standard wide native ad)
        let rawRatio = ad.mediaContent.aspectRatio
        let ratio = rawRatio > 0 ? min(max(rawRatio, 0.8), 1.91) : 1.91
        mediaAspectConstraint?.isActive = false
        let aspect = mediaContainerView.widthAnchor.constraint(
            equalTo: mediaContainerView.heightAnchor, multiplier: ratio)
        aspect.priority = .required
        aspect.isActive = true
        mediaAspectConstraint = aspect

        // Touches are handled by NativeAdView itself (if child views take them, they are not tracked)
        for view in [iconImageView, nameLabel, bodyLabel, ctaLabel] as [UIView] {
            view.isUserInteractionEnabled = false
        }

        // Set nativeAd last (the SDK requires this order: only after the assets are registered)
        nativeAd = ad
    }
}
