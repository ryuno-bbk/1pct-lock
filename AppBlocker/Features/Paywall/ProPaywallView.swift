//
//  ProPaywallView.swift
//  AppBlocker
//
//  Pro 機能ペイウォール v4 (2026-07-19 Retro参照のユーザー指定で全面改装)。
//  - 白黒基調 (金ベースは「かっこよくない」で廃止)
//  - ヒーロー: 夢画像を大きく流し、下部を暗くして見出しを被せる
//  - プランは Retro 式の大きいスワイプカード (機能リスト内蔵、無料/Pro 比較表は廃止)
//  - 「無制限」等の誇張はしない (正直表示: 実請求額主表示+自動更新の開示文)
//  価格は RevenueCat Offerings の実価格のみ。購入/復元は PurchaseService 経由。
//

import SwiftUI
import RevenueCat

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchaseService = PurchaseService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// 表示のきっかけになった機能（ヘッダーに表示）
    let triggeredBy: BlockMode

    /// オンボーディング等、シートではない文脈に埋め込む場合の「閉じる」動作。
    /// nil (既定) なら通常どおり dismiss する
    var onClose: (() -> Void)? = nil

    /// スワイプカードの現在ページ = 選択中プラン (viewAligned ページングと連動)。
    /// 初期値は一番左の月額 (2026-07-19 ユーザー決定)。年額を初期にすると、カードが
    /// 価格ロード後に生成される都合で初期スクロールが効かず「表示ページと選択がズレる」
    /// バグの温床になる + 左に月額が見切れて怪しく見えるため
    @State private var scrolledPlan: PlanOption? = .monthly
    @State private var alertMessage: String = ""
    @State private var showAlert = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private enum PlanOption: Hashable {
        case yearly, monthly, lifetime
    }

    private var selectedPlan: PlanOption { scrolledPlan ?? .monthly }

    var body: some View {
        ZStack {
            // 真っ黒 + 白のかすかなグロウ (白黒基調、2026-07-19 ユーザー指定)
            AppColors.background
                .ignoresSafeArea()
            RadialGradient(
                colors: [Color.white.opacity(0.06), .clear],
                center: .init(x: 0.5, y: 0.05),
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    // 小タイトル (アイコンなし、2026-07-19 ユーザー決定)。
                    // プラン名は「1% エリート / 1% Elite」で確定 (ASCのサブスク表示名と統一)。
                    // 内部ID (entitlement "1% Pro" / ProAccess等) は表示名と別物なので変更しない
                    Text(lang == .japanese ? "1% エリート" : "1% Elite")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                        .tracking(0.5)
                        .padding(.top, 10)

                    // ヒーロー: 写真を大きく流し、下部を暗くして見出しを被せる
                    heroSection
                        .padding(.horizontal, -24)

                    // 一番大事な訴求 (2026-07-19 ユーザー口述。文言は添削待ち)
                    Text(lang == .japanese
                        ? "事前に決めたスケジュールと場所で、意思と関係なく自動ロック。本気で人生を変えたい人へ。"
                        : "Auto-lock by schedule and location — no willpower required. For people serious about changing their life.")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)

                    // プラン: Retro 式の大きいスワイプカード
                    planCarousel
                        .padding(.horizontal, -24)

                    pageDots

                    // CTA + 開示文 + リンク行 (隙間は詰める、2026-07-19 ユーザー指定)
                    footerSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }

            // 閉じるボタン
            VStack {
                HStack {
                    Spacer()
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(AppColors.cardBackground)
                            )
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 16)
                }
                Spacer()
            }
        }
        .task {
            if purchaseService.packages.isEmpty {
                await purchaseService.loadOfferings()
            }
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Hero (写真マルキー + 暗幕 + 見出し被せ)

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            DreamImageMarquee(cardWidth: 190, cardHeight: 250)

            // 下部を暗くして文字を載せる (背景色へ溶かすことでページと一体化)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: AppColors.background.opacity(0.55), location: 0.55),
                    .init(color: AppColors.background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 170)
            .allowsHitTesting(false)

            // 文言は添削待ち
            Text(lang == .japanese ? "未来の理想の自分になる" : "Become your future self")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 2)
        }
    }

    // MARK: - Plan Carousel (Retro式スワイプカード)

    /// 表示順: 月額 → 年額 (初期表示・バッジ) → 買い切り
    private var availablePlans: [(plan: PlanOption, package: Package)] {
        var result: [(PlanOption, Package)] = []
        if let monthly = purchaseService.monthlyPackage { result.append((.monthly, monthly)) }
        if let yearly = purchaseService.yearlyPackage { result.append((.yearly, yearly)) }
        if let lifetime = purchaseService.lifetimePackage { result.append((.lifetime, lifetime)) }
        return result
    }

    @ViewBuilder
    private var planCarousel: some View {
        if purchaseService.isLoadingOfferings {
            ProgressView()
                .tint(AppColors.textSecondary)
                .frame(height: 250)
        } else if purchaseService.offeringsLoadFailed || availablePlans.isEmpty {
            VStack(spacing: 12) {
                Text(lang == .japanese ? "価格を読み込めませんでした" : "Couldn't load prices")
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textSecondary)

                Button {
                    Task { await purchaseService.loadOfferings() }
                } label: {
                    Text(lang == .japanese ? "再試行" : "Retry")
                        .font(AppTypography.buttonSmall)
                        .foregroundColor(AppColors.textPrimary)
                }
            }
            .frame(height: 250)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(availablePlans, id: \.plan) { item in
                        planCard(for: item.package, plan: item.plan)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length * 0.78   // 次のカードを覗かせる (Retro式)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledPlan)
        }
    }

    private func planCard(for package: Package, plan: PlanOption) -> some View {
        // 中央 (選択中) のカードを明確に見せる: 明るい枠+チェック、脇のカードは減光。
        // 「年額のつもりが買い切りを買った」事故の防止 (2026-07-19 ユーザーFB)
        let isSelected = plan == selectedPlan

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(planTitle(plan))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                if plan == .yearly, let badge = yearlyBadgeText {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white))
                }
                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? Color.white : Color.white.opacity(0.2))
            }

            // プラン別の対象者一言 (2026-07-19 ユーザー口述ベース。文言は添削待ち)
            Text(planTagline(plan))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 10) {
                featureLine(icon: "calendar.badge.clock",
                            text: lang == .japanese ? "スケジュール制限" : "Schedule blocking")
                featureLine(icon: "location.fill",
                            text: lang == .japanese ? "位置情報ロック" : "Location lock")
                featureLine(icon: "lock.fill",
                            text: lang == .japanese ? "意志に頼らない自動ロック" : "Auto-lock, no willpower needed") // 文言は添削待ち
                // 2026-09-09 追加。🔴 アイコンは lock.fill と被らないよう nosign
                //    (ハードモードの本質は「解除の手段が無い」ことなので、盾や炎より正確)
                featureLine(icon: "nosign",
                            text: lang == .japanese ? "解除できないハードロックモード" : "Hard lock mode you can't undo") // 英語は添削待ち
            }
            .padding(.top, 14)

            Spacer(minLength: 12)

            // 🔴 2026-09-09 実機FB: 「月あたり◯円」を価格の下に積むと縦が詰まる
            //    (特典が4行になったので余計に)。同じ行の右側へ、下端を揃えて置く。
            //    lastTextBaseline なので小さい文字が大きい価格の足元に来る = 「右下」
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(priceMainText(for: package, plan: plan))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(priceSubText(for: package, plan: plan))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }

            // トライアル資格がある場合は価格の直下でも明示 (バッジだけだと見落とされる)
            if plan == .yearly && purchaseService.yearlyTrialEligible {
                Text(lang == .japanese ? "3日間の無料トライアル付き" : "Includes a 3-day free trial")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 6)
            }
        }
        .padding(18)
        // 特典が3行→4行になった分だけ伸ばす (2026-09-09)
        .frame(height: 288)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppColors.cardBackground.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1)
        )
        .opacity(isSelected ? 1 : 0.55)
        .animation(.easeOut(duration: 0.18), value: scrolledPlan)
    }

    private func featureLine(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    /// 年額カードのバッジ。トライアル資格ありなら「3日間無料」、なければ「おすすめ」(文言は添削待ち)
    private var yearlyBadgeText: String? {
        if purchaseService.yearlyTrialEligible {
            return lang == .japanese ? "3日間無料" : "3 days free"
        }
        return lang == .japanese ? "おすすめ" : "Best value"
    }

    /// プラン別の対象者一言 (月額=お試し / 年額=1年間の覚悟 / 買い切り=一生の覚悟)
    private func planTagline(_ plan: PlanOption) -> String {
        switch plan {
        case .monthly:
            return lang == .japanese ? "まずは試したい人に" : "For trying it out first"
        case .yearly:
            return lang == .japanese ? "1年間、本気を出す覚悟が決まった人に" : "For those committed to a serious year"
        case .lifetime:
            return lang == .japanese ? "一生共にする覚悟のある人に" : "For those committed for life"
        }
    }

    private func planTitle(_ plan: PlanOption) -> String {
        switch plan {
        case .yearly:   return lang == .japanese ? "年額" : "Yearly"
        case .monthly:  return lang == .japanese ? "月額" : "Monthly"
        case .lifetime: return lang == .japanese ? "買い切り" : "Lifetime"
        }
    }

    /// 実請求額の主表示 (正直表示: 週割り等で安く見せない)
    private func priceMainText(for package: Package, plan: PlanOption) -> String {
        switch plan {
        case .yearly:   return "\(package.localizedPriceString)\(lang == .japanese ? "/年" : "/yr")"
        case .monthly:  return "\(package.localizedPriceString)\(lang == .japanese ? "/月" : "/mo")"
        case .lifetime: return package.localizedPriceString
        }
    }

    private func priceSubText(for package: Package, plan: PlanOption) -> String {
        switch plan {
        case .yearly:
            if let m = monthlyEquivalentString(for: package) {
                return lang == .japanese ? "月あたり \(m)" : "\(m)/mo equivalent"
            }
            return lang == .japanese ? "12か月分の一括請求" : "Billed once a year"
        case .monthly:
            return lang == .japanese ? "毎月の請求" : "Billed monthly"
        case .lifetime:
            return lang == .japanese ? "一度きり・自動更新なし" : "One-time payment, no renewal"
        }
    }

    /// 年額プランの「月あたり換算」。実請求額 (年額) が主役で、これは副表示
    private func monthlyEquivalentString(for package: Package) -> String? {
        let product = package.storeProduct
        guard let formatter = product.priceFormatter else { return nil }
        let perMonth = product.pricePerMonth ?? NSDecimalNumber(decimal: product.price / 12)
        return formatter.string(from: perMonth)
    }

    // MARK: - Page Dots

    @ViewBuilder
    private var pageDots: some View {
        if availablePlans.count > 1 {
            HStack(spacing: 6) {
                ForEach(availablePlans, id: \.plan) { item in
                    Circle()
                        .fill(item.plan == selectedPlan ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    // MARK: - Footer (CTA + 開示文 + リンク行、ビチビチに詰める)

    private var selectedPackage: Package? {
        availablePlans.first(where: { $0.plan == selectedPlan })?.package
    }

    // CTA は成果文言 (「購入する」系より「始める」系)。文言はユーザー添削待ち
    private var ctaTitle: String {
        if selectedPlan == .yearly && purchaseService.yearlyTrialEligible {
            return lang == .japanese ? "3日間無料で始める" : "Start 3-day free trial"
        }
        return lang == .japanese ? "1% エリートを始める" : "Start 1% Elite"
    }

    private var footerSection: some View {
        VStack(spacing: 10) {
            PrimaryButton(
                ctaTitle,
                icon: purchaseService.isPurchasing ? nil : "sparkles",
                isLoading: purchaseService.isPurchasing,
                isDisabled: selectedPackage == nil || purchaseService.isPurchasing
            ) {
                purchaseTapped()
            }

            // 正直表示の開示文 (隠さない・実額入り)
            if let disclosure = disclosureText {
                Text(disclosure)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            // 復元 / 規約 は1行に集約 (隙間を詰める)。
            // 「あとで」は 2026-07-31 実機FBで撤去 — 右上の × と役割が重複していた
            // (閉じる導線は × 一本に統一)。復元・規約・プライバシーは Apple 要件なので残す
            HStack(spacing: 18) {
                Button {
                    restoreTapped()
                } label: {
                    Text(lang == .japanese ? "購入を復元" : "Restore")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                }

                Link(lang == .japanese ? "利用規約" : "Terms",
                     destination: RevenueCatConfig.Legal.termsOfUse)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textTertiary)

                if let privacyURL = RevenueCatConfig.Legal.privacyPolicy {
                    Link(lang == .japanese ? "プライバシー" : "Privacy", destination: privacyURL)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            .padding(.top, 2)
        }
    }

    /// 正直表示の開示文 (選択プランに応じて動的、実額入り)
    private var disclosureText: String? {
        guard let package = selectedPackage else { return nil }
        let price = package.localizedPriceString

        switch selectedPlan {
        case .yearly:
            if purchaseService.yearlyTrialEligible {
                return lang == .japanese
                    ? "3日間の無料トライアル終了後、\(price)/年で自動更新されます。トライアル終了の24時間前までに App Store の設定から解約すれば料金はかかりません。"
                    : "After the 3-day free trial, this renews at \(price)/yr. Cancel anytime in App Store settings at least 24 hours before the trial ends to avoid being charged."
            } else {
                return lang == .japanese
                    ? "\(price)/年で自動更新されます。いつでも App Store の設定から解約できます。"
                    : "Renews automatically at \(price)/yr. Cancel anytime in App Store settings."
            }
        case .monthly:
            return lang == .japanese
                ? "\(price)/月で自動更新されます。いつでも App Store の設定から解約できます。"
                : "Renews automatically at \(price)/mo. Cancel anytime in App Store settings."
        case .lifetime:
            return lang == .japanese
                ? "\(price)の一度のお支払いです。自動更新はありません。"
                : "This is a one-time payment of \(price). No auto-renewal."
        }
    }

    // MARK: - Actions

    private func purchaseTapped() {
        guard let package = selectedPackage else { return }
        Task {
            let outcome = await purchaseService.purchase(package)
            switch outcome {
            case .success:
                close()
            case .cancelled:
                break
            case .failed(let message):
                showError(message)
            }
        }
    }

    private func restoreTapped() {
        Task {
            let outcome = await purchaseService.restore()
            switch outcome {
            case .restored:
                close()
            case .nothingToRestore:
                showError(lang == .japanese
                    ? "復元できる購入が見つかりませんでした"
                    : "No purchases to restore")
            case .failed(let message):
                showError(message)
            }
        }
    }

    /// 閉じる動作の一本化: オンボ埋め込み時は onClose、シート表示時は dismiss
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func showError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - Dream Image Marquee

/// 夢画像デッキ (OnboardingDreamAssets.deck) を角丸カードでゆっくり横に流し続けるマルキー。
/// Retro のペイウォール上部を参照 (2026-07-19 ユーザー指定)。
/// シームレスループ: カード列を2セット横に並べ、1セットぶんの幅だけ等速で流したら巻き戻す。
private struct DreamImageMarquee: View {
    var cardWidth: CGFloat = 118
    var cardHeight: CGFloat = 150
    var gap: CGFloat = 12
    /// 流速 (pt/秒)。「気づいたら動いている」程度のゆっくりさ
    var speed: CGFloat = 22

    /// アセット未投入の名前は自動で除外 (OnboardingDreamAssets の設計と同じ)
    private let images: [String] = OnboardingDreamAssets.deck.filter { UIImage(named: $0) != nil }

    @State private var startDate = Date()

    var body: some View {
        // 重要: 幅2セットぶん (~2,800pt) の HStack を「レイアウト上の子」として置くと、
        // その幅が親 VStack に伝播してページ全体が横に引き伸ばされる (2026-07-19 実機バグ)。
        // Color.clear を土台にして overlay で載せることで、マルキーの中身の幅を
        // レイアウト計算から切り離す (overlay の中身は親のサイズに影響しない)
        Color.clear
            .frame(height: cardHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if !images.isEmpty {
                    let setWidth = CGFloat(images.count) * (cardWidth + gap)
                    // ProMotion 120Hz 対策: 30fps に上限 (等速マルキーなので視覚差はない)。
                    // Reduce Motion 設定時は TimelineView 自体を止めて静止表示にする
                    // (OnboardingQuiz.swift の CountUpNumber と同じ流儀)。
                    // drawingGroup() は幅約4,400ptのHStack全体が対象になり巨大テクスチャで
                    // 逆効果の恐れがあるためここでは適用しない
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: UIAccessibility.isReduceMotionEnabled)) { context in
                        let elapsed = context.date.timeIntervalSince(startDate)
                        let offset = CGFloat(elapsed.truncatingRemainder(dividingBy: Double(setWidth / speed))) * speed
                        HStack(spacing: gap) {
                            ForEach(0..<2, id: \.self) { _ in
                                HStack(spacing: gap) {
                                    ForEach(images, id: \.self) { name in
                                        Image(name)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: cardWidth, height: cardHeight)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                }
                            }
                        }
                        .offset(x: -offset)
                        .frame(width: setWidth, height: cardHeight, alignment: .leading)
                    }
                }
            }
            .clipped()
    }
}

#Preview {
    ProPaywallView(triggeredBy: .schedule)
}
