@preconcurrency import AVFoundation
import SwiftUI

/// Owns the picture-in-picture camera session, confining the blocking
/// `AVCaptureSession` calls to a private queue.
private final class PiPSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.yurika.mbCamera.pip-session")
    private var isConfigured = false

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }

                if !isConfigured {
                    // Never auto-connect a phone for the PiP overlay.
                    let device = DeviceDiscovery.fallbackCamera()
                    guard let device,
                          let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input) else {
                        return
                    }

                    session.beginConfiguration()
                    session.addInput(input)
                    session.commitConfiguration()
                    isConfigured = true
                }

                if !session.isRunning {
                    session.startRunning()
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }
}

@MainActor
final class PiPCameraSessionManager: ObservableObject {
    let previewLayer: AVCaptureVideoPreviewLayer

    private let runner = PiPSessionRunner()

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: runner.session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start() {
        Task {
            await runner.start()
            // Selfie-style mirroring, like the main camera preview.
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    func stop() {
        Task {
            await runner.stop()
        }
    }
}

struct PiPCameraPreview: View {
    var onDragDelta: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    @StateObject private var manager = PiPCameraSessionManager()

    var body: some View {
        CameraPreviewView(
            previewLayer: manager.previewLayer,
            onDragDelta: onDragDelta,
            onDragEnded: onDragEnded
        )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            .onAppear {
                manager.start()
            }
            .onDisappear {
                manager.stop()
            }
    }
}
