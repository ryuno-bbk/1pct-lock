//
//  ScrollChallengeView.swift
//  AppBlocker
//
//  解除課題「みんなの進捗を見る」「自分で決めた画像を見る」の共通部品。
//
//  🔴 この画面の肝は「やっぱり作業を続ける」ボタン (2026-08-29 ユーザー発案):
//    いまの解除は「解除する or 何もしない」の二択で、**「やめる」が画面に存在しない**。
//    人は目の前にある選択肢しか選ばない。強制的に見せている最中に「やめる」を
//    常に置いておくことで、摩擦を**決断の機会**に変える。
//
//  🔴 投稿モードは本物のフィードUIをそのまま使う。
//    このアプリは AI モデレーションで規律エトス以外を弾いており、流れてくるのは
//    他人を鼓舞する投稿だけ。**コメントを読むこと自体が目的に合致する**ので
//    いいねもコメントも塞がない (2026-08-29 ユーザー判断)。
//

import SwiftUI
import UIKit

struct ScrollChallengeView: View {

    enum Page: Identifiable {
        case post(FeedItem)
        case image(id: String, image: UIImage)

        var id: String {
            switch self {
            case .post(let item):    return "post-\(item.id)"
            case .image(let id, _):  return "image-\(id)"
            }
        }
    }

    let pages: [Page]
    /// 何件見たら解除できるようになるか (指定値)
    let requiredCount: Int
    let lang: AppLanguage
    let onCompleted: () -> Void
    /// 🔴 やっぱり作業を続ける (= 解除をやめてロックに戻る)
    let onKeepWorking: () -> Void

    /// 十分に見たと認めたページ
    @State private var seen: Set<String> = []
    /// いま画面に半分以上見えているページ
    @State private var visibleIds: Set<String> = []
    /// 🔴 1件たまったあと、次を数える前にスクロールを要求するフラグ。
    ///    最初から2枚とも50%以上見えていると、指を動かさなくても2件進んでしまう
    ///    (2026-08-29 実機報告)。ユーザーの診断どおり
    @State private var awaitingScroll = false
    /// いま計測しているページ
    @State private var currentId: String?
    /// メーターの表示値 (0...1)
    @State private var meterProgress: Double = 0
    @State private var dwellTask: Task<Void, Never>?

    @AppStorage("showOriginal") private var showOriginal = false

    /// 1ページを「見た」と認めるまでの秒数。⚠️ 実機で調整する値
    private static let dwellSeconds: Double = 3.0

    private var ja: Bool { lang == .japanese }

    /// 🔴 手持ちのページ数を超える件数は要求しない。
    ///    画像が3枚しか無いのに5件要求すると**永久に解除できなくなる**
    ///    (2026-08-29 実機で「あと2件から進まない」として発現)
    private var required: Int { max(1, min(requiredCount, pages.count)) }

    private var progress: Int { min(seen.count, required) }
    private var canUnlock: Bool { seen.count >= required }

    private var postItems: [FeedItem] {
        pages.compactMap { if case .post(let item) = $0 { return item } else { return nil } }
    }
    private var isPostMode: Bool { !postItems.isEmpty }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                if pages.isEmpty {
                    emptyState
                } else if isPostMode {
                    FeedCardListView(
                        items: postItems,
                        recordsViews: false,
                        topContentInset: 40,
                        // 🔴 onAppear/onDisappear は判定が厳しすぎた。少し動かしただけで
                        //    メーターがリセットされる (2026-08-29 実機報告)。
                        //    「50%見えていれば見ているとみなす」に変える
                        onItemVisibilityChanged: { item, isVisible in
                            setVisible("post-\(item.id)", isVisible)
                        }
                    )
                    .onScrollPhaseChange { _, phase in
                        if phase != .idle { handleScroll() }
                    }
                } else {
                    imagePager
                }

                // 🔴 上のヘッダーは廃止 (2026-08-29 ユーザー指示)。
                //    メーターは下の解除ボタン自体に統合した = 部品が1つ減る
                VStack(spacing: 0) {
                    Spacer()
                    if !pages.isEmpty {
                        bottomControls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                }
            }
            // ヘッダーの黒い背景を出さない (マイページと同じ見た目に揃える)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onDisappear { stopMeasuring() }
    }

    // MARK: - 画像ページャ

    /// 🔴 1枚ずつ吸い付く縦ページ (YouTube Shorts 風) はやめた。
    ///    フィードと同じ**自由にスクロールできるカード列**にする (2026-08-29 ユーザー指示)。
    ///    止まる位置を作らず、比率も投稿と同じ 4:5 に揃える
    private var imagePager: some View {
        ScrollView {
            LazyVStack(spacing: 28) {
                ForEach(pages) { page in
                    pageView(page)
                        .id(page.id)
                        // 50%見えていれば「見ている」とみなす (投稿モードと同じ基準)
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            setVisible(page.id, isVisible)
                        }
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { handleScroll() }
        }
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .post(let item):
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay { FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20)
        case .image(_, let image):
            // 投稿カードと同じ 4:5 の枠。はみ出す比率は同じ画像のぼかしで埋める
            // (FeedFitBlurImage と同じ方式。本体は絶対にクロップしない)
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .blur(radius: 18)
                                .opacity(0.55)
                                .drawingGroup()
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20)
        }
    }

    // MARK: - 滞在時間の計測
    //
    // 🔴 「取り消して再開始」方式は壊れやすかった (2026-08-29 実機で多発)。
    //    見えているページの集合を持ち、そこから計測対象を選び直す方式にする。
    //    離れたら毎回0から数え直す (2026-08-29 ユーザー指示で累積は廃止)。

    private func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible { visibleIds.insert(id) } else { visibleIds.remove(id) }
        syncCurrent()
    }

    /// 見えているページの中から「まだ見終わっていない最初のもの」を計測対象にする
    private func syncCurrent() {
        // 🔴 必要数に達したらもう数えない。数え続けると「ロックを解除する」と出ている
        //    緑のボタンの裏でメーターが満ちていく矛盾した見た目になる
        guard !canUnlock else {
            stopMeasuring()
            currentId = nil
            return
        }
        // 1件たまった直後は、指が動くまで次を数え始めない
        guard !awaitingScroll else { return }
        let next = pages.first { visibleIds.contains($0.id) && !seen.contains($0.id) }?.id
        guard next != currentId else { return }

        stopMeasuring()
        currentId = next
        guard let next else {
            meterProgress = 0
            return
        }
        startMeasuring(next)
    }

    private func startMeasuring(_ id: String) {
        // 🔴 途中まで見た分は引き継がない。離れたら毎回0から (2026-08-29 ユーザー指示)
        meterProgress = 0

        // 🔴 状態更新は1回だけ。間の描画は Core Animation に任せる (カクつき対策)
        withAnimation(.linear(duration: Self.dwellSeconds)) { meterProgress = 1 }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, currentId == id else { return }
            seen.insert(id)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            // 次を数える前に必ずスクロールさせる
            awaitingScroll = true
            currentId = nil
            // 満タンから0へ瞬間的に戻ると進捗が消えたように見えるので、少しだけ見せてから畳む
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { meterProgress = 0 }
        }
    }

    private func stopMeasuring() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// 指が動いたら次の計測を解禁する
    private func handleScroll() {
        guard awaitingScroll else { return }
        awaitingScroll = false
        syncCurrent()
    }

    // MARK: - 下部の常駐コントロール

    private var bottomControls: some View {
        VStack(spacing: 10) {
            keepWorkingButton

            unlockButton
        }
    }

    /// 🔴 これが本体。常に押せる状態で置いておく。
    ///    iOS 26 ならネイティブの Liquid Glass ボタン (下限が 18.6 なので分岐が要る)
    @ViewBuilder
    private var keepWorkingButton: some View {
        // ⚠️ 文言はユーザー添削待ち
        let label = Text(ja ? "やっぱり作業を続ける" : "Actually, keep working")
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)

        // 🔴 ガラスにしたら文字が背景と同化して読めなくなった (2026-08-29 実機報告)。
        //    ここは一番押してほしいボタンなので、読みやすさを優先して塗りに戻す
        Button(action: onKeepWorking) {
            label
                .foregroundColor(.black)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    /// 🔴 解除ボタン自体がメーターを兼ねる (2026-08-29 ユーザー案)。
    ///    見ている間はボタンの中が満ちていき、満ちると残り件数が1つ減る。
    ///    別途メーターを置かなくて済むので画面の部品が1つ減る
    private var unlockButton: some View {
        Button(action: onCompleted) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 溜まりは薄水緑。全部たまったら通常の緑 (2026-08-29 ユーザー指定)
                    Rectangle()
                        .fill(canUnlock ? AppColors.success.opacity(0.85) : Self.fillingGreen)
                        .frame(width: canUnlock ? geo.size.width : geo.size.width * meterProgress)

                    Text(unlockLabel)
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        // 薄い塗りの上でも読めるように影を敷く
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: 48)
            .background(glassBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(canUnlock ? 0.4 : 0.15), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canUnlock)
        .animation(.easeOut(duration: 0.25), value: canUnlock)
    }

    // ⚠️ 文言はユーザー添削待ち
    private var unlockLabel: String {
        if canUnlock { return ja ? "ロックを解除する" : "Unlock" }
        let left = required - progress
        if isPostMode {
            return ja ? "残り \(left) 件 ライバルの進捗を見る" : "See \(left) more from your rivals"
        }
        return ja ? "残り \(left) 件 自分の画像を見る" : "See \(left) more of your images"
    }

    /// 溜まっている途中の色 (薄水緑)
    private static let fillingGreen = Color(red: 0.55, green: 0.90, blue: 0.78).opacity(0.45)

    /// 🔴 ガラスは透過しすぎると文字が読めない (2026-08-29 実機報告)。
    ///    暗い下地を敷いた上に載せてコントラストを確保する。
    ///    ⚠️ タブバーや戻るボタンのような「背後が屈折して映り込み、長押しで伸びる」
    ///    挙動はシステム部品専用で、公開APIでは再現できない
    @ViewBuilder
    private var glassBackground: some View {
        ZStack {
            Capsule().fill(Color.black.opacity(0.45))
            if #available(iOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 空

    /// 🔴 見せるものが無い時に詰ませない。解除だけはできるようにする
    private var emptyState: some View {
        VStack(spacing: 16) {
            Text(ja ? "見せるものがありません" : "Nothing to show") // 文言はユーザー添削待ち
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Button(action: onCompleted) {
                Text(ja ? "ロックを解除する" : "Unlock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
        }
    }
}
