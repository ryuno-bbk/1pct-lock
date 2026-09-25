//
//  ProfileHero.swift
//  AppBlocker
//
//  BeReal 風プロフィールヒーロー (2026-07-10 確定仕様)。
//  MyProfileView / UserProfileView / OfficialProfileView の 3 画面で共用する。
//    - アバター画像を全幅で大きく表示、左下に 名前(最大) → @handle → bio
//    - 画像の下: フォロワー / フォロー中 / いいね数 などの統計行
//    - 横長のアクションボタン (フォロー / プロフィールを編集)
//    - ボタンと投稿グリッドの間: 累計ロック / 連続 / 完遂率 / 上位% の 2×2 グリッド
//      (2026-07-16 統計パックで完全集約。BeReal の興味チップの位置)
//

import SwiftUI
import UIKit

// MARK: - データ型

// MARK: - Text Outline (BeReal 風: 画像上の白文字に薄い黒枠線をつけて可読性を上げる)

// MARK: - 本物の文字ストローク (2026-07-30 確定)
// SwiftUI の Text には境界線 API が存在しないため、UIKit の2パス描画
// (①ストローク → ②フィル) をラップする。shadow細工・コピー細工は全廃。
// 調整ポイントはこの3定数だけ: 色 (灰色)・透明度 (alpha)・太さ (pt)

enum HeroTextStrokeStyle {
    /// 縁取りの色 (不透明で持ち、透明度は alpha で一括適用)
    static let colorOpaque = UIColor(white: 0.12, alpha: 1)
    /// 縁取り全体の透明度 (2026-07-30 FB「もうちょい薄く」で 0.45→0.32)
    static let alpha: CGFloat = 0.32
    /// 縁取りの太さ (グリフの外側に出る量、pt)
    static let width: CGFloat = 2.0
}

private final class StrokeLabel: UILabel {
    private let strokeWidth = HeroTextStrokeStyle.width

    // ストロークが枠外にはみ出て切れないよう、描画も採寸も太さぶん外側へ広げる
    override func drawText(in rect: CGRect) {
        let inset = rect.insetBy(dx: strokeWidth, dy: strokeWidth)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            super.drawText(in: inset)
            return
        }
        let originalColor = textColor
        // ①ストロークパス: 透明レイヤー内に「不透明」で描き、レイヤー全体へ一括アルファ。
        //   隣接グリフの縁が重なってもレイヤー内では不透明同士の重なりで飽和するだけなので、
        //   最終的な濃さが完全に均一になる (2026-07-30 FB「@handle等の重なりが濃くなる」対策)。
        //   絵文字はビットマップなのでストロークされず、②のフィルパスで普通に描かれる
        ctx.saveGState()
        ctx.setAlpha(HeroTextStrokeStyle.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(strokeWidth * 2)
        ctx.setLineJoin(.round)
        ctx.setTextDrawingMode(.stroke)
        textColor = HeroTextStrokeStyle.colorOpaque
        super.drawText(in: inset)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // ②フィルパス
        ctx.setTextDrawingMode(.fill)
        textColor = originalColor
        super.drawText(in: inset)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var s = super.sizeThatFits(CGSize(
            width: max(0, size.width - strokeWidth * 2),
            height: size.height
        ))
        s.width += strokeWidth * 2
        s.height += strokeWidth * 2
        return s
    }
}

/// ヒーロー画像上のテキスト用。SwiftUI から色・行数・縮小を指定して本物の縁取り文字を描く
struct StrokedText: UIViewRepresentable {
    let text: String
    let font: UIFont
    var textColor: UIColor = .white
    var lineLimit: Int = 1
    var adjustsFontSize: Bool = false
    var minimumScale: CGFloat = 1.0

    func makeUIView(context: Context) -> UILabel {
        let label = StrokeLabel()
        label.backgroundColor = .clear
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.textColor = textColor
        label.numberOfLines = lineLimit
        label.adjustsFontSizeToFitWidth = adjustsFontSize
        label.minimumScaleFactor = minimumScale
        label.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }
}

struct ProfileHeroStat: Identifiable {
    let value: String
    let label: String
    var gold: Bool = false
    /// タップ可能な統計 (フォロー中 → 一覧など)。nil なら表示のみ
    var action: (() -> Void)? = nil

    var id: String { label }
}

/// 統計グリッドのセル (2026-07-11 勲章風 → 2026-07-16 2×2グリッド化)。
/// value (大きい数字) + label (小さい説明) の 2 段構成。gold = 上位% 専用の金装飾。
/// tint = アイコンのテーマ色 (2026-07-16 リッチ化。AppColors のセマンティック色のみ許可、
/// nil なら無彩色。gold セルは tint 不要で金が優先される)。
/// detail = タップで出す詳細説明シート (2026-07-17。nil ならタップ不可の表示のみ)
struct ProfileHeroChip: Identifiable {
    let icon: String   // SF Symbol
    let value: String
    let label: String
    var gold: Bool = false
    var tint: Color? = nil
    var detail: ProfileHeroChipDetail? = nil

    var id: String { icon + label }
}

/// 統計セルの詳細説明モーダルの内容 (2026-07-17 ユーザー要望「バッジ全部タップで説明」)。
/// description = その統計の定義説明、rows = 追加の数値行 (例: 完遂率の直近30日/全期間、上位%の順位)。
/// 閉じるボタンは日英共通で "OK" (TikTok 等の標準ダイアログに合わせた既定値)
struct ProfileHeroChipDetail {
    let title: String
    let description: String
    var rows: [Row] = []
    var okTitle: String = "OK"

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}

// MARK: - 統計セルの詳細モーダル (2026-07-17)
//
// TikTok の「いいねのトータル数」ダイアログ準拠の軽い中央モーダル (ユーザー指定):
// 上に大きいアイコン → タイトル → 説明文 → (数値行) → 区切り線 → OK。
// 背景タップでも閉じる。iOS 標準 alert を使わないのは、アイコンと数値行を載せるため

private struct ChipDetailModal: View {
    let chip: ProfileHeroChip
    let detail: ProfileHeroChipDetail
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// セルと同じテーマ色 (金 > tint > 無彩色) をモーダルのアイコンにも引き継ぐ
    private var theme: Color {
        chip.gold ? AppColors.gold : (chip.tint ?? AppColors.textSecondary)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)  // 小さなカード限定 (巨大 View への scaleEffect 禁止ルールの範囲外)
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.opacity(0.14))
                    Image(systemName: chip.icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(theme)
                }
                .frame(width: 72, height: 72)
                .padding(.bottom, 2)

                Text(detail.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(detail.description)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if !detail.rows.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(detail.rows) { row in
                            HStack {
                                Text(row.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer(minLength: 12)
                                Text(row.value)
                                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
                                    .foregroundColor(row.value == "—" ? AppColors.textTertiary : AppColors.textPrimary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppColors.background.opacity(0.5))
                    )
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 20)

            Divider().overlay(Color.white.opacity(0.12))

            Button(action: close) {
                Text(detail.okTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.secondaryBackground)
        )
        .padding(.horizontal, 40)
    }

    private func close() {
        withAnimation(reduceMotion ? .none : .easeIn(duration: 0.15)) { appeared = false }
        // フェードアウトを見せてから dismiss (即 dismiss だとパッと消えて軽さが出ない)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.15)) { onDismiss() }
    }
}

// MARK: - Hero Header

struct ProfileHeroHeader: View {

    /// 親の ScrollView が付ける座標空間名 (ストレッチズーム用)。
    /// 各プロフィール画面は ScrollView に .coordinateSpace(name: ProfileHeroHeader.scrollSpace) を付けること
    static let scrollSpace = "profileHeroScroll"

    enum HeroImage {
        /// 一般ユーザー: avatar_url (nil ならプレースホルダ)
        case url(String?)
        /// 1% 公式アカウント: ロゴヒーロー
        case onePercent
    }

    /// TOP バッジの眉テキストのローカライズ用 (このコンポーネントは lang を持たない設計だったが、
    /// HandleCopyLabel と同じ @AppStorage 直読みの前例に合わせる)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    let hero: HeroImage
    let displayName: String
    var isPro: Bool = false
    var isOfficial: Bool = false
    var handle: String? = nil
    var bio: String? = nil
    /// 夢の宣言 (bio の下)。dreamLocked = 非公開マーク (本人のみ)
    var dreamText: String? = nil
    var dreamLocked: Bool = false

    /// D案 (2026-07-30): TOP10%以内の時だけ出す金のタイポバッジの数値。
    /// バッジ形状は使わずワードマークと同じ Montserrat BlackItalic の文字だけ (金ピカ回避)。
    /// 置き場はヒーロー画像の「外」(直下右寄せ) — 画像の上だとヒーロー画像への焼き込みで
    /// 偽装できてしまう (2026-07-30 ユーザー指摘)。UI面に置くことが earned の担保。
    /// nil = 圏外/データ不足で非表示
    var topPercent: Int? = nil
    /// TOP バッジタップ時の動作 (統計シートを開く想定 = 「これ何?」の答え+実データによる本物の証明)
    var onTopPercentTap: (() -> Void)? = nil

    /// 累計ロック時間の順位 (2026-09-05)。上位%ピルの右に無彩色のピルで出す。
    /// 🔴 金は上位%専用のブランドルールなので、こちらは金にしない。
    /// nil = 実績なし/母数不足で非表示
    var rank: Int? = nil
    /// 順位ピルのタップ (ランキング画面を開く想定)
    var onRankTap: (() -> Void)? = nil

    let stats: [ProfileHeroStat]

    /// 横長アクションボタン。actionTitle が nil なら非表示 (自分を他人画面で見た時など)
    var actionTitle: String? = nil
    /// true = 塗り (未フォロー)、false = 枠線 (フォロー中 / 編集)
    var actionIsProminent: Bool = true
    var actionIcon: String? = nil
    var onAction: (() -> Void)? = nil

    /// 統計チップ (2026-07-16 統計パック: ボタン下の 2×2 グリッドに完全集約。
    /// 4個前提だが件数に依存しない描画にしてある。空なら非表示)
    var chips: [ProfileHeroChip] = []

    /// タップされた統計セル (詳細説明シートの表示状態)
    @State private var detailChip: ProfileHeroChip?

    var body: some View {
        VStack(spacing: 0) {
            heroImage

            VStack(spacing: 14) {
                if let dreamText, !dreamText.isEmpty {
                    HStack(spacing: 5) {
                        if dreamLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textTertiary)
                        }
                        Text(dreamText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                }

                statsRow

                if let actionTitle, let onAction {
                    actionButton(title: actionTitle, action: onAction)
                }

                if !chips.isEmpty {
                    chipsRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // ヒーロー画像の自前ローダー (2026-07-30)。要件:
    //   1. URL が変わったら再ロードする (AsyncImage はここが不安定 = S15 の結論)
    //   2. ロード中・失敗中も旧画像を出し続ける (保存直後にプレースホルダへ戻さない)
    //   3. アップロード直後は Storage/CDN が一瞬エラーを返すことがあるため最大3回リトライ
    private struct HeroRemoteImage<Placeholder: View>: View {
        let urlString: String
        @ViewBuilder let placeholder: () -> Placeholder

        @State private var image: UIImage?
        @State private var loadedFor: String?
        @State private var loadTask: Task<Void, Never>?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder()
                }
            }
            .onAppear { reload() }
            .onChange(of: urlString) { _, _ in reload() }
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
        }

        private func reload() {
            if loadedFor == urlString, image != nil { return }
            loadTask?.cancel()
            guard let url = URL(string: urlString) else { return }
            loadTask = Task { @MainActor in
                for attempt in 1...3 {
                    if Task.isCancelled { return }
                    if let (data, response) = try? await URLSession.shared.data(from: url),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let loaded = UIImage(data: data) {
                        self.image = loaded
                        self.loadedFor = urlString
                        return
                    }
                    // 400ms → 800ms → 1200ms の間隔でリトライ (アップロード直後の伝播待ち)
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt))
                }
                print("⚠️ HeroRemoteImage load failed after retries: \(urlString)")
            }
        }
    }

// MARK: - Hero Image (角丸カード + 左下テキスト + 引き下げストレッチズーム)

    private var heroImage: some View {
        Color.clear
            .aspectRatio(1.0 / 1.15, contentMode: .fit)  // ちょい縦長 (BeReal 寄り)
            .overlay {
                GeometryReader { geo in
                    // 親 ScrollView の座標空間での minY。最上部で 0、下に引くと正 = その分ヘッダーを伸ばす
                    let minY = geo.frame(in: .named(Self.scrollSpace)).minY
                    let stretch = max(0, minY)
                    // 2026-07-30 実機FB: フレームを伸ばすだけでは scaledToFill が切り抜きで隠れていた
                    // 上部を先に「見せる」だけで、ズームは画像比を超えてからの2段階挙動だった。
                    // → 静止時の切り抜きを固定 (内側 frame+clipped) し、引いた分は倍率で拡大 =
                    // 初動の1pxからズームになる。scaleEffect は葉のImage限定 (S16の巨大View禁止とは別物)
                    let zoom = 1 + stretch / max(geo.size.height, 1)

                    heroImageContent
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .scaleEffect(zoom, anchor: .bottom)
                        .frame(width: geo.size.width, height: geo.size.height + stretch, alignment: .bottom)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            // 下側を暗くしてテキストを立たせる
                            // 2026-07-30 実機FB: 下部の暗さも強すぎたため 0.75→0.55 へ緩和
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.05), .black.opacity(0.55)],
                                startPoint: .center, endPoint: .bottom
                            )
                        }
                        .overlay(alignment: .bottomLeading) { heroOverlayText }
                        // BeReal 準拠: 画像は画面上端にべったり (上の角丸なし)、下 2 角だけ角丸
                        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
                            topLeading: 0, bottomLeading: 24, bottomTrailing: 24, topTrailing: 0
                        )))
                        .offset(y: -stretch)  // 伸びたぶん上へ = 画像が上に広がってズームして見える
                }
            }
    }

    @ViewBuilder
    private var heroImageContent: some View {
        switch hero {
        case .url(let urlString):
            if let urlString, !urlString.isEmpty {
                // AsyncImage は廃止 (S15 + 2026-07-30 実機FBの再発で確定):
                // アップロード直後の一瞬のエラーで失敗 phase に固まり、リトライも旧画像の
                // 保持もしないため「保存した瞬間プレースホルダに戻り再起動まで直らない」。
                // AvatarImage と同じ思想の自前ローダー (リトライ+旧画像保持) へ置き換え
                HeroRemoteImage(urlString: urlString) { heroPlaceholder }
            } else {
                heroPlaceholder
            }
        case .onePercent:
            // 2026-07-30 実機FB「公式アカウントの背景がつまんなすぎる」: フラット#0A0A0B+
            // アイコン直置き (2026-07-22形) → オンボのヒーローと同じ動く煙 (SmokeBackdrop) に刷新。
            // アイコンは OnePercentIcon (正方形アセット=煙の上だと地色の縁が四角く浮く) をやめ、
            // 本物のアイコンから切り出した くり抜き白グリフ (HeroClassicGlyph、アルファのみ) を
            // 直置き — 継ぎ目が構造的に出ない。下部グラデはヒーロー共通のオーバーレイ側が担当
            ZStack {
                SmokeBackdrop()
                Image("HeroClassicGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 168, height: 168)
            }
        }
    }

    private var heroPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.fill")
                .font(.system(size: 90, weight: .thin))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // @handle のタップコピー (2026-07-30 実機FB: IDを他所に貼りたい)。
    // コピーするのは @ を除いた生ハンドル (検索/SQL にそのまま貼れる形)。
    // フィードバック = 押下スケール (小要素のみ、S16 の巨大View scaleEffect 禁止には非抵触)
    // + 軽ハプティクス + アイコンがチェックに変化 + 「コピーしました」の一時表示
    private struct HandleCopyLabel: View {
        let handle: String
        @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
        @State private var copied = false

        private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault }

        var body: some View {
            Button {
                UIPasteboard.general.string = handle
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeIn(duration: 0.25)) { copied = false }
                }
            } label: {
                HStack(spacing: 5) {
                    StrokedText(
                        text: "@\(handle)",
                        font: .systemFont(ofSize: 14, weight: .medium),
                        textColor: UIColor.white.withAlphaComponent(0.9)
                    )
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(copied ? 0.95 : 0.55))
                    if copied {
                        StrokedText(
                            text: lang == .japanese ? "コピーしました" : "Copied",
                            font: .systemFont(ofSize: 11, weight: .semibold),
                            textColor: UIColor.white.withAlphaComponent(0.95)
                        )
                        .transition(.opacity)
                    }
                }
            }
            .buttonStyle(HandleCopyPressStyle())
            .accessibilityLabel(lang == .japanese ? "ユーザーIDをコピー" : "Copy user ID")
        }
    }

    private struct HandleCopyPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .opacity(configuration.isPressed ? 0.75 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// 上位%バッジ (改8、2026-07-30 ユーザー最終指定: BeRealのストリークピル文法)。
    // 金ガラスの調整点はこの3つだけ (2026-07-31)。濃くすると一気に安っぽくなるので上げすぎない
    /// ガラスに透かす金。0.10〜0.20 の間で調整 (0.14=上品側)
    private static let goldTint = AppColors.gold.opacity(0.14)
    /// 縁のヘアライン
    private static let goldEdge = AppColors.gold.opacity(0.42)
    /// 文字色。純白でも純金でもない、白に金を一滴落とした色
    private static let goldInk = Color(hex: "F6EBD2")

    /// 名前の上に半透明黒のカプセル+白文字。色反転案は実写背景 (白背景×下部グラデ) で
    /// 同化して敗北→廃止。眉=日本語「上位」システム太字/英語「TOP」Montserrat の混植、
    /// 数字+%は常に Montserrat BlackItalic。タップで統計シート (「これ何?」の答え+
    /// 実データ=焼き込み偽装との区別)。圏外/母数不足は何も出ない (earned)
    @ViewBuilder
    private var topPercentBadgeView: some View {
        if let topPercent {
            let isJa = (AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault) == .japanese
            let pill = HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(isJa ? "上位" : "TOP")
                    .font(isJa ? .system(size: 11, weight: .heavy) : .custom("Montserrat-BlackItalic", size: 10))
                    .kerning(isJa ? 0 : 1)
                    .opacity(0.9)
                Text("\(topPercent)%")
                    .font(.custom("Montserrat-BlackItalic", size: 16))
            }
            .foregroundColor(Self.goldInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)

            // ピル面: iOS 26+ はネイティブ Liquid Glass (interactive = 押すと伸びる、ユーザー指定
            // 「Apple Nativeの伸びるピル」)。それ未満は寒天 (ultraThinMaterial) フォールバック。
            // 2026-07-31: 素のガラス → 金を透かした「金ガラス」へ (ユーザー要望「上品な金」)。
            // 金ピカ回避のため、色は付けるが濃くしない: tint は淡く、文字はごく淡い金
            // (純白でも純金でもない)、縁だけ金のヘアラインで輪郭を出す
            let glassPill = Group {
                if #available(iOS 26.0, *) {
                    pill
                        .glassEffect(.regular.tint(Self.goldTint).interactive())
                        .overlay(Capsule().strokeBorder(Self.goldEdge, lineWidth: 0.6))
                } else {
                    pill
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Self.goldTint, in: Capsule())
                        .overlay(Capsule().strokeBorder(Self.goldEdge, lineWidth: 0.6))
                }
            }

            if let onTopPercentTap {
                Button {
                    // ハンドルコピーと同じ軽ハプティクス (ユーザー指定)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTopPercentTap()
                } label: { glassPill }
                    .buttonStyle(.plain)
                    .accessibilityLabel("上位\(topPercent)パーセント。タップで統計を表示")
            } else {
                glassPill
                    .accessibilityLabel("上位\(topPercent)パーセント")
            }
        }
    }

    /// 順位ピル (2026-09-05)。上位%ピルと同じガラス文法だが**無彩色**。
    /// 🔴 金は上位%専用 (ブランドルール)。ここで金を使うと勲章の意味が薄まる。
    /// 表示は「12位」/ "#12" だけ (形容詞は付けない = ユーザー判断)
    @ViewBuilder
    private var rankPillView: some View {
        if let rank {
            let isJa = (AppLanguage(rawValue: mainLanguageRaw) ?? .deviceDefault) == .japanese
            let pill = HStack(alignment: .lastTextBaseline, spacing: 2) {
                if !isJa {
                    Text("#")
                        .font(.custom("Montserrat-BlackItalic", size: 11))
                        .opacity(0.9)
                }
                Text("\(rank)")
                    .font(.custom("Montserrat-BlackItalic", size: 16))
                    .monospacedDigit()
                if isJa {
                    Text("位")
                        .font(.system(size: 11, weight: .heavy))
                        .opacity(0.9)
                }
            }
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)

            let glassPill = Group {
                if #available(iOS 26.0, *) {
                    pill
                        .glassEffect(.regular.interactive())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                } else {
                    pill
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                }
            }

            if let onRankTap {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onRankTap()
                } label: { glassPill }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(rank)位。タップでランキングを表示")
            } else {
                glassPill.accessibilityLabel("\(rank)位")
            }
        }
    }

    private var heroOverlayText: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 上位%バッジ (改8): BeReal のストリークピルと同じ文法 — 名前の上に半透明黒地のピル
            // (2026-07-30 ユーザー指定、参考スクショ=BeRealプロフィールの🔥3)
            HStack(spacing: 6) {
                topPercentBadgeView
                rankPillView
            }
            .padding(.bottom, 6)

            HStack(spacing: 7) {
                StrokedText(
                    text: displayName,
                    font: .systemFont(ofSize: 28, weight: .bold),
                    adjustsFontSize: true,
                    minimumScale: 0.6
                )

                if isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.blue)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        // ProfileHero は lang を持たないため、旧コードにあわせ日本語固定 (このファイルは a11y のみの変更範囲)
                        .accessibilityLabel("公式")
                }

            }

            if let handle, !handle.isEmpty {
                HandleCopyLabel(handle: handle)
            }

            if let bio, !bio.isEmpty {
                // 🔴 既に改行入りで保存されている bio が本番に実在する (2026-09-09 確認)。
                //    2行しか出さない場所なので、改行をそのまま流すと2行目以降が全部消える。
                //    表示側でも空白に潰して、行を素直に折り返させる
                let flatBio = bio.split(whereSeparator: \.isNewline).joined(separator: " ")
                StrokedText(
                    text: flatBio,
                    font: .systemFont(ofSize: 13),
                    textColor: UIColor.white.withAlphaComponent(0.85),
                    lineLimit: 2
                )
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(stats) { stat in
                Group {
                    if let action = stat.action {
                        Button(action: action) { statContent(stat) }
                            .buttonStyle(PlainButtonStyle())
                    } else {
                        statContent(stat)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func statContent(_ stat: ProfileHeroStat) -> some View {
        VStack(spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(stat.gold
                    ? (stat.value == "—" ? AppColors.textTertiary : AppColors.gold)
                    : AppColors.textPrimary)
            Text(stat.label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - Action Button (BeReal 風の横長。フォロー時はアイコンが plus→checkmark にバウンス)

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let actionIcon {
                    Image(systemName: actionIcon)
                        .font(.system(size: 14, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(actionIsProminent ? AppColors.background : AppColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(actionIsProminent ? AppColors.textPrimary : AppColors.cardBackground)
            )
            .overlay(
                Capsule()
                    .stroke(actionIsProminent ? Color.clear : AppColors.textTertiary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        // actionIcon / actionIsProminent / title の変化 (フォロー完了) をアニメーションさせる
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: actionIcon)
    }

    // MARK: - Chips (2026-07-16 統計パック: 累計ロック / 連続 / 完遂率 / 上位% を 2×2 グリッドに完全集約)
    //
    // 規律アプリの誇りの指標として一回り大きく、数字主役の 2 段構成。
    // 上位% (gold) は金の細枠 + 金文字の勲章。金はブランドルール上この用途のみ許可。
    // 4個前提だが件数に依存しない描画 (2要素ずつ横に並べる VStack) にしてある

    private var chipsRow: some View {
        let rows = stride(from: 0, to: chips.count, by: 2).map { start in
            Array(chips[start..<min(start + 2, chips.count)])
        }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowChips in
                HStack(spacing: 10) {
                    ForEach(rowChips) { chip in
                        if chip.detail != nil {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                detailChip = chip
                            } label: {
                                chipCell(chip)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            chipCell(chip)
                        }
                    }
                }
            }
        }
        // 中央アラート型の軽いモーダル (2026-07-17 ユーザー指定: TikTok の「いいねのトータル数」ダイアログ)。
        // ボトムシートではなく画面中央に浮かせるため、背景を透明にした fullScreenCover に載せる
        .fullScreenCover(item: $detailChip) { chip in
            if let detail = chip.detail {
                ChipDetailModal(chip: chip, detail: detail) { detailChip = nil }
                    .presentationBackground(.clear)
            }
        }
        // fullScreenCover 既定の「下からスライド」を殺す。これを切らないと
        // 中央モーダルが画面下から せり上がってきて、アラートらしい即時性が出ない
        // (出現/消滅のアニメーションは ChipDetailModal 内の fade + scale が担当)
        .transaction { $0.disablesAnimations = true }
    }

    private func chipCell(_ chip: ProfileHeroChip) -> some View {
        let isEmpty = chip.value == "—"
        // アイコンのテーマ色は値の有無に関わらず常に保つ (2026-07-17 実機FB:
        // 以前は "—" でアイコンまで無彩色に落としていたため、詳細モーダル (常に色付き) と
        // 見た目が食い違い「プロフィールだけ色が付いていない」ように見えた)。
        // 無彩色に落とすのは数値側だけ (データが無いのは値であってアイコンの正体ではない)
        let theme: Color = chip.gold ? AppColors.gold : (chip.tint ?? AppColors.textSecondary)
        let valueColor = isEmpty ? AppColors.textTertiary
            : (chip.gold ? AppColors.gold : AppColors.textPrimary)

        return HStack(spacing: 10) {
            // アイコンは薄い色地の角丸コンテナに載せる (2026-07-16 リッチ化)
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.opacity(0.16))
                Image(systemName: chip.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.value)
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundColor(valueColor)
                Text(chip.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(chip.gold && !isEmpty
                        ? AppColors.gold.opacity(0.75)
                        : AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // カード (background) より内側で幅いっぱいに広げる。外側で広げると
        // カード自体は固有幅のままカラム中央に浮き、2×2 のセル幅が不揃いになる
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(chip.gold && !isEmpty ? AppColors.gold.opacity(0.08) : AppColors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    chip.gold && !isEmpty ? AppColors.gold.opacity(0.45) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - 統計シート (2026-07-30 実機FB「しょぼすぎる」→ 共通コンポーネント化+高級化)
// 入口によって主役が変わる: 累計ロックタップ=ロック時間がヒーロー / 上位%ピルタップ=上位%がヒーロー。
// ヒーロー数字はワードマークと同じ Montserrat BlackItalic。
// 金装飾は 2026-07-30 実機FBで撤去 (シート内は無彩色で統一)

struct ProfileStatsSheetRow: Identifiable {
    /// 白黒シンプルなSF Symbol名 (2026-07-30 実機FB「白黒のアイコンつけれない?」)
    let icon: String
    let label: String
    let value: String
    /// タップで別画面へ送る行 (2026-09-09: 順位行 → ランキング)。nil なら表示のみ
    var action: (() -> Void)? = nil
    var id: String { label }
}

struct ProfileStatsSheet: View {
    // Identifiable なのは sheet(item:) で出すため (2026-07-30 実機FB: sheet(isPresented:)+
    // 別@Stateの組では初回 presentation がフォーカス変更前の状態で描かれるバグがあった)
    enum Focus: Identifiable {
        case lockTime
        case topPercent
        var id: Self { self }
    }

    let focus: Focus
    let lockTimeText: String
    /// TOP10%以内なら数値。圏外/不足は nil → topPercentText へフォールバック
    let topPercentValue: Int?
    let topPercentText: String
    let rows: [ProfileStatsSheetRow]

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }
    private var isJa: Bool { lang == .japanese }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(AppColors.textTertiary.opacity(0.4))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            // ヒーロー数字 (入口の統計が主役)
            VStack(alignment: .leading, spacing: 6) {
                // 上位%フォーカスの見出しは「上位%」でなく説明文そのもの (2026-07-30 実機FB:
                // 「上位3%って何が?」に一番上で答える)
                Text(focus == .lockTime ? L.profileLockTime(lang) : L.statSheetTopPercentHeader(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.2)
                    .foregroundColor(AppColors.textTertiary)
                    .textCase(.uppercase)

                switch focus {
                case .lockTime:
                    Text(lockTimeText)
                        .font(.custom("Montserrat-BlackItalic", size: 46))
                        .foregroundColor(AppColors.textPrimary)
                case .topPercent:
                    if let v = topPercentValue {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(isJa ? "上位" : "TOP")
                                .font(isJa ? .system(size: 20, weight: .heavy) : .custom("Montserrat-BlackItalic", size: 18))
                                .foregroundColor(AppColors.textSecondary)
                            Text("\(v)%")
                                .font(.custom("Montserrat-BlackItalic", size: 46))
                                .foregroundColor(AppColors.textPrimary)
                        }
                    } else {
                        Text(topPercentText)
                            .font(.custom("Montserrat-BlackItalic", size: 46))
                            .foregroundColor(AppColors.textPrimary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Rectangle()
                .fill(AppColors.textTertiary.opacity(0.14))
                .frame(height: 0.5)
                .padding(.horizontal, 24)
                .padding(.top, 20)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    let line = HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textTertiary)
                            .frame(width: 20, alignment: .center)
                        Text(row.label)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Text(row.value)
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(AppColors.textPrimary)
                        // タップできる行だけ chevron を出す (押せると分かるように)
                        if row.action != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                    Group {
                        if let action = row.action {
                            Button(action: action) { line.contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                        } else {
                            line
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(AppColors.textTertiary.opacity(0.10))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}
