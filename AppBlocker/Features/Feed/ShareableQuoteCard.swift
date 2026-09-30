//
//  ShareableQuoteCard.swift
//  AppBlocker
//
//  9:16 vertical card only for saving images.
//  Almost the same layout as FeedItemCard, but it contains no action UI (like/follow/...) at all,
//  and has a fixed size, assuming it is rendered at 1080×1920 with ImageRenderer.
//

import SwiftUI

struct ShareableQuoteCard: View {
    let item: FeedItem
    let lang: AppLanguage
    let showOriginal: Bool

    /// 1080×1920 (standard size for Instagram Story / Reels / TikTok)
    static let renderSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        ZStack {
            if item.kind == .quote {
                // 2026-07-30: official quotes use the same paper × typography template drawing as the feed
                // (sizes are ratios of the card width, so it scales proportionally at 1080×1920 too)
                QuoteCardView(
                    primary: item.displayPrimary(lang: lang, showOriginal: showOriginal),
                    secondary: item.displaySecondary(lang: lang, showOriginal: showOriginal),
                    seedId: item.itemId
                )
            } else {
                QuoteBackgroundView(quoteId: item.itemId, backgroundIndex: item.backgroundId)

                // Center: main + (optional) sub text
                VStack(spacing: 0) {
                    Spacer()

                    // Same poetic line breaks as the feed card (QuoteTypography, 2026-07-30)
                    Text("\"\(QuoteTypography.poeticText(item.displayPrimary(lang: lang, showOriginal: showOriginal)))\"")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(16)
                        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 120)

                    if let secondary = item.displaySecondary(lang: lang, showOriginal: showOriginal) {
                        Text(QuoteTypography.poeticText(secondary))
                            .font(.system(size: 40, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineSpacing(8)
                            .padding(.top, 32)
                            .padding(.horizontal, 120)
                            .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                    }

                    Spacer()
                }
            }

            // Bottom left: author name + official check (for quotes by the anonymous author the whole line is
            // hidden; 2026-07-30 quote audit)
            if let authorName = item.authorName, !Quote.isAnonymousAuthor(authorName) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    HStack(spacing: 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.white)

                        Text(authorName)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)

                        if item.isOfficialAuthor {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.blue)
                        }
                    }
                    .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
                }
                .padding(.leading, 48)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Bottom right: brand mark (planned to be replaced later → split out into AreteWatermark).
            // For paper-template quotes (light background), switch to the dark variant
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer()
                    AreteWatermark(dark: item.kind == .quote
                        && !QuoteCardView.template(for: item.itemId, override: nil).isDark)
                }
            }
            .padding(.trailing, 48)
            .padding(.bottom, 120)
        }
        .frame(width: Self.renderSize.width, height: Self.renderSize.height)
        .clipped()
    }
}

/// Brand mark at the bottom right of saved images.
/// B1 mark (vertical bar + 2 diagonal dots) + "1%" text.
/// internal because ImageExportService (compositing onto the baked images of posts v2) also uses it.
struct AreteWatermark: View {
    /// Dark variant for paper templates (light background) (2026-07-30 quote card renewal).
    /// The original use on top of photos stays white
    var dark: Bool = false

    private var tint: Color { dark ? Color.black.opacity(0.55) : Color.white.opacity(0.7) }

    var body: some View {
        // The B1 mark is the main element; "1%" is a small extra subscript (user-specified 2026-07-06)
        HStack(alignment: .bottom, spacing: 7) {
            b1Mark
            Text("1%")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(dark ? Color.black.opacity(0.45) : .white.opacity(0.55))
                .padding(.bottom, 4)
        }
        .shadow(color: .black.opacity(dark ? 0 : 0.6), radius: 6, x: 0, y: 2)
    }

    /// B1 mark. In viewBox 100 units (bar x44 y20 w12 h60 rx6 / dots r9.5 centers (26,31),(74,69)).
    private var b1Mark: some View {
        let size: CGFloat = 52
        let scale = size / 100
        return ZStack {
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(tint)
                .frame(width: 12 * scale, height: 60 * scale)
                .position(x: 50 * scale, y: 50 * scale)

            Circle()
                .fill(tint)
                .frame(width: 19 * scale, height: 19 * scale)
                .position(x: 26 * scale, y: 31 * scale)

            Circle()
                .fill(tint)
                .frame(width: 19 * scale, height: 19 * scale)
                .position(x: 74 * scale, y: 69 * scale)
        }
        .frame(width: size, height: size)
    }
}
