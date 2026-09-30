//
//  PostBakeRenderer.swift
//  AppBlocker
//
//  Baking process called when "次へ" ("Next") is tapped in StoryTextEditorView.
//  Rebuilds the same composition as the edit canvas (device-dependent size) at a fixed size of
//  width=1080, and composites it into one JPEG with ImageRenderer. Follows the ImageRenderer usage
//  pattern (scale=1, fixed frame) in ImageExportService.swift.
//

import SwiftUI
import UIKit

@MainActor
enum PostBakeRenderer {

    /// Base width of the baking resolution (same order as Instagram Story etc.)
    static let renderWidth: CGFloat = 1080

    /// Runs the bake and returns (JPEG Data, UIImage for preview).
    /// canvasSize is the GeometryReader size of the editor screen (the basis of the normalized
    /// coordinates).
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
        // BakeCompositionView itself is framed to renderSize, so scale=1 gives exactly the intended
        // resolution
        renderer.scale = 1.0
        renderer.isOpaque = true

        guard let uiImage = renderer.uiImage,
              let jpeg = uiImage.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        return (jpeg, uiImage)
    }
}

/// Composite View passed to ImageRenderer. It does not use scaleEffect; it expands the normalized
/// fontSize to real pt from renderSize.width and draws directly (prevents blurry baking).
private struct BakeCompositionView: View {
    let background: PostBackground
    let overlays: [EditableOverlay]
    let canvasSize: CGSize
    let renderSize: CGSize

    var body: some View {
        ZStack {
            backgroundLayer

            ForEach(overlays) { overlay in
                // k = renderSize.width / canvasSize.width. Unless the plate padding/corner radius/shadow are scaled
                // by the same factor as fontSize, the bake comes out with a more cramped plate / weaker shadow
                // than the proportions seen in the editor (fixed 2026-07-11)
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
            // Fill the 4:5 canvas (aspectFill + crop). Bakes with the same look as the editor.
            // canvasSize is 4:5, so renderSize is also 4:5 (1080×1350), and camera photos bake with no margins
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
