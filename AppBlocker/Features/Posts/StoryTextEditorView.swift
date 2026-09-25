//
//  StoryTextEditorView.swift
//  AppBlocker
//
//  UGC 投稿 v2 Step2: IG ストーリー準拠のテキストオーバーレイエディタ。
//  背景 (photo/template/black/white) の上に最大3個のテキストをドラッグ/ピンチ/回転で
//  自由配置できる。中央スナップ・回転スナップ・ゴミ箱ドロップ削除に対応。
//  「次へ」タップで PostBakeRenderer に焼き込みを依頼し、Step3 (PostConfirmView) へ進む。
//
//  パフォーマンス注意: このファイルの TextField は OverlayTextFieldPreview という
//  小さな子View に局所化している (巨大Viewへの scaleEffect / 直下 TextField 禁止のルールに準拠)。
//  scaleEffect はピンチ操作中のライブフィードバックのみに限定し、焼き込みは実 fontSize で描画する。
//

import SwiftUI
import UIKit

struct StoryTextEditorView: View {
    @ObservedObject var draft: PostDraft
    /// 焼き込み完了後、Step3 へ push するためのコールバック
    let onNext: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var canvasSize: CGSize = .zero

    // 入力モード state
    @State private var isEditingOverlay = false
    @State private var editingOverlayId: UUID?
    @State private var editingText: String = ""
    @State private var editingFont: OverlayFont = .serif
    @State private var editingColor: OverlayColor = .offwhite
    @State private var editingPlate: Bool = false
    @State private var editingPlateColor: OverlayColor? = nil
    @State private var editingAlignment: OverlayAlignment = .center
    @State private var editingFontSize: Double = 32

    // 配置モード中の視覚フィードバック
    @State private var isAnyOverlayDragging = false
    @State private var isAnyOverlayNearTrash = false
    @State private var showSnapGuideX = false
    @State private var showSnapGuideY = false

    @State private var isBaking = false

    // 「戻る」でのキャンセル用スナップショット。次へ (焼き込み) を押さずに離れた場合、
    // overlays だけが書き換わって既存の焼き込み画像と食い違うのを防ぐため、入場時の状態へ戻す。
    @State private var overlaysSnapshot: [EditableOverlay] = []
    @State private var didBake = false

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// draft.images[draft.editingIndex] のオーバーレイ数 (境界外なら 0 扱い)
    private var currentOverlayCount: Int {
        guard draft.images.indices.contains(draft.editingIndex) else { return 0 }
        return draft.images[draft.editingIndex].overlays.count
    }

    var body: some View {
        GeometryReader { geo in
            // 編集キャンバスは 4:5 固定 (画面幅 × 1.25)。これが焼き込み比率になる。
            // フィード/コメント/プロフィールと同じ 4:5 なので、カメラ写真はフィルで余白ゼロに焼ける。
            let canvasW = geo.size.width
            let canvasH = canvasW * 5.0 / 4.0
            let cSize = CGSize(width: canvasW, height: canvasH)

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // 4:5 編集キャンバス。上端 = 入力モードの上部バー (時計/ゴミ箱/完了) の直下。
                // 8pt は上げすぎ・中央は黒帯がダサい (2026-07-11 実機FB×2)。
                // 入力オーバーレイのスポイト canvasRect も同じ 56pt に合わせる
                // 注意: overlay (Aa/時計) は padding より前に付ける。padding の後だと
                // 「余白込みの枠」の右上に整列して Aa が画像の外にはみ出す (実機で発生済み)
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

                                // 現在時刻をワンタップ挿入 (2026-07-11 ユーザー指定: 入力モードを
                                // 開かなくても押せるよう常設)
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

                // テキスト入力モードは全画面 (キャンバス外)
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
                didBake = false  // 出現ごとに1編集セッション (確定画面から戻ってきた再訪も含む)
                if draft.images.indices.contains(draft.editingIndex) {
                    overlaysSnapshot = draft.images[draft.editingIndex].overlays
                }
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = CGSize(width: newSize.width, height: newSize.width * 5.0 / 4.0)
            }
        }
        // キャンバスはキーボードで縮めない。縮むと入力直後の「次へ」で
        // 縮んだ比率のまま焼き込まれ、壊れた投稿になる (実機で発生済み)
        .ignoresSafeArea(.keyboard)
        .onDisappear {
            // 焼き込みせずに離れた = キャンセル。編集内容を入場時の状態へ戻す
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
                    // 入力モード中に押すと未確定テキストが焼き込まれずに消えるため無効化
                    // (先に「完了」か暗転タップで確定させる)
                    .disabled(isEditingOverlay)
                    .opacity(isEditingOverlay ? 0.4 : 1)
                }
            }
        }
    }

    // MARK: - Editing Canvas (4:5)

    /// 4:5 キャンバス内の中身 (背景 + オーバーレイ + スナップガイド + ヒント + ゴミ箱)。
    /// canvasSize は 4:5 の実サイズ。オーバーレイ座標もこの 4:5 基準で正規化される。
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

    /// 編集中の DraftImage の背景 (境界外なら黒にフォールバック)
    private var currentBackground: PostBackground {
        guard draft.images.indices.contains(draft.editingIndex) else { return .black }
        return draft.images[draft.editingIndex].background
    }

    // 実機FB#8 真因修正: .scaledToFill() は提案サイズを超えて自身のレイアウトサイズを
    // 押し広げる (ProfileCards.swift の UserPostGridCell に同じ教訓コメントあり。
    // FeedListCard.imageFitBlur のコメントにも「fill レイヤーが ZStack を押し広げる」
    // 既知バグとして記録されている)。frame/clipped が無いと、この ZStack (背景) が
    // editingCanvas の cSize より大きくなり、外側 .frame(canvasW,canvasH).clipped() で
    // 中央寄せクロップされる際に ZStack 自体の座標原点が可視キャンバスとズレる。
    // PlacedOverlayView は .position(overlay.x*canvasSize.width, ...) で「ZStack の
    // 座標系」に直接置くため、そのズレがそのまま「中央に置いたのに見た目がズレる」に
    // 直結していた (焼き込み側の BakeCompositionView.backgroundLayer は既にこの
    // frame+clipped を持っていたため焼き込み結果は正しかった)。
    // size を明示で受け取り、常に cSize ちょうどに固定することで座標系のズレを断つ。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        switch currentBackground {
        case .photo(let image):
            // 4:5 キャンバスをフィル (aspectFill + クロップ)。カメラ写真は余白なく埋まり、
            // 極端な比率の画像だけ上下 or 左右が少し切れる (ユーザー確定: 余白ゼロ優先)
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

    // MARK: - 入力モード

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

    /// 現在時刻をワンタップで配置 (入力モード不要)。
    /// 白背景では ink になる (defaultOverlayColor) ので「時刻が見えない」問題も解消
    private func insertTimeOverlay() {
        guard draft.images.indices.contains(draft.editingIndex),
              currentOverlayCount < 3 else { return }
        let new = EditableOverlay(
            id: UUID(),
            text: OverlayFontProvider.currentTimeString(),
            font: .serif,   // 初期フォントは一番左 (明朝)。時刻も同じ (2026-07-11 ユーザー指定)
            color: defaultOverlayColor,
            plate: false,
            x: 0.5,
            y: 0.3,   // 中央だと本文と被りやすいので少し上に置く
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

    /// 入力モードのゴミ箱: 編集中のテキストを削除して閉じる (新規なら破棄のみ)
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
            // x / y / rotationDegrees は維持 (再編集時は位置を動かさない)
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

    // MARK: - 次へ (焼き込み: 編集中の DraftImage 1枚分)

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

// MARK: - OverlayGlyphView (共通描画パーツ、PostBakeRenderer からも参照される)

/// 1つのテキストオーバーレイの見た目 (フォント + 色 + プレート + シャドウ)。
/// ライブエディタと焼き込みレンダラーの両方から呼ばれる。
struct OverlayGlyphView: View {
    let overlay: EditableOverlay
    /// 実際に描画する pt 値 (呼び出し側で正規化 fontSize から算出済み)
    let resolvedFontSize: CGFloat
    /// プレート余白 / 角丸 / シャドウ半径に掛ける倍率。エディタ表示は 1 (等倍)、
    /// 焼き込み (BakeCompositionView) は fontSize と同じ k (renderWidth/canvasWidth) を渡す。
    /// これを揃えないとプレート/シャドウだけがエディタよりきつく焼き込まれる (2026-07-11 発覚)
    var scale: CGFloat = 1

    private var font: Font {
        OverlayFontProvider.font(overlay.font, size: resolvedFontSize)
    }

    var body: some View {
        // 文字色 = color、プレート背景 = plateColor (未指定なら自動コントラスト)。
        // 「文字/背景」を独立に選べる (2026-07-11 直感性FBで分離)。
        // 折り返しは一切しない (IG準拠): 改行は手動のみ。
        // 大きくすればキャンバス端からはみ出し、見切れ表現ができる (焼き込みでクロップされる)
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
            // 影は可読性用。120pt 超の巨大文字では影のラスタライズが極端に重く
            // フリーズの原因になるため無効化する (2026-07-11)。
            // ここの 120 判定は overlay.fontSize (エディタ座標系の正規化前 pt) を使い、
            // resolvedFontSize (焼き込み時は k 倍済み) を使わないことで
            // プレビューと焼き込みで影の on/off が食い違わないようにする
            .shadow(
                color: (overlay.plate || overlay.fontSize > 120) ? .clear : .black.opacity(0.35),
                radius: (overlay.plate || overlay.fontSize > 120) ? 0 : 8 * scale
            )
    }
}

// MARK: - PlacedOverlayView (配置モード: ドラッグ/ピンチ/回転 + スナップ + ゴミ箱削除)

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

    // 判定圏はアイコンにほぼ重なる距離だけ (旧50は広すぎて画面下部にテキストを
    // 置けなかった。2026-07-11 実機FB)
    private let trashRadius: CGFloat = 32
    private let centerSnapThreshold: CGFloat = 8
    private let rotationSnapThreshold: Double = 4

    private var basePoint: CGPoint {
        CGPoint(x: overlay.x * canvasSize.width, y: overlay.y * canvasSize.height)
    }

    private var trashCenter: CGPoint {
        // 描画側 (trashButton: bottom padding 40 + アイコン 34pt の半分 ≈ 17) と一致させる。
        // ズレると「ゴミ箱の見た目の位置」と「実際に消える判定圏」が食い違う
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 57)
    }

    /// ライブ表示用のオフセット (中央スナップの軽い吸着込み)
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

    /// ライブピンチ表示用のスケール。ピンチはほぼ無制限 (4〜300pt)。左のスライダーは 16〜64 のまま。
    /// 上限 300: 数百pt超の影付きテキストはラスタライズが重く、状態変更のたびに
    /// メインスレッドが固まる (実機フリーズ 2026-07-11)。300 でも画面幅を余裕で超える。
    /// clamp を先取りして「指を離した瞬間に縮む/伸びる」ジャンプを防ぐ
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

// MARK: - OverlayInputOverlay (入力モード: IG 準拠の 4 ボタンツールバー + 横スクロール行)
//
// 構成 (2026-07-11 ユーザー確定、IG のテキストエディタを踏襲):
//   - 上部: 時刻挿入 / ゴミ箱 / 完了
//   - 中央: テキスト + 左に縦サイズスライダー
//   - 下部: アクティブ行 (フォントピル or カラースウォッチ、どちらも横スクロール)
//           + 4 ボタンバー [Aa フォント] [カラーホイール] [整列] [A プレート]
//   - スポイト: カラー行の左端。ドラッグでルーペが動き、背景画像から色を拾う

private struct OverlayInputOverlay: View {
    @Binding var text: String
    @Binding var font: OverlayFont
    @Binding var color: OverlayColor
    @Binding var plate: Bool
    /// プレート背景色 (nil = 文字色から自動コントラスト)
    @Binding var plateColor: OverlayColor?
    @Binding var alignment: OverlayAlignment
    @Binding var fontSize: Double
    /// スポイトのサンプリング元 (編集中の背景)
    let background: PostBackground
    let lang: AppLanguage
    let onDone: () -> Void
    /// 編集中のテキストを削除して閉じる (topBar のゴミ箱)
    let onDelete: () -> Void

    private enum ActiveTool {
        case font
        case color
    }

    @State private var activeTool: ActiveTool = .font
    /// フォント行のスライド選択位置 (中央に来たピル = 選択)
    @State private var fontScrollID: OverlayFont?

    // スポイト
    @State private var isEyedropperActive = false
    @State private var dropperPoint: CGPoint = .zero
    @State private var dropperColor: OverlayColor = .offwhite
    @State private var sampler: EyedropperSampler?

    var body: some View {
        GeometryReader { geo in
            // レイアウト基準 (キーボード非依存の固定分率)
            let textCenterY = geo.size.height * 0.29
            let toolsCenterY = geo.size.height * 0.50
            // 4:5 キャンバスの実領域 (スポイトの可動域)。エディタ本体の上寄せ (top 56pt) と一致させる
            let canvasHeight = geo.size.width * 5.0 / 4.0
            let canvasRect = CGRect(
                x: 0,
                y: 56,
                width: geo.size.width,
                height: canvasHeight
            )

            ZStack {
                // 暗転レイヤー。タップで確定 (onDone)
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
                    // SwiftUI の TextField はフォーカス中の文字色/フォント変更を次のキー入力まで
                    // 反映しない既知の癖がある。スタイルが変わったら id を変えてフィールドを
                    // 作り直し、即時反映させる (onAppear で再フォーカスされる。2026-07-11 実機FB)
                    .id("preview-\(color.token)-\(plate)-\(plateColor?.token ?? "auto")-\(font.rawValue)-\(alignment.rawValue)")
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { /* 帯内タップは閉じない */ }
                    .position(x: geo.size.width / 2, y: textCenterY)

                    // 下部: アクティブ行 + 4ボタンバー
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

                    // スライダーは短め (下端がカラー行のスポイトに重ならないように。2026-07-11 FB)
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

    // MARK: - Top Bar (時刻 / ゴミ箱 / 完了。全ボタン 44pt 判定)

    private var topBar: some View {
        HStack(spacing: 8) {
            // 現在時刻を挿入 (フォントは現在の選択のまま = 初期は一番左の明朝)
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

            // このテキストを削除
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

    // MARK: - 4 ボタンバー [Aa] [カラー] [整列] [プレート]

    private var toolBar: some View {
        HStack(spacing: 8) {
            // Aa (フォント行へ)
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

            // カラーホイール (スウォッチ行へ)
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

            // プレート背景サイクル: OFF → グレー → 黒 → 白 → OFF (2026-07-11 ユーザー指定。
            // スウォッチは常に文字色。トグル式より単純でバグりにくい)
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

    // MARK: - フォント行 (横スクロール + スライド選択。IG 準拠)

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
        // 中央スナップ: 左右に余白を作り、中央に来たピルが選択される
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

    /// ピル上の "Aa" を各フォントで表示 (見た目で選べるように)
    private func pillFont(_ kind: OverlayFont) -> Font {
        // didot だけ 1pt 大きくしていた微調整は解決口の一本化で落とした
        // (ピッカーに出ない case なので実害なし)
        OverlayFontProvider.font(kind, size: 15)
    }

    // MARK: - カラー行 (左端スポイト + 細分パレット。横スクロール 1 列)

    private var plateButtonForeground: Color {
        guard plate else { return .white }
        return (plateColor ?? .offwhite).contrastText.swiftUIColor
    }

    /// プレート背景サイクル: OFF → グレー → 黒 → 白 → OFF
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
                // スポイト (文字色を背景画像から拾う)
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

    // MARK: - スポイト (ドラッグでルーペ、背景画像から色を拾う)

    private func startEyedropper() {
        sampler = EyedropperSampler(background: background)
        // 初期位置 = 画面中央 (キャンバス中央付近)
        dropperPoint = .zero  // eyedropperLayer 側で canvasRect 中央に初期化
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

            // ルーペ (指の上に表示。IG のスポイトと同じティアドロップ風)
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

            // 指位置の小さな点
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 10, height: 10)
                .position(point)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Cycle Actions

}

/// スポイト用の三角ポインタ
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

// MARK: - EyedropperSampler (背景を小さなビットマップに1回だけ描いて色を引く)

/// スポイトのサンプリング。背景 (写真/テンプレ/単色) をキャンバス比率 (4:5) の
/// 小ビットマップへ aspectFill で1回だけ描画し、以降の指の移動ごとに O(1) で色を返す
/// (毎フレーム 12MP 画像をデコードしないための前処理)
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

    /// aspectFill (中央クロップ) で描く。エディタの表示と同じ見え方の範囲から色を拾う
    private static func drawFill(_ image: UIImage, in size: CGSize) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
    }
}

/// 入力モード中のテキスト表示専用の小さな子View (パフォーマンス対策で局所化)。
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

/// フォントサイズ (16〜64pt) を縦ドラッグで調整するカスタムスライダー。
/// SwiftUI 標準 Slider に縦向きが無いため、GeometryReader + DragGesture で自作。
private struct VerticalSizeSlider: View {
    @Binding var value: Double
    private let range: ClosedRange<Double> = 16...64

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // ピンチで範囲外 (4〜600) になり得るため 0...1 にクランプしてつまみを端に留める
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
