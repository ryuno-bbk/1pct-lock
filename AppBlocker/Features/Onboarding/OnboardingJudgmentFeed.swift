//
//  OnboardingJudgmentFeed.swift
//  AppBlocker
//
//  「ライブ審査」演出 (2026-07-29 ユーザー発案、v1=Fable裁量実装)。
//  v1はフック画面に置いたが、実機FBで「これらは流れてこない」(ModerationPolicyStepView) へ
//  移設 (フック画面はARISE型ヒーローに刷新)。投稿カードが上から1枚ずつ落ちてきて、
//  中央でスキャン→カテゴリラベルが付く→合格なら下 (フィード方向) へ流れ込み、
//  不合格なら赤転して横へ弾き飛ばされる。AIモデレーションという主張を文字でなく
//  目の前の出来事として見せる。親フレームに埋め込む前提 (カードは親の中央に配置)。
//
//  トーン設計 (「Sっぽく/悪趣味になる」懸念への回避):
//  - 裁きの演出ではなく「検問」— 静かなスキャンと淡々とした通過がベース。
//    赤を使うのは不合格の一瞬だけ。動きはブランド原則どおり光とスケール中心
//  - スタンプ/バウンス/回転過多は使わない (弾き出しの傾き -12° のみ)
//
//  ロールバック: FeedPreviewHookView で JudgmentFeedView → FeedMarquee に戻すだけ
//  (FeedMarquee は残置)。
//

import SwiftUI

// MARK: - 台本

/// 審査される1枚。ラベルは判定チップに出すカテゴリ名 // 文言はユーザー添削待ち
struct JudgmentItem {
    let image: String
    let labelJa: String
    let labelEn: String
    let pass: Bool
}

enum JudgmentScript {
    /// 表示言語に応じた台本 (2026-07-31 実機FB)。
    /// 英語版から外すもの:
    ///   - パチンコ: 日本固有の遊技で英語圏には文脈が伝わらない (ユーザー指定)。
    ///     代わりに2枚目=パーティーにする (掴みは「弾かれる方」を早く見せる方針を維持)
    ///   - 日本語が焼き込まれた良い投稿5枚 (腕の日 / 4食分作った / 今から商談 / 朝ラン /
    ///     食い終わったら走って勉強) — 英語ユーザーに日本語の画像を見せないため。
    ///     英語版で使える良い投稿は「5:20」「HARD WORK」「LEG DAY」「文字なし」の4枚
    /// 英語版は計12枚 (良4 + NG8)。ブランド画像を英語版込みで作り直したらここに足す
    static func items(for lang: AppLanguage) -> [JudgmentItem] {
        lang == .japanese ? japanese : english
    }

    /// 2026-07-29 実機FB: 「見せたいのは弾かれる方」→ NG全9枚を使い、2枚目から早速
    /// 弾かれる例を見せる (冒頭 良→悪→悪 の掴み)。以降はほぼ交互。
    /// 画像は既存の OnboardingPosts アセット (良い投稿=焼き込み済みから9枚、NG=テキスト無し新素材9枚)
    static let japanese: [JudgmentItem] = [
        JudgmentItem(image: "run-park-female-pov",       labelJa: "ランニング",   labelEn: "Running",   pass: true),
        JudgmentItem(image: "moderate-pachinko",         labelJa: "ギャンブル",   labelEn: "Gambling",  pass: false),
        JudgmentItem(image: "moderate-izakaya-beer",     labelJa: "飲み会",       labelEn: "Drinking",  pass: false),
        JudgmentItem(image: "study-desk-laptop",         labelJa: "勉強",         labelEn: "Study",     pass: true),
        JudgmentItem(image: "moderate-burger-drivethru", labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "gym-mirror-male",           labelJa: "筋トレ",       labelEn: "Workout",   pass: true),
        JudgmentItem(image: "moderate-karaoke",          labelJa: "夜遊び",       labelEn: "Night out", pass: false),
        JudgmentItem(image: "mealprep-containers",       labelJa: "自炊",         labelEn: "Meal prep", pass: true),
        JudgmentItem(image: "moderate-party-cups",       labelJa: "飲み会",       labelEn: "Partying",  pass: false),
        JudgmentItem(image: "study-cafe-coffee",         labelJa: "読書",         labelEn: "Reading",   pass: true), // 本+カフェの画像 (2026-07-29 勉強→読書へ修正)
        JudgmentItem(image: "moderate-ramen-jiro",       labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "business-laptop",           labelJa: "仕事",         labelEn: "Work",      pass: true),
        JudgmentItem(image: "moderate-bowling",          labelJa: "遊び",         labelEn: "Hanging out", pass: false),
        JudgmentItem(image: "gym-mirror-female",         labelJa: "筋トレ",       labelEn: "Workout",   pass: true),
        JudgmentItem(image: "moderate-movie-popcorn",    labelJa: "夜更かし",     labelEn: "Late night", pass: false),
        JudgmentItem(image: "run-scenery-snapshot",      labelJa: "ランニング",   labelEn: "Running",   pass: true),
        JudgmentItem(image: "moderate-pizza-night",      labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "mealprep-eating-plate",     labelJa: "食事管理",     labelEn: "Nutrition", pass: true),
    ]

    /// 英語版 (12枚)。日本語が写り込む画像とパチンコを除外し、2枚目=パーティー
    static let english: [JudgmentItem] = [
        JudgmentItem(image: "run-park-female-pov",       labelJa: "ランニング",   labelEn: "Running",   pass: true),  // 焼き込み="5:20"
        JudgmentItem(image: "moderate-party-cups",       labelJa: "飲み会",       labelEn: "Partying",  pass: false),
        JudgmentItem(image: "moderate-izakaya-beer",     labelJa: "飲み会",       labelEn: "Drinking",  pass: false),
        JudgmentItem(image: "study-desk-laptop",         labelJa: "勉強",         labelEn: "Study",     pass: true),  // 焼き込み="HARD WORK"
        JudgmentItem(image: "moderate-burger-drivethru", labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "gym-mirror-female",         labelJa: "筋トレ",       labelEn: "Workout",   pass: true),  // 焼き込み="LEG DAY"
        JudgmentItem(image: "moderate-karaoke",          labelJa: "夜遊び",       labelEn: "Night out", pass: false),
        JudgmentItem(image: "moderate-bowling",          labelJa: "遊び",         labelEn: "Hanging out", pass: false),
        JudgmentItem(image: "study-cafe-coffee",         labelJa: "読書",         labelEn: "Reading",   pass: true),  // 焼き込みなし
        JudgmentItem(image: "moderate-ramen-jiro",       labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
        JudgmentItem(image: "moderate-movie-popcorn",    labelJa: "夜更かし",     labelEn: "Late night", pass: false),
        JudgmentItem(image: "moderate-pizza-night",      labelJa: "ジャンクフード", labelEn: "Junk food", pass: false),
    ]
}

// MARK: - 本体

struct JudgmentFeedView: View {
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    /// カードの人生: 画面上外 → 中央へ落下 → スキャン → 判定確定 → 退場 (合格=下 / 不合格=横)
    private enum Phase {
        case offscreen, center, scanning, verdict, exited
    }

    @State private var index = 0
    @State private var phase: Phase = .offscreen
    /// スキャン光帯の走行 (0→1)。scanning 突入ごとにリセットして走らせる
    @State private var scanProgress: CGFloat = 0

    private var script: [JudgmentItem] { JudgmentScript.items(for: lang) }
    private var item: JudgmentItem { script[index % script.count] }

    var body: some View {
        GeometryReader { geo in
            // 2026-07-29 実機FB「小さい/上が見切れる」対応:
            // - カード幅 0.60→0.68 に拡大 (親フレーム基準)
            // - アスペクトを 4:5→2:3 に変更 (NG素材の原寸比。fill しても上下が切れない)。
            //   ただし親の高さに収まるよう高さ側からも制約 (小さい端末でのはみ出し防止)
            let cardW = min(geo.size.width * 0.68, (geo.size.height * 0.92) / 1.5)
            let cardH = cardW * 1.5
            // 親フレームの中央がステージ (モデレ画面に埋め込む前提。旧フック画面時代の
            // 全画面 ignoresSafeArea + 上寄せ配置は廃止)
            let stageCenterY = geo.size.height * 0.5

            ZStack {
                judgedCard(width: cardW, height: cardH)
                    .position(x: geo.size.width / 2 + offsetX(width: geo.size.width),
                              y: stageCenterY + offsetY(height: geo.size.height))
                    .rotationEffect(.degrees(rotation), anchor: .bottomLeading)
                    .opacity(cardOpacity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .task { await runLoop() }
    }

    // MARK: - カード

    private func judgedCard(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if UIImage(named: item.image) != nil {
                    Color.clear.overlay(
                        Image(item.image).resizable().aspectRatio(contentMode: .fill)
                    )
                } else {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            // 不合格確定後は彩度を抜いて「死んだ」投稿にする
            .saturation(phase == .verdict && !item.pass ? 0.15 : 1)
            .overlay(Color.black.opacity(phase == .verdict && !item.pass ? 0.35 : 0))

            // スキャン光帯 (scanning 中のみ上→下へ1回走る。ブランドの「動きは光」原則)
            if phase == .scanning {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height * 0.28)
                .offset(y: -height * 0.64 + scanProgress * height * 1.28)
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
            }

            // 判定チップ (カード左下)。scanning=ラベルのみ / verdict=アイコン+色が確定
            if phase == .scanning || phase == .verdict {
                judgmentChip
                    .padding(10)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(chipIsFail ? AppColors.error.opacity(0.6) : Color.white.opacity(0.10),
                        lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private var chipIsFail: Bool { phase == .verdict && !item.pass }
    private var chipIsPass: Bool { phase == .verdict && item.pass }

    private var judgmentChip: some View {
        HStack(spacing: 6) {
            if phase == .verdict {
                Image(systemName: item.pass ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .transition(.scale.combined(with: .opacity))
            } else {
                // スキャン中の思考ドット (静かな脈動、回転スピナーは使わない)
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(0.7)
            }

            Text(lang == .japanese ? item.labelJa : item.labelEn)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(phase == .verdict ? .white : AppColors.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            // 判定確定後: 合格=緑 / 不合格=赤 (2026-07-29 ユーザー指示「OKは緑のOK色に」)。
            // スキャン中は中立のガラス
            Capsule().fill(
                chipIsFail
                    ? AnyShapeStyle(AppColors.error.opacity(0.92))
                    : chipIsPass
                        ? AnyShapeStyle(AppColors.success.opacity(0.92))
                        : AnyShapeStyle(.ultraThinMaterial)
            )
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - フェーズ→トランスフォーム

    private func offsetY(height: CGFloat) -> CGFloat {
        switch phase {
        case .offscreen:            return -height * 0.7
        case .center, .scanning, .verdict: return 0
        case .exited:               return item.pass ? height * 0.85 : 0.06 * height
        }
    }

    private func offsetX(width: CGFloat) -> CGFloat {
        // 不合格の退場だけ横へ弾く
        (phase == .exited && !item.pass) ? -width * 1.3 : 0
    }

    private var rotation: Double {
        (phase == .exited && !item.pass) ? -12 : 0
    }

    private var cardOpacity: Double {
        switch phase {
        case .offscreen:  return 0
        case .exited:     return item.pass ? 0 : 0.9
        default:          return 1
        }
    }

    // MARK: - 進行ループ

    @MainActor
    private func runLoop() async {
        if UIAccessibility.isReduceMotionEnabled {
            // 静止表示: 合格チップ付きの1枚を置くだけ
            phase = .verdict
            return
        }

        // テンポ変遷: 2.4秒 (v1「遅い」) → 1.85秒 (「もう少し遅くて大丈夫」) → 約2.15秒/枚
        // (2026-07-29 FB3回目: スキャンとスキャンの間に呼吸を戻す)
        while !Task.isCancelled {
            // 1. 落下→中央で受け止め
            phase = .offscreen
            scanProgress = 0
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = .center }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard !Task.isCancelled else { return }

            // 2. スキャン (光帯1往路+ラベル出現)
            withAnimation(.easeOut(duration: 0.22)) { phase = .scanning }
            withAnimation(.easeInOut(duration: 0.5)) { scanProgress = 1 }
            try? await Task.sleep(nanoseconds: 620_000_000)
            guard !Task.isCancelled else { return }

            // 3. 判定確定 + ハプティクス (合格=軽 / 不合格=硬)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { phase = .verdict }
            if item.pass {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            try? await Task.sleep(nanoseconds: item.pass ? 450_000_000 : 580_000_000)
            guard !Task.isCancelled else { return }

            // 4. 退場 (合格=下のフィードへ流れ込む / 不合格=横へ弾き飛ばし)
            withAnimation(.easeIn(duration: item.pass ? 0.42 : 0.38)) { phase = .exited }
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }

            index += 1
        }
    }
}
