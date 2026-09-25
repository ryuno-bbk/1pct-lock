//
//  PostBakeRenderer.swift
//  AppBlocker
//
//  StoryTextEditorView の「次へ」タップ時に呼ばれる焼き込み処理。
//  編集キャンバス (端末依存サイズ) と同じ構図を width=1080 の固定サイズで再構成し、
//  ImageRenderer で 1 枚の JPEG に合成する。ImageExportService.swift の
//  ImageRenderer 利用パターン (scale=1, フレーム固定) に倣う。
//

import SwiftUI
import UIKit

@MainActor
enum PostBakeRenderer {

    /// 焼き込み解像度の基準幅 (Instagram Story 等と同じオーダー)
    static let renderWidth: CGFloat = 1080

    /// 焼き込みを実行し、(JPEG Data, プレビュー用 UIImage) を返す。
    /// canvasSize はエディタ画面の GeometryReader サイズ (正規化座標の基準)。
    static func bake(
        background: PostBackground,
        overlays: [EditableOverlay],
        canvasSize: CGSize
    ) -> (Data, UIImage)? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let renderHeight = renderWidth * (canvasSize.height / canvasSize.width)
        let renderSize = CGSize(width: renderWidth, height: renderHeight)

        let content = BakeCompositionView(
            background: background,
            overlays: overlays,
            canvasSize: canvasSize,
            renderSize: renderSize
        )
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        // BakeCompositionView 自体が renderSize に .frame されているので scale=1 でちょうど狙った解像度になる
        renderer.scale = 1.0
        renderer.isOpaque = true

        guard let uiImage = renderer.uiImage,
              let jpeg = uiImage.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        return (jpeg, uiImage)
    }
}

/// ImageRenderer に渡す合成 View。scaleEffect は使わず、正規化 fontSize を
/// renderSize.width から実 pt へ展開して直接描画する (焼き込みボケ防止)。
private struct BakeCompositionView: View {
    let background: PostBackground
    let overlays: [EditableOverlay]
    let canvasSize: CGSize
    let renderSize: CGSize

    var body: some View {
        ZStack {
            backgroundLayer

            ForEach(overlays) { overlay in
                // k = renderSize.width / canvasSize.width。fontSize と同じ倍率で
                // プレート余白/角丸/シャドウも拡大しないと、エディタで見た比率より
                // ぎゅっと詰まったプレート/弱いシャドウで焼き込まれる (2026-07-11 修正)
                let k = canvasSize.width > 0 ? renderSize.width / canvasSize.width : 1
                let fontPt = canvasSize.width > 0
                    ? CGFloat(overlay.fontSize / Double(canvasSize.width)) * renderSize.width
                    : 24
                OverlayGlyphView(overlay: overlay, resolvedFontSize: fontPt, scale: k)
                    .rotationEffect(.degrees(overlay.rotationDegrees))
                    .position(
                        x: CGFloat(overlay.x) * renderSize.width,
                        y: CGFloat(overlay.y) * renderSize.height
                    )
            }
        }
        .frame(width: renderSize.width, height: renderSize.height)
        .clipped()
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        switch background {
        case .photo(let image):
            // 4:5 キャンバスをフィル (aspectFill + クロップ)。エディタと同じ見た目で焼き込む。
            // canvasSize が 4:5 のため renderSize も 4:5 (1080×1350) になり、カメラ写真は余白なく焼ける
            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .frame(width: renderSize.width, height: renderSize.height)
            .clipped()
        case .template(let idx):
            QuoteBackgroundView(quoteId: postFlowTemplateSeedID, backgroundIndex: idx)
                .frame(width: renderSize.width, height: renderSize.height)
        case .black:
            Color.black
        case .white:
            AppColors.textPrimary
        }
    }
}
