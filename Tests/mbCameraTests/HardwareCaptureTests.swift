import AVFoundation
import CameraCore
import Foundation
import Testing
@testable import mbCamera

/// End-to-end tests against the real capture hardware. Opt-in because they turn on
/// the camera and need camera/microphone permission for the invoking terminal:
///
///     MBCAMERA_HARDWARE_TESTS=1 swift test --filter HardwareCapture
///
@Suite(
    "HardwareCapture",
    .enabled(if: ProcessInfo.processInfo.environment["MBCAMERA_HARDWARE_TESTS"] == "1"),
    .serialized
)
struct HardwareCaptureTests {
    @Test("photo formats, preset fallback, and video recording against the real camera")
    @MainActor
    func fullCaptureRoundTrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbCamera-hw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = CaptureService()
        let permissions = await service.requestPermissions()
        try #require(permissions.cameraGranted, "camera permission is required for hardware tests")

        let inventory = await service.discoverDevices()
        let camera = try #require(inventory.cameras.first, "no camera connected")

        var settings = AppSettings(
            mode: .photo,
            photoQuality: .high,
            photoFormat: .jpeg,
            videoResolution: .uhd4k, // FaceTime cameras can't do 4K: exercises the preset fallback
            videoFrameRate: .fps60,
            mediaDestination: .photosDirectory,
            mediaDirectoryPath: tempDir.path,
            selectedInput: CaptureInputSelection(id: camera.id, name: camera.name, type: .camera)
        )

        // Configuring an unsupported resolution must not throw (Improv bug #1).
        let applied = try await service.apply(settings: settings)
        #expect(applied.videoAspectRatio ?? 0 > 0)
        await service.startPreview()

        // JPEG photo really is JPEG.
        let jpegMedia = try await service.capturePhoto(with: settings)
        let jpegURL = try #require(jpegMedia.fileURL)
        let jpegData = try Data(contentsOf: jpegURL)
        #expect(jpegData.count > 10_000)
        #expect(jpegData.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        #expect(jpegURL.pathExtension == "jpg")

        // HEIC (the default format) produces a HEIF container.
        settings.photoFormat = .heic
        let heicMedia = try await service.capturePhoto(with: settings)
        let heicURL = try #require(heicMedia.fileURL)
        let heicData = try Data(contentsOf: heicURL)
        if heicURL.pathExtension == "heic" {
            #expect(heicData.count > 4_000)
            #expect(Data(heicData[4..<8]) == Data("ftyp".utf8))
        } else {
            // Machines without HEVC encoding fall back to JPEG with a .jpg name.
            #expect(heicURL.pathExtension == "jpg")
            #expect(heicData.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        }

        // PNG photo really is PNG.
        settings.photoFormat = .png
        let pngMedia = try await service.capturePhoto(with: settings)
        let pngURL = try #require(pngMedia.fileURL)
        let pngData = try Data(contentsOf: pngURL)
        #expect(pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(pngURL.pathExtension == "png")

        // Video mode: reconfigure, record ~2s, and get a playable movie back.
        settings.mode = .video
        try await service.apply(settings: settings)
        await service.startPreview()

        try await service.startRecording(with: settings)
        try await Task.sleep(for: .seconds(2))
        let videoMedia = try await service.stopRecording(with: settings)

        let videoURL = try #require(videoMedia.fileURL)
        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        #expect(videoSize > 50_000, "recorded movie should have real frames")
        #expect(videoURL.pathExtension == "mov")

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 1.0)

        await service.stopPreview()
    }
}
