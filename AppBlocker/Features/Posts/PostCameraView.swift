//
//  PostCameraView.swift
//  AppBlocker
//
//  UGC 投稿の新 Step1: TikTok/BeReal 式の自前カメラ (2026-07-11 ユーザー確定)。
//  ＋タブを押すと即このカメラが開く (背面スタート)。
//    - 中央: 4:5 プレビュー (投稿キャンバスと同比率 = ほぼ WYSIWYG)
//    - 下部: ライブラリ / シャッター / 前後切替、その下に「テンプレートから選ぶ」
//    - 上部: 閉じる / フラッシュ
//  撮影 or ライブラリ選択で背景を確定し、そのままエディタ (Step2) へ進む。
//  テンプレートは従来の PostBackgroundGridView へ遷移する。
//

import SwiftUI
import AVFoundation
import PhotosUI
import UIKit
import Combine

// MARK: - カメラ制御 (AVCaptureSession)

final class PostCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "onepercent.postcamera.session")

    /// nil = 判定中 / true = 許可 / false = 拒否
    @Published var isAuthorized: Bool? = nil
    @Published var flashOn = false
    @Published var isFrontCamera = false

    private var currentInput: AVCaptureDeviceInput?
    private var onPhoto: ((UIImage?) -> Void)?

    /// 端末の傾きを見て「水平が水平に写る」角度を教えてくれる Apple 純正の調停役 (iOS 17+)。
    ///
    /// 🔴 これが無いと接続は既定の縦 (90°) に固定されたままになる。AVFoundation は
    ///    加速度センサーを勝手に読まないので、横に構えて撮っても「縦で撮った」EXIF が付き、
    ///    世界が90°倒れた写真が保存される (2026-08-28 ユーザー報告)。
    ///    プレビューと撮影の両方に同じ調停役の角度を当てて WYSIWYG を保つ (Apple の AVCam と同じ形)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// 調停役を作り直すための現在デバイス。currentInput は session queue 側で触るので
    /// main から読める複製をこちらに持つ
    private var mainDevice: AVCaptureDevice?

    /// カメラデバイスを持つ端末か (シミュレータ判定)
    static var hasCameraDevice: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.isAuthorized = granted }
                if granted { self?.configureAndRun() }
            }
        default:
            DispatchQueue.main.async { self.isAuthorized = false }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndRun() {
        queue.async {
            if self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                // 背面スタート (ユーザー指定)
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                }
                if self.session.canAddOutput(self.output) {
                    self.session.addOutput(self.output)
                }
                self.session.commitConfiguration()
            }
            if !self.session.isRunning { self.session.startRunning() }
            let device = self.currentInput?.device
            DispatchQueue.main.async {
                self.mainDevice = device
                self.rebuildRotationCoordinator()
            }
        }
    }

    /// 前後カメラ切替
    func flip() {
        queue.async {
            guard let current = self.currentInput else { return }
            let newPosition: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            } else {
                self.session.addInput(current)  // 失敗時は戻す
            }
            self.session.commitConfiguration()

            let activeDevice = self.currentInput?.device
            let isFront = activeDevice?.position == .front
            DispatchQueue.main.async {
                self.isFrontCamera = isFront
                // 入力を差し替えると接続が張り直されるので、調停役も作り直す
                self.mainDevice = activeDevice
                self.rebuildRotationCoordinator()
            }
        }
    }

    // MARK: - 向き (回転調停役)

    /// プレビュー層を受け取る。SwiftUI 側 (CameraPreviewView) の生成時に呼ばれる
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildRotationCoordinator()
    }

    private func rebuildRotationCoordinator() {
        rotationObservation = nil
        guard let device = mainDevice else {
            rotationCoordinator = nil
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        // 端末を傾けるたびに角度が変わるので追従させる (プレビューと撮影結果を一致させるため)
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func capture(_ completion: @escaping (UIImage?) -> Void) {
        onPhoto = completion
        // 「撮影した瞬間」の傾きを使う。調停役は main 側にあるのでここで読んでから queue に渡す
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let mirrored = isFrontCamera
        queue.async {
            if let connection = self.output.connection(with: .video) {
                if let captureAngle, connection.isVideoRotationAngleSupported(captureAngle) {
                    connection.videoRotationAngle = captureAngle
                }
                // 前面カメラはプレビューが鏡像なので出力も鏡像に揃える。
                // 以前は撮影後に UIImage の orientation を .leftMirrored でベタ書きしていたが、
                // それは「常に縦で撮る」前提でしか成立せず、横に構えると向きが壊れる
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
            }
            let settings = AVCapturePhotoSettings()
            if self.output.supportedFlashModes.contains(.on) {
                settings.flashMode = self.flashOn ? .on : .off
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 向き (EXIF) も鏡像も capture() で接続に設定済みなので、ここでは一切いじらない。
        // UIImage(data:) が EXIF を読んで正しい向きの UIImage を返す
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.onPhoto?(image)
            self.onPhoto = nil
        }
    }
}

// MARK: - プレビューレイヤー

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// 生成したプレビュー層を回転調停役に登録するためのコールバック
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        onLayerReady(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - PostCameraView

struct PostCameraView: View {
    @ObservedObject var draft: PostDraft
    /// 背景確定後に Step2 (エディタ) へ進む
    let onChosen: () -> Void
    /// 「テンプレートから選ぶ」→ 従来の背景グリッドへ
    let onOpenTemplates: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @StateObject private var camera = PostCameraController()
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var isCapturing = false
    /// 今日あと何件投稿できるか (nil = 未取得/取得失敗で非表示)。
    /// 2026-07-31 実機FB: 従来は最後の確認画面にしか出ておらず、撮影・編集を終えてからでないと
    /// 残り枠が分からなかった。フローの入口 (この画面) でも見えるようにする
    @State private var remainingSlots: Int?

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// 残り枠の表記。0 件のときは「使い切った」ことがはっきり分かる文言にする
    private func remainingSlotsText(_ remaining: Int) -> String {
        if remaining == 0 {
            return lang == .japanese ? "今日の投稿枠は使い切りました" : "No posts left today" // 文言はユーザー添削待ち
        }
        return lang == .japanese
            ? "今日はあと\(remaining)件"
            : "\(remaining) posts left today" // 文言はユーザー添削待ち
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // 4:5 プレビュー (投稿キャンバスと同比率)
                Color.clear
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .overlay { previewContent }
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 0)

                controls
            }

            // 上部: 閉じる / フラッシュ
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(.black.opacity(0.4)))
                    }

                    Spacer()

                    if let remainingSlots {
                        Text(remainingSlotsText(remainingSlots))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(remainingSlots == 0 ? AppColors.error : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.4)))
                    }

                    Spacer()

                    Button {
                        camera.flashOn.toggle()
                    } label: {
                        Image(systemName: camera.flashOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(camera.flashOn ? .yellow : .white)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(.black.opacity(0.4)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)

                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { remainingSlots = await UserPostService.shared.remainingDailyPostSlots() }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    // MARK: - Preview Content

    @ViewBuilder
    private var previewContent: some View {
        if !PostCameraController.hasCameraDevice {
            cameraUnavailableView(
                message: lang == .japanese
                    ? "この端末ではカメラを使えない"
                    : "Camera is not available on this device"
            )
        } else if camera.isAuthorized == false {
            cameraUnavailableView(
                message: lang == .japanese
                    ? "カメラへのアクセスが許可されていない"
                    : "Camera access is not allowed",
                showSettings: true
            )
        } else {
            CameraPreviewView(session: camera.session) { layer in
                // View 更新サイクル中に controller を触らないよう次のループへ逃がす
                DispatchQueue.main.async { camera.attachPreviewLayer(layer) }
            }
        }
    }

    private func cameraUnavailableView(message: String, showSettings: Bool = false) -> some View {
        ZStack {
            Color(white: 0.08)
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 34, weight: .thin))
                    .foregroundColor(.white.opacity(0.4))
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                if showSettings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(lang == .japanese ? "設定を開く" : "Open Settings")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.white))
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Controls (ライブラリ / シャッター / 前後切替 + テンプレート)

    private var controls: some View {
        VStack(spacing: 18) {
            HStack {
                // 左: ライブラリ
                PhotosPicker(selection: $photoPickerItem, matching: .images, photoLibrary: .shared()) {
                    Group {
                        if isLoadingPhoto {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
                }
                .disabled(isLoadingPhoto)

                Spacer()

                // 中央: シャッター (白リング + 白丸)
                Button {
                    takePhoto()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 5)
                            .frame(width: 78, height: 78)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 62, height: 62)
                            .scaleEffect(isCapturing ? 0.82 : 1)
                    }
                }
                .disabled(isCapturing || camera.isAuthorized != true)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isCapturing)

                Spacer()

                // 右: 前後切替
                Button {
                    camera.flip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .disabled(camera.isAuthorized != true)
            }
            .padding(.horizontal, 36)

            // テンプレート導線
            Button(action: onOpenTemplates) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                    Text(PostFlowStrings.templateSectionLabel(lang))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private func takePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        camera.capture { image in
            isCapturing = false
            guard let image else { return }
            let resized = downsample(image, maxDimension: 2000)
            if draft.selectBackground(.photo(resized)) {
                onChosen()
            }
        }
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer {
            isLoadingPhoto = false
            photoPickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let original = UIImage(data: data) else {
            print("⚠️ PostCameraView: failed to load selected photo")
            return
        }
        let resized = downsample(original, maxDimension: 2000)
        if draft.selectBackground(.photo(resized)) {
            onChosen()
        }
    }

    /// 長辺を maxDimension に収める (アスペクト比維持)。すでに小さければそのまま返す。
    private func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let ratio = maxDimension / longSide
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
