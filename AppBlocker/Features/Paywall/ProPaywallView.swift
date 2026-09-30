//
//  ProPaywallView.swift
//  AppBlocker
//
//  Paywall for Pro features v4 (fully redesigned 2026-07-19 per user spec, with Retro as reference).
//  - Black-and-white base (the gold base was dropped as "not cool")
//  - Hero: dream images scroll large, the bottom is darkened and the headline sits on top
//  - Plans are big Retro-style swipe cards (feature list built in, the free/Pro comparison table was
//    removed)
//  - No exaggeration like "unlimited" (honest display: the actual charge as the main figure +
//    auto-renew disclosure)
//  Prices come only from the real prices in RevenueCat Offerings. Purchase/restore go through
//  PurchaseService.
//

import SwiftUI
import RevenueCat

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchaseService = PurchaseService.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    /// The feature that triggered the display (shown in the header)
    let triggeredBy: BlockMode

    /// The "close" action when embedded in a non-sheet context such as onboarding.
    /// If nil (default), dismiss as usual
    var onClose: (() -> Void)? = nil

    /// Current page of the swipe cards = selected plan (linked with viewAligned paging).
    /// The initial value is monthly, the leftmost (user decision 2026-07-19). If yearly were the initial
    /// value, the cards are created after prices load, so the initial scroll does not take effect and it
    /// becomes a breeding ground for the bug "shown page and selection don't match" + monthly is cut off on
    /// the left, which looks suspicious
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
            // Pure black + a faint white glow (black-and-white base, user specified 2026-07-19)
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
                    // Small title (no icon, user decision 2026-07-19).
                    // The plan name is finalized as "1% エリート" ("1% Elite") / "1% Elite" (same as the subscription display
                    // name in ASC). Internal IDs (entitlement "1% Pro" / ProAccess etc.) are separate from the display
                    // name, so do not change them
                    Text(lang == .japanese ? "1% エリート" : "1% Elite")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                        .tracking(0.5)
                        .padding(.top, 10)

                    // Hero: the photos scroll large, the bottom is darkened and the headline sits on top
                    heroSection
                        .padding(.horizontal, -24)

                    // The most important pitch (dictated by the user 2026-07-19. Wording pending review)
                    Text(lang == .japanese
                        ? "事前に決めたスケジュールと場所で、意思と関係なく自動ロック。本気で人生を変えたい人へ。"
                        : "Auto-lock by schedule and location — no willpower required. For people serious about changing their life.")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)

                    // Plans: big Retro-style swipe cards
                    planCarousel
                        .padding(.horizontal, -24)

                    pageDots

                    // CTA + disclosure + link row (tighten the gaps, user specified 2026-07-19)
                    footerSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }

            // Close button
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

    // MARK: - Hero (photo marquee + dark overlay + headline on top)

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            DreamImageMarquee(cardWidth: 190, cardHeight: 250)

            // Darken the bottom to put text on it (blends into the background color so it is one with the page)
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

            // Wording pending review
            Text(lang == .japanese ? "未来の理想の自分になる" : "Become your future self")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 2)
        }
    }

    // MARK: - Plan Carousel (Retro-style swipe cards)

    /// Display order: monthly → yearly (initial display, badge) → lifetime
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
                                length * 0.78   // let the next card peek in (Retro style)
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
        // Make the center (selected) card clearly visible: bright border + check, side cards dimmed.
        // Prevents the accident "meant to buy yearly but bought lifetime" (user feedback 2026-07-19)
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

            // One line per plan about who it is for (based on what the user dictated 2026-07-19. Wording pending
            // review)
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
                            text: lang == .japanese ? "意志に頼らない自動ロック" : "Auto-lock, no willpower needed") // Wording pending review
                // Added 2026-09-09. 🔴 The icon is nosign so it does not clash with lock.fill
                //    (the essence of hard mode is "there is no way to unlock", so this is more accurate than a shield
                //    or flame)
                featureLine(icon: "nosign",
                            text: lang == .japanese ? "解除できないハードロックモード" : "Hard lock mode you can't undo") // English pending review
            }
            .padding(.top, 14)

            Spacer(minLength: 12)

            // 🔴 2026-09-09 real device feedback: stacking "月あたり◯円" ("◯ yen per month") under the price makes it
            //    too tight vertically (even more so now that the perks are 4 lines). Put it on the right side of
            //    the same line, bottom-aligned. With lastTextBaseline the small text sits at the foot of the big
            //    price = "bottom right"
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

            // If eligible for the trial, also state it right below the price (the badge alone gets missed)
            if plan == .yearly && purchaseService.yearlyTrialEligible {
                Text(lang == .japanese ? "3日間の無料トライアル付き" : "Includes a 3-day free trial")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 6)
            }
        }
        .padding(18)
        // Taller by the amount the perks grew from 3 lines → 4 lines (2026-09-09)
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

    /// Badge on the yearly card. "3日間無料" ("3 days free") if eligible for the trial, otherwise "おすすめ"
    /// ("Recommended") (wording pending review)
    private var yearlyBadgeText: String? {
        if purchaseService.yearlyTrialEligible {
            return lang == .japanese ? "3日間無料" : "3 days free"
        }
        return lang == .japanese ? "おすすめ" : "Best value"
    }

    /// One line per plan about who it is for (monthly = trying it out / yearly = commitment for 1 year /
    /// lifetime = commitment for life)
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

    /// Main display of the actual charge (honest display: do not make it look cheaper with per-week splits
    /// etc.)
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

    /// "Per-month equivalent" of the yearly plan. The actual charge (yearly) is the main figure; this is
    /// secondary
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

    // MARK: - Footer (CTA + disclosure + link row, packed tightly)

    private var selectedPackage: Package? {
        availablePlans.first(where: { $0.plan == selectedPlan })?.package
    }

    // The CTA uses outcome wording ("start"-type rather than "buy"-type). Wording pending user review
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

            // Disclosure for honest display (nothing hidden, includes the actual amount)
            if let disclosure = disclosureText {
                Text(disclosure)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            // Restore / Terms are put on one line (tighten the gaps).
            // "あとで" ("Later") was removed after 2026-07-31 real device feedback: it duplicated the role of the ×
            // at the top right (the close path is unified on the × only). Restore, Terms and Privacy stay because
            // Apple requires them
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

    /// Disclosure for honest display (dynamic by selected plan, includes the actual amount)
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

    /// Single close action: onClose when embedded in onboarding, dismiss when shown as a sheet
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

/// A marquee that keeps slowly scrolling the dream image deck (OnboardingDreamAssets.deck) sideways as
/// rounded cards. Based on the top of Retro's paywall (user specified 2026-07-19).
/// Seamless loop: place 2 sets of the card row side by side, scroll at a constant speed by the width of
/// 1 set, then rewind.
private struct DreamImageMarquee: View {
    var cardWidth: CGFloat = 118
    var cardHeight: CGFloat = 150
    var gap: CGFloat = 12
    /// Speed (pt/sec). Slow enough that you only notice it is moving after a while
    var speed: CGFloat = 22

    /// Names whose assets are not added yet are excluded automatically (same design as OnboardingDreamAssets)
    private let images: [String] = OnboardingDreamAssets.deck.filter { UIImage(named: $0) != nil }

    @State private var startDate = Date()

    var body: some View {
        // Important: if the HStack 2 sets wide (~2,800pt) is placed as a "layout child",
        // that width propagates to the parent VStack and the whole page gets stretched sideways (2026-07-19
        // real device bug). Using Color.clear as the base and putting it in an overlay cuts the marquee
        // content's width off from the layout calculation (overlay content does not affect the parent's size)
        Color.clear
            .frame(height: cardHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if !images.isEmpty {
                    let setWidth = CGFloat(images.count) * (cardWidth + gap)
                    // For ProMotion 120Hz: cap at 30fps (constant-speed marquee, so no visible difference).
                    // When Reduce Motion is on, stop the TimelineView itself and show a still image
                    // (same approach as CountUpNumber in OnboardingQuiz.swift).
                    // drawingGroup() would apply to the whole HStack about 4,400pt wide, creating a huge texture that
                    // may backfire, so it is not applied here
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
