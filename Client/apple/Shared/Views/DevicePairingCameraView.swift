@preconcurrency import AVFoundation
import ChirpMLS
import Observation
import SwiftUI
import Vision

struct DevicePairingCameraView: View {
    let onCode: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = PairingCameraModel()
    @State private var delivered = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                MessageText("请扫描您本人新设备当前显示的 Chirp 设备授权二维码。扫描后仍需核对安全码并确认批准。")
                    .font(.callout).padding(.horizontal, 24)
                if let session = camera.session {
                    PairingCameraPreview(session: session)
                        .frame(minHeight: 260, maxHeight: 420).clipShape(.rect(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .accessibilityLabel(Text(verbatim: LocalizedMessage(stringLiteral: "设备授权扫码取景框").localized(in: AppLanguage.load().locale)))
                } else if let failure = camera.failure {
                    Image(systemName: "camera.fill").font(.largeTitle).accessibilityHidden(true)
                    Text(verbatim: failure).font(.callout).padding(24)
                    MessageText("您也可以返回设置，导入二维码图片。")
                } else { ProgressView { MessageText("正在准备摄像头…") } }
                Spacer(minLength: 16)
            }
            .padding(.top, 24)
            .messageNavigationTitle("扫描设备授权二维码")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { MessageText("取消") } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
        // The system camera permission prompt can temporarily make the scene inactive.
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else { camera.stop(); return }
            guard !delivered else { return }
            await camera.start { value in
                guard !delivered else { return }
                delivered = true; camera.stop(); onCode(value)
            }
        }
        .onDisappear { camera.stop() }
    }
}

@MainActor @Observable
private final class PairingCameraModel {
    private(set) var failure: String?
    private(set) var session: AVCaptureSession?
    @ObservationIgnored private var capture: PairingCameraCapture?
    @ObservationIgnored private var generation = UUID()

    func start(onCode: @escaping @MainActor @Sendable (String) -> Void) async {
        guard capture == nil else { return }
        let token = UUID()
        generation = token
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard !Task.isCancelled, generation == token else { return }
        guard allowed else { failure = DevicePairingError.cameraUnavailable.localizedDescription; return }
        let value = PairingCameraCapture { [weak self] value in
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                onCode(value)
            }
        }
        failure = nil
        capture = value
        do {
            try await value.start()
            guard generation == token else { return }
            try Task.checkCancellation()
            // Attaching the preview adds a connection to the session.
            session = value.session
        } catch {
            guard generation == token else { return }
            if !Task.isCancelled {
                failure = DevicePairingError.cameraUnavailable.localizedDescription
            }
            stop()
        }
    }

    func stop() {
        generation = UUID()
        session = nil
        capture?.stop()
        capture = nil
    }
}

// All capture configuration and lifecycle writes run on controlQueue. Frame
// state is confined to frameQueue; only decoded public request text leaves it.
private final class PairingCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private static let controlQueue = DispatchQueue(label: "cn.youzifeile.chirp.pairing-camera")
    private let frameQueue = DispatchQueue(label: "cn.youzifeile.chirp.pairing-qr")
    private let onCode: @Sendable (String) -> Void
    private var delivered = false
    private var lastFrame: TimeInterval = 0

    init(onCode: @escaping @Sendable (String) -> Void) {
        self.onCode = onCode
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.controlQueue.async { [self] in
                do {
                    try configure()
                    session.startRunning()
                    guard session.isRunning else { throw DevicePairingError.cameraUnavailable }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw DevicePairingError.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        #if os(iOS)
        session.automaticallyConfiguresApplicationAudioSession = false
        #endif
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { throw DevicePairingError.cameraUnavailable }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw DevicePairingError.cameraUnavailable }
        session.addOutput(output)
    }

    func stop() {
        Self.controlQueue.async { [self] in
            session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date.timeIntervalSinceReferenceDate
        guard !delivered, now - lastFrame >= 0.25, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cvPixelBuffer: image).perform([request])
            let values = (request.results ?? []).compactMap(\.payloadStringValue)
            guard values.count == 1, let value = values.first, (try? DevicePairingRequest.parse(value)) != nil else { return }
            delivered = true; onCode(value)
        } catch { /* A blurred frame can be retried without authorizing anything. */ }
    }
}

#if os(iOS)
private struct PairingCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PairingPreviewUIView {
        let view = PairingPreviewUIView(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PairingPreviewUIView, context: Context) {
        if uiView.preview.session !== session { uiView.preview.session = session }
    }
}
private final class PairingPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#elseif os(macOS)
private struct PairingCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer = preview
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let preview = nsView.layer as? AVCaptureVideoPreviewLayer, preview.session !== session {
            preview.session = session
        }
    }
}
#endif
