//
//  StoryTextEditorView.swift
//  AppBlocker
//
//  UGC post v2 Step2: text overlay editor modeled on IG Stories.
//  Up to 3 texts can be placed freely on the background (photo/template/black/white) with
//  drag/pinch/rotate. Supports center snap, rotation snap and delete by dropping on the trash can.
//  Tapping "次へ" ("Next") asks PostBakeRenderer to bake the image, then goes to Step3
//  (PostConfirmView).
//
//  Performance note: the TextField in this file is localized to a small child view called
//  OverlayTextFieldPreview (follows the rule that bans scaleEffect on a huge view and a TextField
//  directly under it). scaleEffect is limited to live feedback during a pinch; the bake draws with
//  the real fontSize.
//

import SwiftUI
import UIKit

struct StoryTextEditorView: View {
    @ObservedObject var draft: PostDraft
    /// Callback to push to Step3 after baking finishes
    let onNext: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var canvasSize: CGSize = .zero

    // Input mode state
    @State private var isEditingOverlay = false
    @State private var editingOverlayId: UUID?
    @State private var editingText: String = ""
    @State private var editingFont: OverlayFont = .serif
    @State private var editingColor: OverlayColor = .offwhite
    @State private var editingPlate: Bool = false
    @State private var editingPlateColor: OverlayColor? = nil
    @State private var editingAlignment: OverlayAlignment = .center
    @State private var editingFontSize: Double = 32

    // Visual feedback during placement mode
    @State private var isAnyOverlayDragging = false
    @State private var isAnyOverlayNearTrash = false
    @State private var showSnapGuideX = false
    @State private var showSnapGuideY = false

    @State private var isBaking = false

    // Snapshot for canceling with Back. If the user leaves without pressing Next (bake), restore the
    // state at entry. This prevents only overlays being rewritten and no longer matching the existing
    // baked image.
    @State private var overlaysSnapshot: [EditableOverlay] = []
    @State private var didBake = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// Number of overlays in draft.images[draft.editingIndex] (0 if out of bounds)
    private var currentOverlayCount: Int {
        guard draft.images.indices.contains(draft.editingIndex) else { return 0 }
        return draft.images[draft.editingIndex].overlays.count
    }

    var body: some View {
        GeometryReader { geo in
            // The editing canvas is fixed at 4:5 (screen width × 1.25). This becomes the bake ratio.
            // It is the same 4:5 as feed/comments/profile, so camera photos are baked with fill and zero margin.
            let canvasW = geo.size.width
            let canvasH = canvasW * 5.0 / 4.0
            let cSize = CGSize(width: canvasW, height: canvasH)

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // 4:5 editing canvas. Top edge = right below the top bar of input mode (clock/trash/done).
                // 8pt was too high, and centering gives an ugly black band (2026-07-11 real device feedback ×2).
                // The eyedropper canvasRect of the input overlay also uses the same 56pt
                // Note: attach overlay (Aa/clock) before padding. After padding, it aligns to the top right of
                // "the frame including the margin" and Aa sticks out of the image (already happened on a real device)
                editingCanvas(size: cSize)
                    .frame(width: canvasW, height: canvasH)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .topTrailing) {
                        if !isEditingOverlay {
                            VStack(spacing: 10) {
                                Button {
                                    beginNewOverlay()
                                } label: {
                                    Text("Aa")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 40, height: 40)
                                        .background(Circle().fill(Color.black.opacity(0.35)))
                                }

                                // One-tap insert of the current time (2026-07-11 user request: always shown so it can be pressed
                                // without opening input mode)
                                Button {
                                    insertTimeOverlay()
                                } label: {
                                    Image(systemName: "clock")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 40, height: 40)
                                        .background(Circle().fill(Color.black.opacity(0.35)))
                                }
                            }
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                            .disabled(currentOverlayCount >= 3)
                            .opacity(currentOverlayCount >= 3 ? 0.35 : 1)
                        }
                    }
                    .padding(.top, 56)

                // Text input mode is full screen (outside the canvas)
                if isEditingOverlay {
                    OverlayInputOverlay(
                        text: $editingText,
                        font: $editingFont,
                        color: $editingColor,
                        plate: $editingPlate,
                        plateColor: $editingPlateColor,
                        alignment: $editingAlignment,
                        fontSize: $editingFontSize,
                        background: currentBackground,
                        lang: lang,
                        onDone: { commitEditing() },
                        onDelete: { deleteEditingOverlay() }
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                canvasSize = cSize
                didBake = false  // One edit session per appearance (including coming back from the confirm screen)
                if draft.images.indices.contains(draft.editingIndex) {
                    overlaysSnapshot = draft.images[draft.editingIndex].overlays
                }
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = CGSize(width: newSize.width, height: newSize.width * 5.0 / 4.0)
            }
        }
        // Do not shrink the canvas for the keyboard. If it shrinks, pressing "次へ" ("Next") right after
        // typing bakes with the shrunk ratio and produces a broken post (already happened on a real device)
        .ignoresSafeArea(.keyboard)
        .onDisappear {
            // Leaving without baking = cancel. Restore the edits to the state at entry
            if !didBake, draft.images.indices.contains(draft.editingIndex) {
                draft.images[draft.editingIndex].overlays = overlaysSnapshot
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isBaking {
                    ProgressView().tint(.white)
                } else {
                    Button(PostFlowStrings.step2Next(lang)) {
                        Task { await proceedNext() }
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    // Disabled because pressing it in input mode drops the unconfirmed text without baking it
                    // (confirm first with "完了" ("Done") or by tapping the dimmed area)
                    .disabled(isEditingOverlay)
                    .opacity(isEditingOverlay ? 0.4 : 1)
                }
            }
        }
    }

    // MARK: - Editing Canvas (4:5)

    /// Contents of the 4:5 canvas (background + overlays + snap guides + hint + trash).
    /// canvasSize is the real 4:5 size. Overlay coordinates are also normalized against this 4:5 basis.
    @ViewBuilder
    private func editingCanvas(size: CGSize) -> some View {
        ZStack {
            backgroundLayer(size: size)
                .contentShape(Rectangle())
                .onTapGesture { beginNewOverlay() }

            if draft.images.indices.contains(draft.editingIndex) {
                ForEach($draft.images[draft.editingIndex].overlays) { $overlay in
                    let isBeingEdited = isEditingOverlay && overlay.id == editingOverlayId
                    PlacedOverlayView(
                        overlay: $overlay,
                        canvasSize: size,
                        onTap: { beginEditingExisting(overlay) },
                        onDelete: {
                            draft.images[draft.editingIndex].overlays.removeAll { $0.id == overlay.id }
                        },
                        onDragSignal: { signal in
                            isAnyOverlayDragging = signal.isDragging
                            isAnyOverlayNearTrash = signal.isNearTrash
                            showSnapGuideX = signal.snappedX
                            showSnapGuideY = signal.snappedY
                        }
                    )
                    .opacity(isBeingEdited ? 0 : 1)
                }
            }

            if showSnapGuideX {
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
            if showSnapGuideY {
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }

            if currentOverlayCount == 0 && !isEditingOverlay {
                Text(PostFlowStrings.step2Hint(lang))
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }

            if isAnyOverlayDragging {
                trashButton
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Background

    /// Background of the DraftImage being edited (falls back to black if out of bounds)
    private var currentBackground: PostBackground {
        guard draft.images.indices.contains(draft.editingIndex) else { return .black }
        return draft.images[draft.editingIndex].background
    }

    // Real device feedback #8 root cause fix: .scaledToFill() pushes its own layout size beyond the
    // proposed size (UserPostGridCell in ProfileCards.swift has a comment with the same lesson.
    // The FeedListCard.imageFitBlur comment also records it as a known bug: "the fill layer pushes the
    // ZStack wider"). Without frame/clipped, this ZStack (background) becomes larger than
    // editingCanvas's cSize, and when the outer .frame(canvasW,canvasH).clipped() crops it centered,
    // the coordinate origin of the ZStack itself shifts away from the visible canvas.
    // PlacedOverlayView is placed directly in "the ZStack's coordinate system" with
    // .position(overlay.x*canvasSize.width, ...), so that shift led directly to "placed in the center
    // but it looks off" (the bake side's BakeCompositionView.backgroundLayer already had this
    // frame+clipped, so the baked result was correct).
    // Take size explicitly and always fix it to exactly cSize to remove the coordinate shift.
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        switch currentBackground {
        case .photo(let image):
            // Fill the 4:5 canvas (aspectFill + crop). Camera photos fill it with no margin, and only images
            // with extreme ratios lose a little at the top/bottom or left/right (user decision: zero margin first)
            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        case .template(let idx):
            QuoteBackgroundView(quoteId: postFlowTemplateSeedID, backgroundIndex: idx)
                .frame(width: size.width, height: size.height)
        case .black:
            Color.black
        case .white:
            AppColors.textPrimary
        }
    }

    // MARK: - Trash

    private var trashButton: some View {
        Image(systemName: "trash.circle.fill")
            .font(.system(size: 34))
            .foregroundColor(.white)
            .scaleEffect(isAnyOverlayNearTrash ? 1.2 : 1.0)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .animation(.easeOut(duration: 0.15), value: isAnyOverlayNearTrash)
    }

    // MARK: - Input mode

    private var defaultOverlayColor: OverlayColor {
        if case .white = currentBackground { return .ink }
        return .offwhite
    }

    private func beginNewOverlay() {
        guard currentOverlayCount < 3 else { return }
        editingOverlayId = nil
        editingText = ""
        editingFont = .serif
        editingColor = defaultOverlayColor
        editingPlate = false
        editingPlateColor = nil
        editingAlignment = .center
        editingFontSize = 32
        withAnimation(.easeOut(duration: 0.18)) { isEditingOverlay = true }
    }

    /// Place the current time with one tap (no input mode needed).
    /// On a white background it becomes ink (defaultOverlayColor), which also fixes the
    /// "time is invisible" problem
    private func insertTimeOverlay() {
        guard draft.images.indices.contains(draft.editingIndex),
              currentOverlayCount < 3 else { return }
        let new = EditableOverlay(
            id: UUID(),
            text: OverlayFontProvider.currentTimeString(),
            font: .serif,   // The initial font is the leftmost one (Mincho). Same for the time (2026-07-11 user request)
            color: defaultOverlayColor,
            plate: false,
            x: 0.5,
            y: 0.3,   // Place it a bit higher, since the center tends to overlap the body text
            fontSize: 44,
            rotationDegrees: 0,
            alignment: .center
        )
        draft.images[draft.editingIndex].overlays.append(new)
        QuizHaptics.light()
    }

    private func beginEditingExisting(_ overlay: EditableOverlay) {
        editingOverlayId = overlay.id
        editingText = overlay.text
        editingFont = overlay.font
        editingColor = overlay.color
        editingPlate = overlay.plate
        editingPlateColor = overlay.plateColor
        editingAlignment = overlay.alignment
        editingFontSize = overlay.fontSize
        withAnimation(.easeOut(duration: 0.18)) { isEditingOverlay = true }
    }

    /// Trash in input mode: deletes the text being edited and closes (only discards if it is new)
    private func deleteEditingOverlay() {
        if let id = editingOverlayId, draft.images.indices.contains(draft.editingIndex) {
            draft.images[draft.editingIndex].overlays.removeAll { $0.id == id }
        }
        editingText = ""
        QuizHaptics.light()
        withAnimation(.easeOut(duration: 0.18)) { isEditingOverlay = false }
    }

    private func commitEditing() {
        defer { withAnimation(.easeOut(duration: 0.18)) { isEditingOverlay = false } }
        guard draft.images.indices.contains(draft.editingIndex) else { return }

        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if let id = editingOverlayId {
                draft.images[draft.editingIndex].overlays.removeAll { $0.id == id }
            }
            return
        }

        let limited = String(trimmed.prefix(120))

        if let id = editingOverlayId, let idx = draft.images[draft.editingIndex].overlays.firstIndex(where: { $0.id == id }) {
            draft.images[draft.editingIndex].overlays[idx].text = limited
            draft.images[draft.editingIndex].overlays[idx].font = editingFont
            draft.images[draft.editingIndex].overlays[idx].color = editingColor
            draft.images[draft.editingIndex].overlays[idx].plate = editingPlate
            draft.images[draft.editingIndex].overlays[idx].plateColor = editingPlateColor
            draft.images[draft.editingIndex].overlays[idx].alignment = editingAlignment
            draft.images[draft.editingIndex].overlays[idx].fontSize = editingFontSize
            // Keep x / y / rotationDegrees (do not move the position when re-editing)
        } else {
            guard currentOverlayCount < 3 else { return }
            let new = EditableOverlay(
                id: UUID(),
                text: limited,
                font: editingFont,
                color: editingColor,
                plate: editingPlate,
                plateColor: editingPlateColor,
                x: 0.5,
                y: 0.5,
                fontSize: editingFontSize,
                rotationDegrees: 0,
                alignment: editingAlignment
            )
            draft.images[draft.editingIndex].overlays.append(new)
        }
    }

    // MARK: - Next (bake: one DraftImage being edited)

    @MainActor
    private func proceedNext() async {
        guard draft.images.indices.contains(draft.editingIndex),
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let idx = draft.editingIndex
        let background = draft.images[idx].background
        let overlays = draft.images[idx].overlays

        isBaking = true
        defer { isBaking = false }

        guard let (jpeg, preview) = await PostBakeRenderer.bake(
            background: background,
            overlays: overlays,
            canvasSize: canvasSize
        ) else {
            print("⚠️ StoryTextEditorView: bake failed")
            return
        }

        draft.images[idx].bakedImageData = jpeg
        draft.images[idx].bakedPreviewImage = preview
        draft.images[idx].overlayDTOs = overlays.map { $0.toDTO(canvasWidth: canvasSize.width) }
        didBake = true
        onNext()
    }
}

// MARK: - OverlayGlyphView (shared drawing part, also used by PostBakeRenderer)

/// Appearance of one text overlay (font + color + plate + shadow).
/// Called from both the live editor and the bake renderer.
struct OverlayGlyphView: View {
    let overlay: EditableOverlay
    /// The pt value actually drawn (computed by the caller from the normalized fontSize)
    let resolvedFontSize: CGFloat
    /// Multiplier for plate padding / corner radius / shadow radius. The editor display uses 1 (actual
    /// size), and the bake (BakeCompositionView) passes the same k as fontSize (renderWidth/canvasWidth).
    /// If these do not match, only the plate/shadow is baked stronger than in the editor (found 2026-07-11)
    var scale: CGFloat = 1

    private var font: Font {
        OverlayFontProvider.font(overlay.font, size: resolvedFontSize)
    }

    var body: some View {
        // Text color = color, plate background = plateColor (auto contrast if not set).
        // "Text/background" can be chosen independently (split after the 2026-07-11 intuitiveness feedback).
        // No wrapping at all (IG style): line breaks are manual only.
        // If made large, it goes past the canvas edge and can be cut off on purpose (cropped in the bake)
        Text(overlay.text.isEmpty ? " " : overlay.text)
            .font(font)
            .foregroundColor(overlay.color.swiftUIColor)
            .multilineTextAlignment(overlay.alignment.textAlignment)
            .fixedSize()
            .padding(.horizontal, overlay.plate ? 10 * scale : 0)
            .padding(.vertical, overlay.plate ? 6 * scale : 0)
            .background(
                Group {
                    if overlay.plate {
                        RoundedRectangle(cornerRadius: 10 * scale)
                            .fill(overlay.resolvedPlateColor.swiftUIColor)
                    }
                }
            )
            // The shadow is for readability. For huge text over 120pt, rasterizing the shadow is extremely heavy
            // and causes freezes, so it is disabled (2026-07-11).
            // This 120 check uses overlay.fontSize (pt in the editor coordinate system, before normalization)
            // and not resolvedFontSize (already multiplied by k during the bake), so that
            // the preview and the bake do not disagree on whether the shadow is on or off
            .shadow(
                color: (overlay.plate || overlay.fontSize > 120) ? .clear : .black.opacity(0.35),
                radius: (overlay.plate || overlay.fontSize > 120) ? 0 : 8 * scale
            )
    }
}

// MARK: - PlacedOverlayView (placement mode: drag/pinch/rotate + snap + delete by trash)

private struct OverlayDragSignal {
    var isDragging: Bool
    var isNearTrash: Bool
    var snappedX: Bool
    var snappedY: Bool
}

private struct PlacedOverlayView: View {
    @Binding var overlay: EditableOverlay
    let canvasSize: CGSize
    let onTap: () -> Void
    let onDelete: () -> Void
    let onDragSignal: (OverlayDragSignal) -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1.0
    @GestureState private var rotateDelta: Angle = .zero

    @State private var isNearTrashLocal = false
    @State private var snappedXLocal = false
    @State private var snappedYLocal = false

    // The hit area is only about the distance that overlaps the icon (the old 50 was too wide, and text
    // could not be placed at the bottom of the screen. 2026-07-11 real device feedback)
    private let trashRadius: CGFloat = 32
    private let centerSnapThreshold: CGFloat = 8
    private let rotationSnapThreshold: Double = 4

    private var basePoint: CGPoint {
        CGPoint(x: overlay.x * canvasSize.width, y: overlay.y * canvasSize.height)
    }

    private var trashCenter: CGPoint {
        // Match the drawing side (trashButton: bottom padding 40 + half of the 34pt icon ≈ 17).
        // If they differ, "where the trash looks" and "the actual delete hit area" disagree
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 57)
    }

    /// Offset for live display (includes light magnetic snapping to the center)
    private var liveOffset: CGSize {
        guard dragTranslation != .zero else { return .zero }
        var dx = dragTranslation.width
        var dy = dragTranslation.height
        let liveX = basePoint.x + dx
        let liveY = basePoint.y + dy
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2
        if abs(liveX - centerX) < centerSnapThreshold {
            dx += centerX - liveX
        }
        if abs(liveY - centerY) < centerSnapThreshold {
            dy += centerY - liveY
        }
        return CGSize(width: dx, height: dy)
    }

    /// Scale for the live pinch display. Pinch is almost unlimited (4-300pt). The left slider stays at
    /// 16-64.
    /// Upper limit 300: text with a shadow over several hundred pt is heavy to rasterize, and the
    /// main thread freezes on every state change (real device freeze 2026-07-11). Even 300 easily exceeds
    /// the screen width.
    /// Apply the clamp in advance to prevent the jump where it "shrinks/grows the moment the finger is
    /// lifted"
    private var clampedMagnify: CGFloat {
        guard overlay.fontSize > 0 else { return magnifyDelta }
        let minScale = 4.0 / overlay.fontSize
        let maxScale = 300.0 / overlay.fontSize
        return min(max(magnifyDelta, minScale), maxScale)
    }

    var body: some View {
        OverlayGlyphView(overlay: overlay, resolvedFontSize: overlay.fontSize)
            .rotationEffect(Angle(degrees: overlay.rotationDegrees) + rotateDelta)
            .scaleEffect(isNearTrashLocal ? 0.6 : clampedMagnify)
            .opacity(isNearTrashLocal ? 0.5 : 1)
            .position(basePoint)
            .offset(liveOffset)
            .onTapGesture {
                if dragTranslation == .zero { onTap() }
            }
            .gesture(combinedGesture)
    }

    private var combinedGesture: some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
                evaluateSignals(translation: value.translation)
            }
            .onEnded { value in
                applyDragEnd(value.translation)
            }

        let magnify = MagnificationGesture()
            .updating($magnifyDelta) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newSize = (overlay.fontSize * value).rounded()
                overlay.fontSize = min(max(newSize, 4), 300)
            }

        let rotate = RotationGesture()
            .updating($rotateDelta) { value, state, _ in
                state = value
            }
            .onEnded { value in
                applyRotationEnd(value)
            }

        return drag.simultaneously(with: magnify).simultaneously(with: rotate)
    }

    private func evaluateSignals(translation: CGSize) {
        let liveX = basePoint.x + translation.width
        let liveY = basePoint.y + translation.height
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2

        let nowSnapX = abs(liveX - centerX) < centerSnapThreshold
        let nowSnapY = abs(liveY - centerY) < centerSnapThreshold
        if nowSnapX != snappedXLocal {
            snappedXLocal = nowSnapX
            if nowSnapX { hapticLight() }
        }
        if nowSnapY != snappedYLocal {
            snappedYLocal = nowSnapY
            if nowSnapY { hapticLight() }
        }

        let distance = hypot(liveX - trashCenter.x, liveY - trashCenter.y)
        let nowNearTrash = distance < trashRadius
        if nowNearTrash != isNearTrashLocal {
            isNearTrashLocal = nowNearTrash
            hapticLight()
        }

        onDragSignal(OverlayDragSignal(isDragging: true, isNearTrash: isNearTrashLocal, snappedX: snappedXLocal, snappedY: snappedYLocal))
    }

    private func applyDragEnd(_ translation: CGSize) {
        let wasNearTrash = isNearTrashLocal
        snappedXLocal = false
        snappedYLocal = false
        isNearTrashLocal = false
        onDragSignal(OverlayDragSignal(isDragging: false, isNearTrash: false, snappedX: false, snappedY: false))

        if wasNearTrash {
            onDelete()
            return
        }

        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        var finalTranslation = translation
        let liveX = basePoint.x + translation.width
        let liveY = basePoint.y + translation.height
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2
        if abs(liveX - centerX) < centerSnapThreshold {
            finalTranslation.width += centerX - liveX
        }
        if abs(liveY - centerY) < centerSnapThreshold {
            finalTranslation.height += centerY - liveY
        }

        overlay.x += finalTranslation.width / canvasSize.width
        overlay.y += finalTranslation.height / canvasSize.height
        overlay.x = min(max(overlay.x, 0), 1)
        overlay.y = min(max(overlay.y, 0), 1)
    }

    private func applyRotationEnd(_ angle: Angle) {
        let newDegrees = overlay.rotationDegrees + angle.degrees
        var normalized = newDegrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }

        let snapTargets: [Double] = [0, 90, 180, 270, 360]
        if let nearest = snapTargets.first(where: { abs(normalized - $0) <= rotationSnapThreshold }) {
            normalized = nearest >= 360 ? 0 : nearest
            hapticLight()
        }
        overlay.rotationDegrees = normalized
    }

    private func hapticLight() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - OverlayInputOverlay (input mode: IG-style 4-button toolbar + horizontal scroll row)
//
// Layout (confirmed by the user 2026-07-11, follows the IG text editor):
//   - Top: insert time / trash / done
//   - Center: text + vertical size slider on the left
//   - Bottom: active row (font pills or color swatches, both scroll horizontally)
//           + 4-button bar [Aa font] [color wheel] [alignment] [A plate]
//   - Eyedropper: left end of the color row. Dragging moves the loupe and picks a color from the
//     background image

private struct OverlayInputOverlay: View {
    @Binding var text: String
    @Binding var font: OverlayFont
    @Binding var color: OverlayColor
    @Binding var plate: Bool
    /// Plate background color (nil = auto contrast from the text color)
    @Binding var plateColor: OverlayColor?
    @Binding var alignment: OverlayAlignment
    @Binding var fontSize: Double
    /// Sampling source for the eyedropper (the background being edited)
    let background: PostBackground
    let lang: AppLanguage
    let onDone: () -> Void
    /// Delete the text being edited and close (trash in topBar)
    let onDelete: () -> Void

    private enum ActiveTool {
        case font
        case color
    }

    @State private var activeTool: ActiveTool = .font
    /// Slide selection position of the font row (the pill that comes to the center = selected)
    @State private var fontScrollID: OverlayFont?

    // Eyedropper
    @State private var isEyedropperActive = false
    @State private var dropperPoint: CGPoint = .zero
    @State private var dropperColor: OverlayColor = .offwhite
    @State private var sampler: EyedropperSampler?

    var body: some View {
        GeometryReader { geo in
            // Layout reference (fixed fractions that do not depend on the keyboard)
            let textCenterY = geo.size.height * 0.29
            let toolsCenterY = geo.size.height * 0.50
            // Actual area of the 4:5 canvas (the eyedropper's movable range). Match the editor's top alignment
            // (top 56pt)
            let canvasHeight = geo.size.width * 5.0 / 4.0
            let canvasRect = CGRect(
                x: 0,
                y: 56,
                width: geo.size.width,
                height: canvasHeight
            )

            ZStack {
                // Dimming layer. Tap to confirm (onDone)
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDone() }

                if !isEyedropperActive {
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                    }

                    OverlayTextFieldPreview(
                        text: $text,
                        font: font,
                        color: color,
                        plate: plate,
                        plateColor: plateColor,
                        alignment: alignment,
                        fontSize: fontSize
                    )
                    // SwiftUI's TextField has a known quirk: color/font changes while focused are not shown until the
                    // next key press. When the style changes, change the id to rebuild the field
                    // so it applies immediately (it is refocused in onAppear. 2026-07-11 real device feedback)
                    .id("preview-\(color.token)-\(plate)-\(plateColor?.token ?? "auto")-\(font.rawValue)-\(alignment.rawValue)")
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { /* a tap inside the band does not close it */ }
                    .position(x: geo.size.width / 2, y: textCenterY)

                    // Bottom: active row + 4-button bar
                    VStack(spacing: 12) {
                        Group {
                            switch activeTool {
                            case .font:  fontScrollRow(width: geo.size.width)
                            case .color: colorScrollRow
                            }
                        }
                        .frame(height: 42)

                        toolBar
                    }
                    .position(x: geo.size.width / 2, y: toolsCenterY)

                    // The slider is kept short (so its bottom end does not overlap the eyedropper in the color row.
                    // 2026-07-11 feedback)
                    VerticalSizeSlider(value: $fontSize)
                        .frame(width: 32, height: geo.size.height * 0.22)
                        .position(x: 32, y: textCenterY)
                } else {
                    eyedropperLayer(canvasRect: canvasRect)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            fontScrollID = font
        }
    }

    // MARK: - Top Bar (time / trash / done. All buttons have 44pt hit areas)

    private var topBar: some View {
        HStack(spacing: 8) {
            // Insert the current time (the font stays the current selection = initially the leftmost, Mincho)
            Button {
                text = OverlayFontProvider.currentTimeString()
                QuizHaptics.light()
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            // Delete this text
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Spacer()

            Button {
                onDone()
            } label: {
                Text(PostFlowStrings.step2Done(lang))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    // MARK: - 4-button bar [Aa] [color] [alignment] [plate]

    private var toolBar: some View {
        HStack(spacing: 8) {
            // Aa (go to the font row)
            Button {
                activeTool = .font
            } label: {
                Text("Aa")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(activeTool == .font ? .black : .white)
                    .frame(width: 46, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(activeTool == .font ? Color.white : Color.clear)
                    )
                    .contentShape(Rectangle())
            }

            // Color wheel (go to the swatch row)
            Button {
                activeTool = .color
            } label: {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 46, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(activeTool == .color ? Color.white.opacity(0.25) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }

            // Plate background cycle: OFF → gray → black → white → OFF (2026-07-11 user request.
            // Swatches are always the text color. Simpler than toggles and less likely to be buggy)
            Button {
                cyclePlateBackground()
            } label: {
                Text("A")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(plateButtonForeground)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(plate ? (plateColor ?? .offwhite).swiftUIColor : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(plate ? 0.9 : 0.6), lineWidth: 1.5)
                    )
                    .frame(width: 46, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
    }

    // MARK: - Font row (horizontal scroll + slide to select. IG style)

    private func fontScrollRow(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OverlayFont.pickable, id: \.self) { kind in
                    fontPill(kind)
                        .id(kind)
                }
            }
            .scrollTargetLayout()
        }
        // Center snap: add margins on both sides so the pill that comes to the center is selected
        .contentMargins(.horizontal, (width - 70) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $fontScrollID, anchor: .center)
        .onChange(of: fontScrollID) { _, newValue in
            if let newValue, newValue != font {
                font = newValue
                QuizHaptics.light()
            }
        }
    }

    private func fontPill(_ kind: OverlayFont) -> some View {
        let isSelected = font == kind
        return Button {
            font = kind
            withAnimation(.easeOut(duration: 0.2)) { fontScrollID = kind }
        } label: {
            Text("Aa")
                .font(pillFont(kind))
                .foregroundColor(isSelected ? .black : .white)
                .frame(width: 62, height: 38)
                .background(Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.15)))
        }
    }

    /// Show "Aa" on each pill in its own font (so it can be chosen by look)
    private func pillFont(_ kind: OverlayFont) -> Font {
        // The tweak that made only didot 1pt larger was dropped when font resolution was unified into one
        // entry point (it is a case not shown in the picker, so no real harm)
        OverlayFontProvider.font(kind, size: 15)
    }

    // MARK: - Color row (eyedropper at the left end + fine palette. One horizontally scrolling row)

    private var plateButtonForeground: Color {
        guard plate else { return .white }
        return (plateColor ?? .offwhite).contrastText.swiftUIColor
    }

    /// Plate background cycle: OFF → gray → black → white → OFF
    private func cyclePlateBackground() {
        if !plate {
            plate = true
            plateColor = .plateGray
        } else if plateColor == .plateGray {
            plateColor = .ink
        } else if plateColor == .ink {
            plateColor = .offwhite
        } else {
            plate = false
            plateColor = nil
        }
        QuizHaptics.light()
    }

    private var colorScrollRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                // Eyedropper (picks the text color from the background image)
                Button {
                    startEyedropper()
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                }

                ForEach(Array(OverlayColor.palette.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        color = swatch
                    } label: {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(swatch.swiftUIColor)
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        Color.white.opacity(color == swatch ? 1 : 0.4),
                                        lineWidth: color == swatch ? 2.5 : 1
                                    )
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Eyedropper (drag for a loupe, picks a color from the background image)

    private func startEyedropper() {
        sampler = EyedropperSampler(background: background)
        // Initial position = center of the screen (near the center of the canvas)
        dropperPoint = .zero  // Initialized to the center of canvasRect on the eyedropperLayer side
        isEyedropperActive = true
        QuizHaptics.light()
    }

    private func eyedropperLayer(canvasRect: CGRect) -> some View {
        let point = dropperPoint == .zero
            ? CGPoint(x: canvasRect.midX, y: canvasRect.midY)
            : dropperPoint

        return ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clamped = CGPoint(
                                x: min(max(value.location.x, canvasRect.minX), canvasRect.maxX),
                                y: min(max(value.location.y, canvasRect.minY), canvasRect.maxY)
                            )
                            dropperPoint = clamped
                            let normalized = CGPoint(
                                x: (clamped.x - canvasRect.minX) / canvasRect.width,
                                y: (clamped.y - canvasRect.minY) / canvasRect.height
                            )
                            if let picked = sampler?.uiColor(atNormalized: normalized) {
                                dropperColor = .custom(picked)
                            }
                        }
                        .onEnded { _ in
                            color = dropperColor
                            isEyedropperActive = false
                            QuizHaptics.light()
                        }
                )

            // Loupe (shown above the finger. Teardrop-like, same as the IG eyedropper)
            VStack(spacing: 2) {
                Circle()
                    .fill(dropperColor.swiftUIColor)
                    .frame(width: 56, height: 56)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                Triangle()
                    .fill(Color.white)
                    .frame(width: 14, height: 10)
                    .rotationEffect(.degrees(180))
            }
            .position(x: point.x, y: point.y - 48)
            .allowsHitTesting(false)

            // Small dot at the finger position
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 10, height: 10)
                .position(point)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Cycle Actions

}

/// Triangle pointer for the eyedropper
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - EyedropperSampler (draws the background once into a small bitmap and reads colors from it)

/// Eyedropper sampling. Draws the background (photo/template/solid color) once with aspectFill into a
/// small bitmap with the canvas ratio (4:5), then returns a color in O(1) for each finger move after that
/// (preprocessing so a 12MP image is not decoded every frame)
private struct EyedropperSampler {
    private let width = 96
    private let height = 120
    private var pixels: [UInt8] = []

    init(background: PostBackground) {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            switch background {
            case .black:
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            case .white:
                UIColor(AppColors.textPrimary).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            case .photo(let ui):
                Self.drawFill(ui, in: size)
            case .template(let idx):
                if let ui = BackgroundImageProvider.image(atIndex: idx) {
                    Self.drawFill(ui, in: size)
                } else {
                    UIColor.black.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                }
            }
        }

        guard let cg = image.cgImage else { return }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    func uiColor(atNormalized p: CGPoint) -> UIColor? {
        guard !pixels.isEmpty else { return nil }
        let x = min(max(Int(p.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(p.y * CGFloat(height)), 0), height - 1)
        let i = (y * width + x) * 4
        return UIColor(
            red: CGFloat(pixels[i]) / 255,
            green: CGFloat(pixels[i + 1]) / 255,
            blue: CGFloat(pixels[i + 2]) / 255,
            alpha: 1
        )
    }

    /// Draw with aspectFill (center crop). Picks colors from the same visible range as the editor display
    private static func drawFill(_ image: UIImage, in size: CGSize) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
    }
}

/// Small child view only for showing the text during input mode (localized for performance).
private struct OverlayTextFieldPreview: View {
    @Binding var text: String
    let font: OverlayFont
    let color: OverlayColor
    let plate: Bool
    let plateColor: OverlayColor?
    let alignment: OverlayAlignment
    let fontSize: Double

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .focused($isFocused)
            .multilineTextAlignment(alignment.textAlignment)
            .font(previewFont)
            .foregroundColor(color.swiftUIColor)
            .tint(.white)
            .padding(.horizontal, plate ? 10 : 0)
            .padding(.vertical, plate ? 6 : 0)
            .background(plate ? (plateColor ?? color.contrastText).swiftUIColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: plate ? 10 : 0))
            .shadow(color: plate ? .clear : .black.opacity(0.35), radius: plate ? 0 : 8)
            .padding(.horizontal, 56)
            .onAppear { isFocused = true }
            .onChange(of: text) { _, newValue in
                if newValue.count > 120 {
                    text = String(newValue.prefix(120))
                }
            }
    }

    private var previewFont: Font {
        OverlayFontProvider.font(font, size: min(fontSize, 48))
    }
}

/// Custom slider that adjusts the font size (16-64pt) by dragging vertically.
/// SwiftUI's standard Slider has no vertical orientation, so it is built with GeometryReader +
/// DragGesture.
private struct VerticalSizeSlider: View {
    @Binding var value: Double
    private let range: ClosedRange<Double> = 16...64

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // Pinch can take it out of range (4-600), so clamp to 0...1 and keep the knob at the end
            let t = min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
            let thumbY = h * (1 - t)

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 4, height: h)
                    .position(x: geo.size.width / 2, y: h / 2)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 4, height: max(0, h - thumbY))
                    .position(x: geo.size.width / 2, y: thumbY + max(0, h - thumbY) / 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedY = min(max(drag.location.y, 0), h)
                        let newT = 1 - (clampedY / h)
                        value = range.lowerBound + newT * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}
