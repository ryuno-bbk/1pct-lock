//
//  NativeAdCardView.swift
//  AppBlocker
//
//  フィード内スポンサー投稿カード (AdMob ネイティブ広告、2026-07-31 広告v1)。
//  FeedListCard と同じ骨格 (ヘッダ: アイコン+名前 / 本文行 / 角丸メディア / 下部CTA) に合わせ、
//  「広告」バッジを必ず表示する (景表法ステマ規制 2023-10 施行の法的義務。絶対に外さない)。
//
//  タップ計測とアセット登録の制約上、カード全体を GoogleMobileAds の NativeAdView (UIKit) で
//  組む必要がある。SwiftUI 側は UIViewRepresentable で包み、systemLayoutSizeFitting で
//  高さを提案幅から算出する。AdChoices アイコンは SDK が右上に自動配置する (adChoicesView 未指定時)。
//

import SwiftUI
import UIKit
import GoogleMobileAds

// MARK: - SwiftUI スロット (在庫が無ければ何も描画しない = 枠ごと消える)

struct FeedAdSlot: View {
    /// フィード内で何番目の広告枠か (0,1,2…)。スロット→広告の対応を安定させる
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
        // LazyVStack から提案される幅 (画面幅) に対する高さを AutoLayout に解かせる。
        // 幅未確定の初回パスでは画面幅で仮計算する (カードは常に全幅のため実質同値)
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // ceil が必須: AutoLayout の解は小数点付きで返り、SwiftUI 側の丸めで 1pt 未満だけ
        // 低い高さが割り当てられると、下端の CTA がビュー境界からサブピクセルはみ出す。
        // AdMob の native ad validator はこれを "Advertiser assets outside native ad view"
        // として検出する (2026-07-31 実機で実際に指摘された)。切り上げて必ず収める
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - UIKit カード本体

/// FeedListCard の見た目の写し (UIKit)。配色は AppColors と同値のハードコード
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

        // ヘッダ: アイコン (34pt 丸) + 見出し (投稿者名の位置) + 「広告」バッジ
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

        // 本文行 (投稿タイトル行の位置、最大2行)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = Self.textPrimary.withAlphaComponent(0.92)
        bodyLabel.numberOfLines = 2

        // メディア (角丸 18 = 他カードの画像と同じ。高さはメディア実比率から可変)
        mediaContainerView.translatesAutoresizingMaskIntoConstraints = false
        mediaContainerView.layer.cornerRadius = 18
        mediaContainerView.clipsToBounds = true
        mediaContainerView.backgroundColor = .black

        // CTA: フォローピルと同系の白カプセル (全幅)
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
            // ヘッダ (FeedListCard: leading 14 / top 9 / bottom 8)
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

            // 本文行 (horizontal 14、ヘッダ下 8 / メディア上 9 = titleRow の余白感)
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 8),

            // メディア (全幅・角丸のみ = カードレス構成)
            mediaContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mediaContainerView.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 9),

            // CTA (メディア下 12、下端で高さを閉じる)
            ctaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            ctaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ctaLabel.topAnchor.constraint(equalTo: mediaContainerView.bottomAnchor, constant: 12),
            ctaLabel.heightAnchor.constraint(equalToConstant: 42),
            {
                // 下端だけ優先度を1段落とす: SwiftUI が AutoLayout の理想高さと僅かに違う高さを
                // 割り当てた場合でも、他の制約 (上からのチェーン) を壊して CTA をビュー外へ
                // 押し出すのではなく、この制約が静かに緩んで全アセットが境界内に残るようにする
                let bottom = ctaLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
                bottom.priority = UILayoutPriority(999)
                return bottom
            }(),
        ])

        // SDK へのアセット登録 (これが無いとタップ/インプレッションが計測されず規約違反)
        iconView = iconImageView
        headlineView = nameLabel
        bodyView = bodyLabel
        mediaView = mediaContainerView
        callToActionView = ctaLabel
        // adChoicesView は未指定 = SDK がメディア右上に AdChoices アイコンを自動配置する
    }

    func configure(with ad: NativeAd, isJapanese: Bool) {
        // 「広告」表示は法的義務 (景表法ステマ規制)。ローカライズはするが非表示条件は作らない
        adBadgeLabel.text = isJapanese ? " 広告 " : " Ad "

        nameLabel.text = ad.headline
        iconImageView.image = ad.icon?.image

        bodyLabel.text = ad.body
        bodyLabel.isHidden = (ad.body ?? "").isEmpty

        ctaLabel.text = ad.callToAction
        ctaLabel.isHidden = (ad.callToAction ?? "").isEmpty

        mediaContainerView.mediaContent = ad.mediaContent

        // メディア高さ = 実アスペクト比 (w/h)。フィードのリズムを壊さないよう 4:5 (縦長上限) 〜
        // 1.91:1 (横長下限) にクランプ。比率 0 (未取得) は 1.91:1 (ネイティブ広告の標準横長) 扱い
        let rawRatio = ad.mediaContent.aspectRatio
        let ratio = rawRatio > 0 ? min(max(rawRatio, 0.8), 1.91) : 1.91
        mediaAspectConstraint?.isActive = false
        let aspect = mediaContainerView.widthAnchor.constraint(
            equalTo: mediaContainerView.heightAnchor, multiplier: ratio)
        aspect.priority = .required
        aspect.isActive = true
        mediaAspectConstraint = aspect

        // タッチは NativeAdView 自身がハンドリングする (子ビューが奪うと計測されない)
        for view in [iconImageView, nameLabel, bodyLabel, ctaLabel] as [UIView] {
            view.isUserInteractionEnabled = false
        }

        // 最後に nativeAd を差す (アセット登録が済んでから、が SDK の要求順序)
        nativeAd = ad
    }
}
