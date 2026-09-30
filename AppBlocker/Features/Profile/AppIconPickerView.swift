//
//  AppIconPickerView.swift
//  AppBlocker
//
//  Switching the app icon (Elite perk, added 2026-07-20 / turned into a gallery 2026-07-25).
//
//  ■ Steps to add a new icon (do this every time the user makes an image):
//    1. Create "AppIcon<name>.appiconset" in Assets.xcassets and put in a 1024x1024 PNG (no alpha)
//       (copy Contents.json from an existing appiconset and replace filename)
//    2. For the preview, also put the same PNG in "IconPreview<name>.imageset"
//    3. (If there is one) put the original art in "Original<name>.imageset" (shown as the gallery
//       background)
//    4. Add the set name to ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in pbxproj (space
//       separated)
//    5. Add one line to AppIconCatalog.all below
//    ※ Adding icon images always needs an app update (App Review). iOS does not allow adding them at
//      runtime. If you want to control only "when they unlock" without App Review, layer a Supabase
//      app_icons flag table on top (2026-07-20 design note).
//
//  ■ UX (2026-07-25 user request):
//    Tap an icon in the grid → gallery in a centered modal. The original art is laid dimmed in the
//    background, and the icon sits big in the center. Page with the left/right arrows (+ swipe), and
//    apply with the CTA.
//

import SwiftUI

// MARK: - Catalog

struct AppIconOption: Identifiable {
    /// Name passed to setAlternateIconName. nil = primary (AppIcon)
    let alternateName: String?
    /// Preview image shown in the list (imageset name)
    let previewAssetName: String
    /// Original art laid behind the gallery (imageset name). nil = solid background
    let originalAssetName: String?
    let nameJa: String
    let nameEn: String

    var id: String { alternateName ?? "primary" }

    /// Icons usable for free (Classic = primary, and White. Confirmed by the user 2026-07-25).
    /// Wordmark is temporarily free during the 2026-07-29 brand test (it may be promoted to primary;
    /// once decided, choose between making it paid or making it primary). Everything else is an Elite
    /// perk (gated only on apply, browsing is free)
    var isFree: Bool {
        alternateName == nil || alternateName == "AppIconWhite"
            || alternateName == "AppIconWordmark" || alternateName == "AppIconWordmarkWhite"
    }
}

enum AppIconCatalog {
    /// Rollback on subscription expiry (C1 family, 2026-07-29 real device bug feedback): even after expiry,
    /// the home screen kept the Elite-only icon. If the current alternate icon is paid, go back to the
    /// primary.
    /// Only called from the "expiry confirmed by a fresh fetch" path of
    /// ProAccess.reconcileEntitlementMirror. The existing C1 guard prevents a wrong revert based only on
    /// offline/cache data.
    /// Names not in the catalog (leftovers from old versions etc.) are also treated as paid and reverted.
    /// ⚠️ setAlternateIconName shows the OS standard "You have changed the icon" alert, but this is
    /// accepted because it also serves as the notice that the perk expired (there is no public API to hide
    /// it)
    @MainActor
    static func revertPaidIconIfLapsed() {
        guard let current = UIApplication.shared.alternateIconName else { return } // Using the primary
        // This checks "is that name paid right now", so look at the full defined catalog instead of all,
        // which is for display (all is filtered by hidesPaidIcons)
        let isFree = catalog.first(where: { $0.alternateName == current })?.isFree ?? false
        guard !isFree else { return }
        UIApplication.shared.setAlternateIconName(nil) { error in
            if let error {
                print("⚠️ Paid icon revert failed: \(error)")
            } else {
                print("🔒 Paid app icon reverted to primary (entitlement lapsed)")
            }
        }
    }

    /// 🔴 v1 does not show the 5 paid (Elite-only) icons (2026-08-04 user decision:
    /// hide them until we have icons good enough to ship). **Setting this flag back to false is all it
    /// takes to bring them back**: the definitions, Assets and the alternate icon registration in
    /// Info.plist are all left in place, so nothing else needs to be touched.
    /// During this period the Pro perks are only schedule/location blocking
    private static let hidesPaidIcons = true

    /// Icons shown on screen. While the others are hidden, only the 4 free ones (Classic/White/2 Wordmarks)
    static let all: [AppIconOption] = hidesPaidIcons ? catalog.filter(\.isFree) : catalog

    // Wording (icon names) is waiting for the user's review.
    // Primary = Classic (bold monogram, black, confirmed by the user 2026-07-25)
    private static let catalog: [AppIconOption] = [
        AppIconOption(alternateName: nil, previewAssetName: "IconPreviewClassic",
                      originalAssetName: nil, nameJa: "クラシック", nameEn: "Classic"),
        AppIconOption(alternateName: "AppIconWhite", previewAssetName: "IconPreviewWhite",
                      originalAssetName: nil, nameJa: "ホワイト", nameEn: "White"),
        AppIconOption(alternateName: "AppIconWordmark", previewAssetName: "IconPreviewWordmark",
                      originalAssetName: nil, nameJa: "ワードマーク", nameEn: "Wordmark"), // Wording is waiting for the user's review
        AppIconOption(alternateName: "AppIconWordmarkWhite", previewAssetName: "IconPreviewWordmarkWhite",
                      originalAssetName: nil, nameJa: "ワードマーク・ホワイト", nameEn: "Wordmark White"), // Wording is waiting for the user's review
        AppIconOption(alternateName: "AppIconLion", previewAssetName: "IconPreviewLion",
                      originalAssetName: "OriginalLion", nameJa: "ライオン", nameEn: "Lion"),
        AppIconOption(alternateName: "AppIconHuman", previewAssetName: "IconPreviewHuman",
                      originalAssetName: "OriginalHuman", nameJa: "ラッパー", nameEn: "Rapper"),
        AppIconOption(alternateName: "AppIconCobra", previewAssetName: "IconPreviewCobra",
                      originalAssetName: "OriginalCobra", nameJa: "コブラ", nameEn: "Cobra"),
        AppIconOption(alternateName: "AppIconGoat", previewAssetName: "IconPreviewGoat",
                      originalAssetName: "OriginalGoat", nameJa: "ヤギ", nameEn: "Goat"),
        AppIconOption(alternateName: "AppIconDoberman", previewAssetName: "IconPreviewDoberman",
                      originalAssetName: "OriginalDoberman", nameJa: "ドーベルマン", nameEn: "Doberman"),
    ]
}

// MARK: - Picker View

struct AppIconPickerView: View {
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var currentAlternate: String? = UIApplication.shared.alternateIconName
    @State private var galleryItem: GalleryItem?

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    struct GalleryItem: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(AppIconCatalog.all.enumerated()), id: \.element.id) { index, option in
                        iconCell(option, index: index)
                    }
                }
                .padding(20)

                // Wording is waiting for the user's review
                Text(lang == .japanese
                     ? "アイコンは今後のアップデートで追加されます。"
                     : "More icons will arrive in future updates.")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle(lang == .japanese ? "アプリアイコン" : "App Icon") // Wording is waiting for the user's review
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $galleryItem) { item in
            IconGalleryView(
                startIndex: item.index,
                lang: lang,
                currentAlternate: $currentAlternate
            )
        }
    }

    private func iconCell(_ option: AppIconOption, index: Int) -> some View {
        let isCurrent = option.alternateName == currentAlternate
        // Switching icons is an Elite perk (Classic/White are free). Anyone can browse the gallery
        let isLocked = !proAccess.isPro && !isCurrent && !option.isFree

        return Button {
            galleryItem = GalleryItem(index: index)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(option.previewAssetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19))
                        .overlay(
                            RoundedRectangle(cornerRadius: 19)
                                .stroke(isCurrent ? Color.white : Color.white.opacity(0.1),
                                        lineWidth: isCurrent ? 2 : 1)
                        )
                        .opacity(isLocked ? 0.55 : 1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .background(Circle().fill(AppColors.background))
                            .offset(x: 6, y: 6)
                    } else if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)
                            .padding(6)
                            .background(Circle().fill(AppColors.cardBackground))
                            .offset(x: 6, y: 6)
                    }
                }

                Text(lang == .japanese ? option.nameJa : option.nameEn)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isCurrent ? AppColors.textPrimary : AppColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon Gallery (centered modal + left/right paging + original art in the background)

private struct IconGalleryView: View {
    let startIndex: Int
    let lang: AppLanguage
    @Binding var currentAlternate: String?

    @ObservedObject private var proAccess = ProAccess.shared
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    @State private var showProPaywall = false
    @State private var errorMessage: String?

    private var options: [AppIconOption] { AppIconCatalog.all }
    /// Side length of the square modal (leaves room for the left/right arrows)
    private var cardSide: CGFloat { min(UIScreen.main.bounds.width - 104, 320) }
    private var option: AppIconOption { options[index] }
    private var isCurrent: Bool { option.alternateName == currentAlternate }

    var body: some View {
        ZStack {
            // Dark backdrop (tap to close)
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Center: square modal (2026-07-25 user request: even tall original images are cropped to squares
            // for consistency, the icon is in their center, and the CTA is outside the modal).
            // Paging uses TabView paging = the next card slides in from the side (instant switching was
            // rejected)
            VStack(spacing: 20) {
                // The viewport is the full screen width (2026-07-25 real device feedback: cutting off in a card-width
                // box was rejected). Cards are centered inside each page, so when swiping, the next card
                // comes in from outside the screen edge and leaves past the screen edge. The swipeable area also
                // becomes full width
                TabView(selection: $index) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                        galleryPage(opt).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)
                .frame(height: cardSide)
                // The arrows sit right beside the card (8pt outside), Y = card center. Since the viewport became full
                // width, use a transparent card-width frame as the reference to keep the old visual position
                // (Color.clear has no hit testing, so TabView swipes pass through)
                .overlay {
                    Color.clear
                        .frame(width: cardSide, height: cardSide)
                        .overlay(alignment: .leading) {
                            arrowButton(systemName: "chevron.left") { step(-1) }
                                .offset(x: -48)
                        }
                        .overlay(alignment: .trailing) {
                            arrowButton(systemName: "chevron.right") { step(+1) }
                                .offset(x: 48)
                        }
                }

                Text(lang == .japanese ? option.nameJa : option.nameEn)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                // The CTA is outside the modal (the square card)
                Button {
                    apply()
                } label: {
                    Text(isCurrent
                         ? (lang == .japanese ? "使用中" : "Current")  // Wording is waiting for the user's review
                         : (lang == .japanese ? "このアイコンにする" : "Use this icon"))  // Wording is waiting for the user's review
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isCurrent ? AppColors.textTertiary : AppColors.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Capsule().fill(isCurrent ? Color.white.opacity(0.1) : AppColors.textPrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
                .frame(width: cardSide)
            }

            // Close (top right)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .presentationBackground(.clear)
        .onAppear { index = startIndex }
        .sheet(isPresented: $showProPaywall) {
            ProPaywallView(triggeredBy: .schedule)
        }
        .alert(errorMessage ?? "", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Square card for one page. Classic/White (no original art) do not
    /// lay a background card. Only the icon is placed in the center (2026-07-25 user request)
    @ViewBuilder
    private func galleryPage(_ opt: AppIconOption) -> some View {
        ZStack {
            if let original = opt.originalAssetName {
                Image(original)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSide, height: cardSide)
                    .overlay(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            Image(opt.previewAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27))
                .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 22, y: 8)
        }
        .frame(width: cardSide, height: cardSide)
    }

    private func arrowButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            index = (index + delta + options.count) % options.count
        }
    }

    private func apply() {
        // Switching is an Elite perk. But Classic/White are free (confirmed by the user 2026-07-25)
        guard proAccess.isPro || option.isFree else {
            showProPaywall = true
            return
        }
        let target = option
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(target.alternateName)
                currentAlternate = target.alternateName
                // The iOS standard "You have changed the icon" alert cannot be hidden (no public API), so
                // close the gallery first so the alert appears on top of the plain list screen
                // (fixes the odd look of a modal stacked on a modal, 2026-07-25 real device feedback)
                dismiss()
            } catch {
                errorMessage = lang == .japanese
                    ? "アイコンを変更できませんでした"
                    : "Couldn't change the app icon"  // Wording is waiting for the user's review
                print("⚠️ setAlternateIconName failed: \(error)")
            }
        }
    }
}

#Preview {
    NavigationStack { AppIconPickerView() }
}
