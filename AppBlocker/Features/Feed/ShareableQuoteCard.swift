//
//  ShareableQuoteCard.swift
//  AppBlocker
//
//  画像保存専用の 9:16 縦長カード。
//  FeedItemCard とほぼ同じレイアウトだが、アクション UI (いいね/フォロー/…) を一切含まず、
//  ImageRenderer で 1080×1920 にレンダリングする想定で固定サイズ。
//

import SwiftUI

struct ShareableQuoteCard: View {
    let item: FeedItem
    let lang: AppLanguage
    let showOriginal: Bool

    /// 1080×1920 (Instagram Story / Reels / TikTok 標準サイズ)
    static let renderSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        ZStack {
            if item.kind == .quote {
                // 2026-07-30: 公式名言はフィードと同じ紙×タイポのテンプレ描画
                // (サイズはカード幅比なので 1080×1920 でも相似形にスケール)
                QuoteCardView(
                    primary: item.displayPrimary(lang: lang, showOriginal: showOriginal),
                    secondary: item.displaySecondary(lang: lang, showOriginal: showOriginal),
                    seedId: item.itemId
                )
            } else {
                QuoteBackgroundView(quoteId: item.itemId, backgroundIndex: item.backgroundId)

                // 中央: メイン + (任意) サブテキスト
                VStack(spacing: 0) {
                    Spacer()

                    // フィードカードと同じ詩的改行 (QuoteTypography、2026-07-30)
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

            // 左下: 投稿者名 + 公式チェック (匿名著者の名言は行ごと非表示 — 2026-07-30 名言監査)
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

            // 右下: ブランドマーク (将来差し替え予定 → AreteWatermark に分離)。
            // 紙テンプレの名言 (明背景) では暗色バリアントに切り替える
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

/// 保存画像右下のブランド表記。
/// B1 マーク (縦棒 + 対角ドット2つ) + 「1%」テキスト。
/// ImageExportService (投稿v2 の焼き込み画像への合成) からも使うため internal。
struct AreteWatermark: View {
    /// 紙テンプレ (明背景) 用の暗色バリアント (2026-07-30 名言カード刷新)。
    /// 写真の上に載せる従来用途は白のまま
    var dark: Bool = false

    private var tint: Color { dark ? Color.black.opacity(0.55) : Color.white.opacity(0.7) }

    var body: some View {
        // B1 マークが主役、「1%」はおまけの添え字 (ユーザー指定 2026-07-06)
        HStack(alignment: .bottom, spacing: 7) {
            b1Mark
            Text("1%")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(dark ? Color.black.opacity(0.45) : .white.opacity(0.55))
                .padding(.bottom, 4)
        }
        .shadow(color: .black.opacity(dark ? 0 : 0.6), radius: 6, x: 0, y: 2)
    }

    /// B1 マーク。viewBox 100 換算 (棒 x44 y20 w12 h60 rx6 / ドット r9.5 中心 (26,31),(74,69))。
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
