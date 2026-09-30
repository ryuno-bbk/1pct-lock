//
//  ProfileCards.swift
//  AppBlocker
//
//  List cards for My Page (liked quotes, followed great figures)
//

import SwiftUI

// MARK: - Liked Quote Card

struct LikedQuoteCard: View {
    let quote: Quote
    let onTap: () -> Void
    let onUnlike: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\"\(quote.displayPrimary(lang: lang, showOriginal: false))\"")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack {
                    if let name = quote.displayAuthor {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("― \(name)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textTertiary)

                            let bio = lang == .japanese ? quote.authorBioJp : quote.authorBioEn
                            if !bio.isEmpty {
                                Text(bio)
                                    .font(.system(size: 10))
                                    .foregroundColor(AppColors.textTertiary.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer()

                    Button(action: onUnlike) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Liked Quote Grid Cell (TikTok-style 9:16 thumbnail, quote centered)
// S15: centered with the same layout as FeedItemCard, author name omitted (focus on the thumbnail)

struct LikedQuoteGridCell: View {
    let quote: Quote
    let onTap: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        // 2026-07-30: photo backgrounds removed entirely → drawn with the same paper × typography template
        // as the feed (sizes are relative to width, so it scales down proportionally even as a thumbnail).
        // The translation line is not shown in thumbnails
        QuoteCardView(
            primary: quote.displayPrimary(lang: lang, showOriginal: showOriginal),
            secondary: nil,
            seedId: quote.id
        )
        .aspectRatio(4.0/5.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
    }
}

// MARK: - User Post Grid Cell (TikTok-style 9:16 thumbnail, for your own posts)
// S15: centered with the same layout as FeedItemCard, tags omitted

struct UserPostGridCell: View {
    let post: UserPost
    let onTap: () -> Void
    /// 2026-07-22 real device feedback: in your own grid, rejected/flagged are shown explicitly with
    /// "dimmed cell + icon + label" (previously the thumbnails were listed plain, and you could not tell
    /// whether they were restricted).
    /// Not shown on other people's profiles (the caller passes true only when isSelf)
    var showsModerationState: Bool = false
    /// Post with an appeal under review (same clock + "異議申し立て中" ("Appeal under review") display as
    /// the feed overlay. 2026-07-25 real device feedback: reflect the appeal state in the grid too)
    var isAppealPending: Bool = false
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    // M5: AsyncImage fully decodes even for thumbnails (around 5.5MB per image at 1080×1350).
    // To replace it with a 400px downsample + cache via PostThumbnailLoader,
    // the same 3 branches as AsyncImagePhase (loading/success/failure) are kept in our own @State
    private enum ThumbnailPhase {
        case loading
        case success(UIImage)
        case failure
    }

    @State private var thumbnailPhase: ThumbnailPhase = .loading

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        ZStack {
            // Post v2: if there is a baked image, that is the thumbnail itself; otherwise the current text tile
            if let url = post.imageUrl {
                // Fix the container (Color.clear) first, then overlay + clipped. Placing a fill image directly
                // pushes the layout out and breaks the cell, and since clipped only clips the drawing,
                // the overflowing hit area steals taps from neighboring cells (the real device incident "wherever
                // you tap, the top-left one opens"). Taps are left to the outer contentShape, so hitTest is turned
                // off on the image.
                Color.clear
                    .overlay(
                        Group {
                            switch thumbnailPhase {
                            case .success(let image):
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                // Real device feedback #1 root cause fix: if a load failure of an image post (with imageUrl)
                                // falls back to the quote template (QuoteBackgroundView),
                                // it misrepresents the fact that "it is an image post" and looks like a stone background
                                // (bug where camera photo + text posts looked like text posts).
                                // Replace it with a neutral placeholder. The old text posts with a nil imageUrl
                                // (else branch) keep QuoteBackgroundView
                                ZStack {
                                    Color.black
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white.opacity(0.25))
                                }
                            case .loading:
                                Color.black
                            }
                        }
                    )
                    .clipped()
                    .allowsHitTesting(false)
                    .task(id: url) {
                        // id: url, so if post is replaced and url changes, it is cancelled and reloaded
                        thumbnailPhase = .loading
                        let image = await PostThumbnailLoader.shared.thumbnail(for: url)
                        // Real device feedback #1 root cause fix: even when the Task itself is cancelled because this cell
                        // reappears / the layout shifts from the async load of the profile stats, the code after await
                        // resumes and keeps running (due to Swift's cooperative cancellation), and
                        // previously it wrote nil as a "real failure" and permanently fixed it at .failure
                        // (stone background until this .task ran again).
                        // If cancelled, exit here and leave it as .loading, and
                        // leave the retry to a natural re-run (reappearance / id change)
                        if Task.isCancelled { return }
                        if let image {
                            thumbnailPhase = .success(image)
                        } else {
                            thumbnailPhase = .failure
                        }
                    }
            } else {
                QuoteBackgroundView(quoteId: post.id, backgroundIndex: post.backgroundId)

                Color.black.opacity(0.25)

                VStack(spacing: 5) {
                    Text("\"\(post.displayPrimary(lang: lang, showOriginal: showOriginal))\"")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)

                    if let secondary = post.displaySecondary(lang: lang, showOriginal: showOriginal) {
                        Text(secondary)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .aspectRatio(4.0/5.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay {
            // 2026-07-22 real device feedback: show restricted (rejected/flagged) cells explicitly with
            // dimming + icon + label. A tap opens the detail as before (the detail has a large overlay + the
            // appeal path, so this stays purely visual and hitTesting is turned off)
            if showsModerationState,
               post.moderationStatus == "rejected" || post.moderationStatus == "flagged" {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 6) {
                        Image(systemName: isAppealPending
                              ? "clock.fill"
                              : (post.moderationStatus == "rejected"
                                 ? "eye.slash.fill" : "exclamationmark.triangle.fill"))
                            .font(.system(size: 18, weight: .semibold))
                        Text(isAppealPending
                             ? (lang == .japanese ? "異議申し立て中" : "Appeal under review")  // Wording awaiting user review
                             : post.moderationStatus == "rejected"
                             ? L.postsModerationRejectedBadge(lang)
                             : (lang == .japanese ? "表示が制限されています" : "Visibility limited"))  // Wording awaiting user review
                            .font(.system(size: 9, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            // Tap count (028 SQL view_count, visible to everyone). In the position of BeReal's reaction count
            HStack(spacing: 3) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(post.viewCount.abbreviated)
                    .font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(6)
            .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
    }
}

// MARK: - Author Row Card

struct AuthorRowCard: View {
    let author: Author
    let onUnfollow: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(AppColors.accent)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(author.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)

                    if author.isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }

                let bio = author.displayBio(lang: lang)
                if !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: onUnfollow) {
                Text(L.profileUnfollow(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(AppColors.cardBackground.opacity(0.6))
                    )
                    .overlay(
                        Capsule().stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
        )
    }
}
