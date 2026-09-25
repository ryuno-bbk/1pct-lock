//
//  ProfileCards.swift
//  AppBlocker
//
//  マイページ用のリストカード（いいね名言・フォロー中偉人）
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

// MARK: - Liked Quote Grid Cell (TikTok 風 9:16 サムネイル、名言中央配置)
// S15: FeedItemCard と同じレイアウトで中央配置、著者名は省略 (サムネ集中)

struct LikedQuoteGridCell: View {
    let quote: Quote
    let onTap: () -> Void
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        // 2026-07-30: 写真背景を全廃 → フィードと同じ紙×タイポのテンプレ描画
        // (幅比サイズなのでサムネでも相似形に縮む)。サムネでは翻訳行は出さない
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

// MARK: - User Post Grid Cell (TikTok 風 9:16 サムネイル、自分の投稿用)
// S15: FeedItemCard と同じレイアウトで中央配置、タグは省略

struct UserPostGridCell: View {
    let post: UserPost
    let onTap: () -> Void
    /// 2026-07-22 実機FB: 自分のグリッドでは rejected/flagged を「セル暗転+アイコン+ラベル」で
    /// 明示する (従来はサムネが素で並び、制限中かどうか分からなかった)。
    /// 他人のプロフィールでは出さない (呼び出し側が isSelf の時だけ true を渡す)
    var showsModerationState: Bool = false
    /// 審査中の異議申し立てがある投稿 (フィードのオーバーレイと同じく時計+「異議申し立て中」表示。
    /// 2026-07-25 実機FB: グリッド欄にも申し立て状態を反映)
    var isAppealPending: Bool = false
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("showOriginal") private var showOriginal = false

    // M5: AsyncImage はサムネ表示でもフルデコードしてしまう (1080×1350 で1枚5.5MB前後)。
    // PostThumbnailLoader 経由の 400px ダウンサンプル + キャッシュに差し替えるため、
    // AsyncImagePhase と同じ 3 分岐 (loading/success/failure) を自前の @State で持つ
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
            // 投稿v2: 焼き込み画像があればサムネそのもの、なければ現行のテキストタイル
            if let url = post.imageUrl {
                // 器 (Color.clear) を先に確定させてから overlay + clipped。fill 画像を直接置くと
                // レイアウトを押し広げてセルが崩れる上、clipped は描画しか切らないため
                // はみ出した当たり判定が隣セルのタップを奪う (「どこを押しても左上が開く」実機事故)。
                // タップは外側の contentShape に任せるので画像側の hitTest は切る。
                Color.clear
                    .overlay(
                        Group {
                            switch thumbnailPhase {
                            case .success(let image):
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                // 実機FB#1 真因修正: 画像投稿 (imageUrl あり) のロード失敗を
                                // 名言テンプレ (QuoteBackgroundView) にフォールバックすると、
                                // 「画像投稿である」事実を偽って石背景に見えてしまう
                                // (カメラ撮影+文字入れ投稿がテキスト投稿のような見た目になるバグ)。
                                // 中立なプレースホルダに差し替える。imageUrl が nil の
                                // 旧テキスト投稿側 (else 分岐) は QuoteBackgroundView のまま維持
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
                        // id: url なので post が差し替わって url が変わればキャンセルして再読込される
                        thumbnailPhase = .loading
                        let image = await PostThumbnailLoader.shared.thumbnail(for: url)
                        // 実機FB#1 真因修正: このセルの再出現/プロフィール統計の非同期ロードに
                        // よるレイアウト揺れで Task 自体がキャンセルされても、await 復帰後の
                        // コードは (Swift の協調的キャンセルにより) 止まらず実行され続け、
                        // 従来は nil を「本当の失敗」として書き込んで .failure に恒久固定
                        // していた (次にこの .task が再実行されるまで石背景のまま)。
                        // キャンセル済みならここで抜けて .loading のまま残し、
                        // 自然な再実行 (再出現 / id 変化) でのリトライに任せる
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
            // 2026-07-22 実機FB: 制限中 (rejected/flagged) のセルを暗転+アイコン+ラベルで明示。
            // タップは従来どおり詳細を開く (詳細側に大きなオーバーレイ+異議申し立て導線があるため
            // ここは純粋な視覚表示に留め、hitTesting は切る)
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
                             ? (lang == .japanese ? "異議申し立て中" : "Appeal under review")  // 文言はユーザー添削待ち
                             : post.moderationStatus == "rejected"
                             ? L.postsModerationRejectedBadge(lang)
                             : (lang == .japanese ? "表示が制限されています" : "Visibility limited"))  // 文言はユーザー添削待ち
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
            // タップ数 (028 SQL view_count、全員に見える)。BeReal のリアクション数の位置
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
