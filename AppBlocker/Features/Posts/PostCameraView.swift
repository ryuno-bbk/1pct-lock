//
//  PostCameraView.swift
//  AppBlocker
//
//  New Step1 of UGC posting: a custom TikTok/BeReal-style camera (user decision 2026-07-11).
//  Tapping the + tab opens this camera right away (starts with the back camera).
//    - Center: 4:5 preview (same ratio as the post canvas = almost WYSIWYG)
//    - Bottom: library / shutter / front-back switch, and below them "テンプレートから選ぶ"
//      ("Choose from templates")
//    - Top: close / flash
//  Taking a photo or picking from the library sets the background, then goes straight to the
//  editor (Step2).
//  Templates navigate to the existing PostBackgroundGridView.
//

import SwiftUI
import AVFoundation
import PhotosUI
import UIKit
import Combine

// MARK: - Camera control (AVCaptureSession)

final class PostCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "onepercent.postcamera.session")

    /// nil = checking / true = allowed / false = denied
    @Published var isAuthorized: Bool? = nil
    @Published var flashOn = false
    @Published var isFrontCamera = false

    private var currentInput: AVCaptureDeviceInput?
    private var onPhoto: ((UIImage?) -> Void)?

    /// Apple's own coordinator that reads the device tilt and gives the angle at which "level is captured
    /// as level" (iOS 17+).
    ///
    /// 🔴 Without this, the connection stays fixed at the default portrait (90°). AVFoundation does not
    ///    read the accelerometer on its own, so even when shooting in landscape the EXIF says "shot in
    ///    portrait", and a photo with the world tilted 90° is saved (2026-08-28 user report).
    ///    Apply the same coordinator's angle to both preview and capture to keep WYSIWYG (same shape as
    ///    Apple's AVCam)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Current device, used to rebuild the coordinator. currentInput is touched on the session queue, so
    /// a copy readable from main is kept here
    private var mainDevice: AVCaptureDevice?

    /// Whether the device has a camera (simulator check)
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
                // Start with the back camera (user instruction)
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

    /// Switch front/back camera
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
                self.session.addInput(current)  // Restore it on failure
            }
            self.session.commitConfiguration()

            let activeDevice = self.currentInput?.device
            let isFront = activeDevice?.position == .front
            DispatchQueue.main.async {
                self.isFrontCamera = isFront
                // Replacing the input rebuilds the connection, so rebuild the coordinator too
                self.mainDevice = activeDevice
                self.rebuildRotationCoordinator()
            }
        }
    }

    // MARK: - Orientation (rotation coordinator)

    /// Receives the preview layer. Called when the SwiftUI side (CameraPreviewView) is created
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
        // The angle changes every time the device is tilted, so follow it (to keep the preview and the
        // captured result the same)
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
        // Use the tilt "at the moment of capture". The coordinator lives on main, so read it here and then
        // pass it to the queue
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let mirrored = isFrontCamera
        queue.async {
            if let connection = self.output.connection(with: .video) {
                if let captureAngle, connection.isVideoRotationAngleSupported(captureAngle) {
                    connection.videoRotationAngle = captureAngle
                }
                // The front camera preview is mirrored, so mirror the output too.
                // Before, the UIImage orientation was hard-coded to .leftMirrored after capture, but
                // that only works if "always shot in portrait", and the orientation breaks in landscape
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
        // Orientation (EXIF) and mirroring are already set on the connection in capture(), so nothing is
        // changed here. UIImage(data:) reads the EXIF and returns a UIImage with the correct orientation
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.onPhoto?(image)
            self.onPhoto = nil
        }
    }
}

// MARK: - Preview layer

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Callback to register the created preview layer with the rotation coordinator
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
    /// After the background is set, go to Step2 (editor)
    let onChosen: () -> Void
    /// "テンプレートから選ぶ" ("Choose from templates") → the existing background grid
    let onOpenTemplates: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @StateObject private var camera = PostCameraController()
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var isCapturing = false
    /// How many more posts can be made today (nil = not fetched / fetch failed, hidden).
    /// 2026-07-31 real device feedback: before, this only appeared on the last confirmation screen, so
    /// the remaining slots were unknown until after shooting and editing. Show it at the entry of the
    /// flow (this screen) too
    @State private var remainingSlots: Int?

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// Text for the remaining slots. When 0, use wording that makes it clear they are "used up"
    private func remainingSlotsText(_ remaining: Int) -> String {
        if remaining == 0 {
            return lang == .japanese ? "今日の投稿枠は使い切りました" : "No posts left today" // Wording is waiting for the user's review
        }
        return lang == .japanese
            ? "今日はあと\(remaining)件"
            : "\(remaining) posts left today" // Wording is waiting for the user's review
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // 4:5 preview (same ratio as the post canvas)
                Color.clear
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .overlay { previewContent }
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 0)

                controls
            }

            // Top: close / flash
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
                // Defer to the next loop so the controller is not touched during the View update cycle
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

    // MARK: - Controls (library / shutter / front-back switch + templates)

    private var controls: some View {
        VStack(spacing: 18) {
            HStack {
                // Left: library
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

                // Center: shutter (white ring + white circle)
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

                // Right: front/back switch
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

            // Entry to templates
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

    /// Fit the long side within maxDimension (keeps the aspect ratio). If already smaller, return it as is.
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
