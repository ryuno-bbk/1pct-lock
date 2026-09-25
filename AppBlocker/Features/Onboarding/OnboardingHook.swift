//
//  OnboardingHook.swift
//  AppBlocker
//
//  診断オンボーディング PHASE 0: スプラッシュ (モノグラム起動アニメ) と
//  フィードプレビュー (AI生成投稿の縦ループ) のフック。
//
//  - モノグラムはアイコンPNGでなく図形を直接描く (AreteWatermark の b1Mark と同じ
//    viewBox 100 換算: 棒 x44 y20 w12 h60 rx6 / ドット r9.5 中心 (26,31),(74,69))
//  - フィードプレビューは Assets の "OnboardingFeed1"〜"OnboardingFeed6" を表示。
//    画像未投入の間はモノクロのグラデーションでフォールバックし、開発を止めない
//

import SwiftUI

// MARK: - 1. スプラッシュ (モノグラム起動)

struct MonogramSplashView: View {
    let onContinue: () -> Void

    // 「刻印」演出の段階 (2026-07-17 全面刷新。旧「ドットが対角から飛んでくる」吸着演出は
    // ユーザーFBで「ダサい」と却下 → 要素は移動させず、その場で結像させる方向に転換)
    @State private var barGrown = false
    @State private var dot1Shown = false
    @State private var dot2Shown = false
    @State private var settled = false
    @State private var showWordmark = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            SplashMonogram(
                barGrown: barGrown,
                dot1Shown: dot1Shown,
                dot2Shown: dot2Shown,
                settled: settled,
                size: 108
            )

            Text("1%")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .opacity(showWordmark ? 1 : 0)
                .offset(y: showWordmark ? 0 : 6)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if UIAccessibility.isReduceMotionEnabled {
                barGrown = true; dot1Shown = true; dot2Shown = true
                settled = true; showWordmark = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onContinue() }
                return
            }
            // 1. 縦棒が中心から一気に伸びる (easeOutExpo 系カーブ)
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                barGrown = true
            }
            // 2. ドットは飛んでこない — その場でボケから結像する (ずらして2つ)
            withAnimation(.easeOut(duration: 0.45).delay(0.4)) { dot1Shown = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.58)) { dot2Shown = true }
            // 3. 全体がわずかに沈んで「置かれる」+ ハプティクス1回
            withAnimation(.easeOut(duration: 0.45).delay(1.0)) { settled = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                QuizHaptics.light()
            }
            // 4. ワードマークが下から浮き上がる
            withAnimation(.easeOut(duration: 0.4).delay(1.15)) {
                showWordmark = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                onContinue()
            }
        }
    }
}

/// スプラッシュ専用のモノグラム (刻印コレオグラフィー用)。
/// ジオメトリは MonogramMark と同一 (viewBox 100: 縦棒 50,50/w12h60、ドット r9.5 @(26,31)(74,69)) だが、
/// ドットを移動でなく「ボケ→結像」(blur+scale+opacity) で出すためのパラメータを持つ。
/// 汎用の MonogramMark は他所 (ローダーのマスク等) で使うため触らない
private struct SplashMonogram: View {
    let barGrown: Bool
    let dot1Shown: Bool
    let dot2Shown: Bool
    let settled: Bool
    let size: CGFloat

    var body: some View {
        let s = size / 100

        ZStack {
            RoundedRectangle(cornerRadius: 6 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 12 * s, height: 60 * s)
                .scaleEffect(y: barGrown ? 1 : 0.02, anchor: .center)
                .position(x: 50 * s, y: 50 * s)

            dot(x: 26, y: 31, shown: dot1Shown, s: s)
            dot(x: 74, y: 69, shown: dot2Shown, s: s)
        }
        .frame(width: size, height: size)
        // 結像後にわずかに沈んで等倍へ (「置かれた」感)。巨大View への scaleEffect 禁止 (S16) の対象外
        .scaleEffect(settled ? 1.0 : 1.03)
    }

    private func dot(x: CGFloat, y: CGFloat, shown: Bool, s: CGFloat) -> some View {
        Circle()
            .fill(AppColors.textPrimary)
            .frame(width: 19 * s, height: 19 * s)
            .scaleEffect(shown ? 1 : 1.45)
            .blur(radius: shown ? 0 : 5)
            .opacity(shown ? 1 : 0)
            .position(x: x * s, y: y * s)
    }
}

/// 太字モノグラム (2026-07-29 ヒーロー画面用に新設)。プライマリアイコン「クラシック
/// (太字モノグラム)」と同族のプロポーション: 棒とドットを MonogramMark より肉厚に。
/// ベクター描画なので背景 (煙) を四角く隠さない (アイコンPNG直置きだと黒タイルが煙を遮る)
struct MonogramMarkBold: View {
    let size: CGFloat

    var body: some View {
        let s = size / 100

        ZStack {
            // 縦棒: 幅12→20、角丸も肉厚に
            RoundedRectangle(cornerRadius: 10 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 20 * s, height: 62 * s)
                .position(x: 50 * s, y: 50 * s)

            // ドット: r9.5→r13
            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 26 * s, height: 26 * s)
                .position(x: 24 * s, y: 28 * s)

            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 26 * s, height: 26 * s)
                .position(x: 76 * s, y: 72 * s)
        }
        .frame(width: size, height: size)
    }
}

/// 1% モノグラム (縦棒 + 対角ドット2つ)。assembled=false の間はドットが対角の外に散っている
struct MonogramMark: View {
    let assembled: Bool
    let size: CGFloat

    var body: some View {
        let s = size / 100   // viewBox 100 換算

        ZStack {
            // 縦棒 (x44 y20 w12 h60 rx6)
            RoundedRectangle(cornerRadius: 6 * s)
                .fill(AppColors.textPrimary)
                .frame(width: 12 * s, height: 60 * s)
                .scaleEffect(y: assembled ? 1 : 0.01, anchor: .center)
                .position(x: 50 * s, y: 50 * s)

            // ドット (r9.5, 中心 (26,31) / (74,69))
            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 19 * s, height: 19 * s)
                .position(x: 26 * s, y: 31 * s)
                .offset(x: assembled ? 0 : -46 * s, y: assembled ? 0 : -46 * s)
                .opacity(assembled ? 1 : 0)

            Circle()
                .fill(AppColors.textPrimary)
                .frame(width: 19 * s, height: 19 * s)
                .position(x: 74 * s, y: 69 * s)
                .offset(x: assembled ? 0 : 46 * s, y: assembled ? 0 : 46 * s)
                .opacity(assembled ? 1 : 0)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 投稿画像アセット (テキストは画像に焼き込み済み)

/// フィードプレビューの1投稿。画像はテキスト焼き込み済み、正方形で表示する。
/// username / title / likes / comments はダミー (Fable 割当)。likes / comments は表示に使わない
/// (2026-09-26 反応数の表示を撤去。HookPostCard 参照)。
/// avatar はユーザーが後で送るアイコン asset 名 (nil ならプレースホルダ表示)。
struct HookFeedPost: Identifiable {
    let id = UUID()
    let image: String
    let username: String
    let title: String
    let likes: Int
    let comments: Int
    var avatar: String? = nil
}

/// フィードプレビューに流す「良い投稿」13枚 (Assets/OnboardingPosts)。
/// 焼き込みは Docs/onboarding_image_prompts.md 参照。無ければグラデーションでフォールバック
enum OnboardingFeedAssets {
    static let good: [HookFeedPost] = [
        HookFeedPost(image: "gym-mirror-female",     username: "@rina_lifts", title: "脚の日は逃げない。今日も潰してきた", likes: 214, comments: 18),
        HookFeedPost(image: "mealprep-containers",   username: "@kenta_fuel", title: "日曜の30分で平日が決まる",          likes: 156, comments: 9),
        HookFeedPost(image: "study-desk-laptop",     username: "@sho_study",  title: "テスト2週間前。ここからが本番",      likes: 302, comments: 24),
        HookFeedPost(image: "run-park-female-pov",   username: "@miku_runs",  title: "朝の街はまだ静か。5kmだけ",          likes: 189, comments: 11),
        HookFeedPost(image: "gym-mirror-male",       username: "@takumi_gym", title: "腕の日。パンプが正義",              likes: 271, comments: 15),
        HookFeedPost(image: "business-laptop",       username: "@yuto_biz",   title: "スーツに着替えた。勝ってくる",       likes: 98,  comments: 6),
        HookFeedPost(image: "study-book-only",       username: "@nao_kei",    title: "眠い。でも夢の方が強い",            likes: 233, comments: 20),
        HookFeedPost(image: "mealprep-eating-plate", username: "@gym_daily",  title: "食う。走る。読む。以上",            likes: 145, comments: 8),
        HookFeedPost(image: "run-scenery-snapshot",  username: "@run_sora",   title: "誰もいない朝を独り占め",            likes: 176, comments: 10),
        HookFeedPost(image: "gym-mirror-foreign",    username: "@leo_fit",    title: "Chest day. No excuses",           likes: 320, comments: 22),
        HookFeedPost(image: "gym-equipment-only",    username: "@iron_note",  title: "仕事終わり。ジムが一日の締め",       likes: 134, comments: 7),
        HookFeedPost(image: "study-cafe-coffee",     username: "@mari_reads", title: "カフェで2時間。集中できた",         likes: 121, comments: 9),
        HookFeedPost(image: "business-stock-chart",  username: "@invest_k",   title: "淡々と積み立てるだけ",              likes: 88,  comments: 5)
    ]
    /// モデレーションページに出す「削除対象」9枚 (2026-07-29 ユーザー支給の新素材に全面差し替え。
    /// 旧6枚は日本語焼き込み入りで海外ユーザーに不自然だった → 新素材は全てテキスト無しの
    /// 日英共通。並びは同カテゴリが隣接しないよう 酒/ギャンブル/ジャンク/遊び/夜更かし を交互配置)
    static let moderate: [String] = [
        "moderate-izakaya-beer",      // 居酒屋ビール乾杯 (JP)
        "moderate-pachinko",          // パチンコ (ギャンブル)
        "moderate-burger-drivethru",  // 車内バーガー
        "moderate-karaoke",           // カラオケ
        "moderate-party-cups",        // ハウスパーティー赤カップ (海外)
        "moderate-ramen-jiro",        // 二郎系ラーメン (JP)
        "moderate-bowling",           // ボウリング
        "moderate-movie-popcorn",     // 夜更かし映画+ポップコーン
        "moderate-pizza-night"        // ピザ+映画
    ]
    // 旧アセット (moderate-drinking-izakaya-toast / moderate-junkfood-burger /
    // moderate-game-controller / moderate-drinking-bar / moderate-junkfood-chips /
    // moderate-game-desk) は未参照のままAssetsに残置 — 削除はユーザー確認後
}

// MARK: - 2. フィードプレビュー (フック)

struct FeedPreviewHookView: View {
    let onStart: () -> Void
    let onAlreadyHasAccount: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// 背景のケンバーンズ (超スローズーム)。onAppear で 1.06→1.0
    @State private var backdropSettled = false
    @State private var showWordmark = false
    @State private var showTagline = false

    var body: some View {
        ZStack {
            // ARISE型ヒーロー (2026-07-29 ユーザー指定で全面刷新。参考=海外モチベ系アプリの
            // ファーストビュー: 雰囲気背景 + 中央に巨大ワードマーク + タグライン + 白ピルCTA)。
            // 審査演出 (JudgmentFeedView) はモデレ画面へ移設した。
            heroBackdrop

            // 暗幕: ワードマークとCTAの可読性確保 (上下を締める)
            LinearGradient(
                colors: [
                    AppColors.background.opacity(0.55),
                    AppColors.background.opacity(0.15),
                    AppColors.background.opacity(0.30),
                    AppColors.background.opacity(0.92)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 上部: クラシックアイコンの「くり抜き」グリフ (2026-07-29 実機FB5回目で確定:
                // タイル直置きは「上がアプリアイコンみたいになる」で却下 → 実アイコンPNGから
                // 輝度→アルファ変換で切り出した真っ白グリフ (HeroClassicGlyph imageset、
                // 生成スクリプトはPIL・メモリ参照)。本物由来なのでドット比率のズレは構造的に無い
                Image("HeroClassicGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 54)
                    .padding(.top, 18)

                Spacer()

                // 中央: 巨大ワードマーク (Montserrat Black Italic = ARISE系のヘビーイタリック表示体。
                // OFLライセンス、Resources/Fonts + Info.plist UIAppFonts で登録。
                // ⚠️ ワードマーク専用 — UI本文には使わない (フォント統一原則はシステムフォントのまま)。
                // フォント未登録環境では Font.custom が自動でシステムフォントにフォールバックする)
                // 登場 = ブランドの「ボケ→結像」文法 (blur 8→0 + 沈み 18pt + 0.96→等倍、0.9s)
                Text("1%")
                    .font(.custom("Montserrat-BlackItalic", size: 104))
                    .foregroundColor(AppColors.textPrimary)
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 4)
                    .opacity(showWordmark ? 1 : 0)
                    .blur(radius: showWordmark ? 0 : 8)
                    .scaleEffect(showWordmark ? 1 : 0.96)
                    .offset(y: showWordmark ? 0 : 18)

                // タグライン: 英語=「Not for everyone.」ユーザー確定 (2026-07-29)。
                // 日本語は検討中のため暫定で同文を使用 — 候補: 「上位1%のためのSNS」(ユーザー発言)
                Text("Not for everyone.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .opacity(showTagline ? 1 : 0)
                    .blur(radius: showTagline ? 0 : 5)
                    .offset(y: showTagline ? 0 : 14)

                Spacer()

                PrimaryButton(lang == .japanese ? "始める" : "Get Started", icon: "arrow.right") {
                    onStart()
                }
                .padding(.horizontal, 24)

                Button(action: onAlreadyHasAccount) {
                    Text(lang == .japanese ? "すでにアカウントを持っている" : "I already have an account")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                        .underline()
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            guard !UIAccessibility.isReduceMotionEnabled else {
                backdropSettled = true; showWordmark = true; showTagline = true
                return
            }
            // 背景: 超スローで寄りが引く (ケンバーンズ)。
            // 文字: ボケ→結像+浮上を段階的に (2026-07-29 FB「もっと目立つように」→
            // 時間を伸ばし・ずらしを深く。スプラッシュ廃止でここがアプリの第一声になった)
            withAnimation(.easeOut(duration: 14)) { backdropSettled = true }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(0.25)) { showWordmark = true }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.85).delay(0.65)) { showTagline = true }
        }
    }

    /// 背景アート。Assets に "HeroBackdrop" imageset を入れると自動で表示される
    /// (ユーザーがAI生成予定 2026-07-29)。未投入の間は**動く煙** (HeroSmoke.metal の
    /// 手続き生成FBM、動画アセット不要・無限ループ) + 中央のかすかなグロウでフォールバック
    @ViewBuilder
    private var heroBackdrop: some View {
        if UIImage(named: "HeroBackdrop") != nil {
            Color.clear.overlay(
                Image("HeroBackdrop")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(backdropSettled ? 1.0 : 1.06)
            )
            .ignoresSafeArea()
        } else {
            SmokeBackdrop()
                .ignoresSafeArea()
        }
    }
}

// SmokeBackdrop は DesignSystem/Components/SmokeBackdrop.swift へ共有化 (2026-07-30、
// 公式プロフィールヒーローでも使うため。実装・見た目は不変)

/// 実フィード (FeedListCard) に寄せたカードレス投稿UI (ヘッダ=アバター+名前 / 4:5画像 /
/// 画像内オーバーレイのいいね・コメントアイコン) が縦にゆっくり流れ続ける無限ループ。
///
/// シームレスループの実装: カード列を2セット縦に並べ、1セットぶんの高さ (setHeight) だけ
/// 等速スクロールしたら offset を 0 に巻き戻す。巻き戻り先 (offset=0, 1セット目の先頭) と
/// 巻き戻り元 (offset=-setHeight, 2セット目の先頭) はまったく同じ内容なので、切り替わりが
/// 視覚的に発生しない。ポイントは setHeight が「実際にレイアウトされた1セットの高さ」と
/// 完全一致していること — 手計算の推定値だとフォント/行間の誤差で数ptズレ、そこで
/// 一瞬「瞬間移動」して見える。そのため PreferenceKey で1セット目の高さを実測し、
/// 実測値が届くまでは推定値をフォールバックとして使う。
private struct FeedMarquee: View {
    let posts: [HookFeedPost]

    private let gap: CGFloat = 14
    private let hPadding: CGFloat = 16
    private var duration: Double { Double(posts.count) * 4.6 }

    /// アニメーションの起点時刻。context.date (壁時計) をそのまま使わず経過時間に変換することで、
    /// 大きな絶対時刻値による浮動小数点誤差の余地をなくす
    @State private var startDate = Date()
    /// 1セットの実測高さ。届くまでは推定値 (下記 estimatedSetHeight) をフォールバック表示に使う
    @State private var measuredSetHeight: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width - hPadding * 2
            // 画像は 4:5。カード高さ推定 = ヘッダ(~42: アバター30+スペーシング) + 画像(cardW*5/4)
            let imgH = cardW * 5.0 / 4.0
            let estimatedSetHeight = CGFloat(posts.count) * (imgH + 42 + gap)
            let setHeight = measuredSetHeight ?? estimatedSetHeight

            Group {
                if UIAccessibility.isReduceMotionEnabled {
                    cardStack(imgW: cardW, imgH: imgH)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let elapsed = context.date.timeIntervalSince(startDate)
                        let t = elapsed.truncatingRemainder(dividingBy: duration) / duration
                        VStack(spacing: gap) {
                            measuredCardStack(imgW: cardW, imgH: imgH)
                            cardStack(imgW: cardW, imgH: imgH)
                        }
                        .offset(y: -setHeight * CGFloat(t))
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func cardStack(imgW: CGFloat, imgH: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(posts) { post in
                HookPostCard(post: post, imgW: imgW, imgH: imgH)
            }
        }
        .padding(.horizontal, hPadding)
    }

    /// 1セット目相当。実際にレイアウトされた高さを PreferenceKey 経由で測って measuredSetHeight に反映する
    private func measuredCardStack(imgW: CGFloat, imgH: CGFloat) -> some View {
        cardStack(imgW: imgW, imgH: imgH)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeSetHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(MarqueeSetHeightKey.self) { height in
                if height > 0 { measuredSetHeight = height }
            }
    }
}

/// FeedMarquee の1セットぶんの実測高さを子から親へ伝えるための PreferenceKey
private struct MarqueeSetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 実フィード (FeedListCard, 2026-07-10 カードレス仕様) の視覚文法を踏襲したカード:
/// ヘッダ (アバター+名前) は画像の外・上に置く、カード背景/枠線は持たない、
/// 角丸18は画像だけが持つ、画像は fit+同画像ぼかし埋め、いいね♥/コメント💬は
/// 画像内右下にアイコンのみでオーバーレイ、画像内左下に「例」バッジ。
/// アバターはユーザー提供予定 (asset があれば表示、無ければプレースホルダ)。ネットワークなし、自己完結。
/// 2026-09-26: 捏造した反応数 (いいね 数百〜約8万 / コメント 数十〜約4,200) の表示を撤去し、
/// 左下のバッジを「例」表記に置き換えた (実在の投稿・反応に見せない。数字は別の値で埋めない)
private struct HookPostCard: View {
    let post: HookFeedPost
    let imgW: CGFloat
    let imgH: CGFloat

    // 「例」バッジの言語出し分け用: FeedPreviewHookView と同じ AppStorage キーを直接読む
    // (init シグネチャは変更しない = lang を引数追加しない)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ヘッダ: アバター + ユーザー名 (画像の外。カードレスなので背景/枠線を持たない)
            HStack(spacing: 9) {
                avatar
                Text(post.username)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            // 4:5 の画像枠。画像は全体を見せる (見切れさせない = scaledToFit)。
            // 余白は同じ画像のぼかしで埋める (黒帯を出さない IG/BeReal 式)。角丸は画像だけが持つ
            ZStack {
                if UIImage(named: post.image) != nil {
                    Image(post.image).resizable().scaledToFill()
                        .frame(width: imgW, height: imgH).clipped().blur(radius: 18).opacity(0.55)
                        // ぼかしは TimelineView 30fps 駆動のマルキーで毎フレーム再計算される GPU コストが大きいため、
                        // このレイヤーだけ Metal オフスクリーンで一度だけラスタライズする
                        // (S16 の 10fps 事故と同系統のコスト。見た目は不変、このレイヤーのみ影響。FeedListCard.swift の imageFitBlur と同じパターン)
                        .drawingGroup()
                    Image(post.image).resizable().scaledToFit()
                        .frame(width: imgW, height: imgH)
                } else {
                    LinearGradient(colors: [Color(white: 0.26), Color(white: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: imgW, height: imgH)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) { exampleBadge }
            .overlay(alignment: .bottomTrailing) { actionIcons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画像内左下: 「例」バッジ (旧いいね数バッジと同じ位置・見た目。2026-09-26 に数字を撤去)
    private var exampleBadge: some View {
        Text(lang == .japanese ? "例" : "Example") // 文言はユーザー添削待ち
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(10)
    }

    /// 画像内右下: いいね + コメント (実フィードと同じ BeReal 式アイコンのみオーバーレイ)。
    /// アイコン下のカウント数字 (捏造値) は 2026-09-26 に撤去。数字は出さない
    private var actionIcons: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 25))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(width: 40, height: 32)
            }
            .frame(width: 40)

            VStack(spacing: 2) {
                Image(systemName: "ellipsis.bubble.fill")
                    .font(.system(size: 23))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(width: 40, height: 32)
            }
            .frame(width: 40)
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var avatar: some View {
        if let name = post.avatar, UIImage(named: name) != nil {
            Image(name).resizable().scaledToFill()
                .frame(width: 30, height: 30).clipShape(Circle())
        } else {
            // ユーザーがアイコンを送るまでのプレースホルダ (名前頭文字)
            Circle()
                .fill(AppColors.secondaryBackground)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(post.username.dropFirst().prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppColors.textSecondary)
                )
        }
    }
}
