import AppKit
import AVFoundation
import CameraCore
import Foundation
import Testing
@testable import mbCamera

@MainActor
private final class MockCaptureService: CaptureServiceProtocol {
    let previewLayer = AVCaptureVideoPreviewLayer(session: AVCaptureSession())
    var onRecordingFinishedUnexpectedly: ((CapturedMedia?, Error?) -> Void)?

    var discoveredInventory = DeviceInventory()
    var discoveredInventorySequence: [DeviceInventory] = []
    var enforceInputValidation = false
    var applyCalls: [AppSettings] = []
    var startPreviewCalls = 0
    var stopPreviewCalls = 0
    var capturePhotoCalls = 0
    var startRecordingCalls = 0
    var stopRecordingCalls = 0
    var focusPoints: [CGPoint] = []
    var applyErrors: [Error] = []
    var stopRecordingErrors: [Error] = []

    var photoOutputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("photo.jpg")
    var videoOutputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("video.mov")
    var photoResultOverride: CapturedMedia?

    func requestPermissions() async -> CapturePermissions {
        CapturePermissions(cameraGranted: true, microphoneGranted: true)
    }

    func discoverDevices() async -> DeviceInventory {
        if !discoveredInventorySequence.isEmpty {
            discoveredInventory = discoveredInventorySequence.removeFirst()
        }
        return discoveredInventory
    }

    func apply(settings: AppSettings) async throws -> AppliedCaptureConfiguration {
        applyCalls.append(settings)
        try validateSelectedInputIfNeeded(settings)
        if let error = popNextApplyError() {
            throw error
        }
        return AppliedCaptureConfiguration(videoAspectRatio: nil)
    }

    func startPreview() async {
        startPreviewCalls += 1
    }

    func stopPreview() async {
        stopPreviewCalls += 1
    }

    func capturePhoto(with settings: AppSettings) async throws -> CapturedMedia {
        capturePhotoCalls += 1
        if let photoResultOverride {
            return photoResultOverride
        }
        return CapturedMedia(fileURL: photoOutputURL, thumbnailFileURL: photoOutputURL)
    }

    func startRecording(with settings: AppSettings) async throws {
        startRecordingCalls += 1
    }

    func stopRecording(with settings: AppSettings) async throws -> CapturedMedia {
        stopRecordingCalls += 1
        if let error = popNextStopRecordingError() {
            throw error
        }
        return CapturedMedia(fileURL: videoOutputURL, thumbnailFileURL: videoOutputURL)
    }

    func setFocusAndExposure(normalizedPoint: CGPoint) async throws {
        focusPoints.append(normalizedPoint)
    }

    private func popNextApplyError() -> Error? {
        guard !applyErrors.isEmpty else {
            return nil
        }
        return applyErrors.removeFirst()
    }

    private func popNextStopRecordingError() -> Error? {
        guard !stopRecordingErrors.isEmpty else {
            return nil
        }
        return stopRecordingErrors.removeFirst()
    }

    private func validateSelectedInputIfNeeded(_ settings: AppSettings) throws {
        guard enforceInputValidation else {
            return
        }

        guard let selected = settings.selectedInput else {
            throw CaptureServiceError.missingInputSource
        }

        switch selected.type {
        case .camera:
            if !discoveredInventory.cameras.contains(where: { $0.id == selected.id }) {
                throw CaptureServiceError.cameraNotFound
            }
        case .screen:
            if !discoveredInventory.screens.contains(where: { $0.id == selected.id }) {
                throw CaptureServiceError.screenNotFound
            }
        }
    }
}

@Suite("CameraViewModel")
struct CameraViewModelTests {
    @Test("initialize fills defaults and starts preview")
    @MainActor
    func initializeFillsDefaultsAndStartsPreview() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            screens: [DeviceDescriptor(id: "88", name: "Display", type: .screen)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()

        #expect(viewModel.settings.selectedInput?.id == "cam-1")
        #expect(viewModel.settings.selectedAudioSources.count == 2)
        #expect(viewModel.settings.selectedAudioSources.contains(where: { $0.kind == .microphone && $0.isEnabled }))
        #expect(viewModel.isInitialized)
        #expect(mock.startPreviewCalls == 1)
        #expect(mock.applyCalls.count == 1)
    }

    @Test("photo capture updates last media url")
    @MainActor
    func photoCaptureUpdatesLastMediaURL() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let photoURL = tempRoot.appendingPathComponent("latest.jpg")
        try Data().write(to: photoURL)
        mock.photoOutputURL = photoURL

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.captureButtonPressed()

        #expect(mock.capturePhotoCalls == 1)
        #expect(viewModel.lastMediaURL == photoURL)
        #expect(!viewModel.lastMediaIsInPhotoLibrary)
    }

    @Test("photo saved to the library keeps a thumbnail source but no file url")
    @MainActor
    func photoSavedToLibraryHasNoFileURL() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        mock.photoResultOverride = CapturedMedia(thumbnailData: Data([0x01]))

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()
        await viewModel.captureButtonPressed()

        #expect(viewModel.lastMediaURL == nil)
        #expect(viewModel.lastMediaIsInPhotoLibrary)
    }

    @Test("initialize falls back to a different input when selected camera cannot be configured")
    @MainActor
    func initializeFallsBackToDifferentInput() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [
                DeviceDescriptor(id: "cam-2", name: "External Cam", type: .camera),
                DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)
            ],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )
        mock.applyErrors = [CaptureServiceError.cameraNotFound]

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        try store.replace(
            with: AppSettings(
                selectedInput: CaptureInputSelection(id: "cam-1", name: "FaceTime", type: .camera)
            )
        )

        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()

        #expect(viewModel.settings.selectedInput?.id == "cam-2")
        #expect(mock.applyCalls.count == 2)
        #expect(mock.startPreviewCalls == 1)
    }

    @Test("video mode toggles recording")
    @MainActor
    func videoModeTogglesRecording() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let videoURL = tempRoot.appendingPathComponent("latest.mov")
        try Data().write(to: videoURL)
        mock.videoOutputURL = videoURL

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)

        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)
        #expect(viewModel.recordingStartedAt != nil)
        #expect(mock.startRecordingCalls == 1)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(viewModel.recordingStartedAt == nil)
        #expect(mock.stopRecordingCalls == 1)
        #expect(viewModel.lastMediaURL == videoURL)
    }

    @Test("mode switching is ignored while recording")
    @MainActor
    func modeSwitchIgnoredWhileRecording() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)
        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        await viewModel.setMode(.photo)
        #expect(viewModel.settings.mode == .video)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(mock.stopRecordingCalls == 1)
    }

    @Test("stop recording retries when output reports not yet recording")
    @MainActor
    func stopRecordingRetriesWhenNotYetRecording() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )
        mock.stopRecordingErrors = [CaptureServiceError.recordingNotInProgress]

        let videoURL = tempRoot.appendingPathComponent("retry.mov")
        try Data().write(to: videoURL)
        mock.videoOutputURL = videoURL

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)

        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(mock.stopRecordingCalls == 2)
        #expect(viewModel.lastMediaURL == videoURL)
    }

    @Test("persistent stop failure still releases the recording state")
    @MainActor
    func persistentStopFailureReleasesRecordingState() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )
        mock.stopRecordingErrors = Array(repeating: CaptureServiceError.recordingNotInProgress, count: 6)

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)
        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("failed video persistence releases recording state and keeps the temp file reachable")
    @MainActor
    func failedPersistenceReleasesStateAndKeepsTempFile() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )
        let strandedPath = tempRoot.appendingPathComponent("stranded.mov").path
        mock.stopRecordingErrors = [CaptureServiceError.videoPersistenceFailed(tempPath: strandedPath)]

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)
        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(viewModel.recordingStartedAt == nil)
        #expect(viewModel.lastMediaURL?.path == strandedPath)
        #expect(viewModel.errorMessage?.contains("preserved") == true)
    }

    @Test("unexpected recording finish resets state and keeps the saved media")
    @MainActor
    func unexpectedRecordingFinishResetsState() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        await viewModel.setMode(.video)
        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        let partialURL = tempRoot.appendingPathComponent("partial.mov")
        try Data().write(to: partialURL)
        mock.onRecordingFinishedUnexpectedly?(
            CapturedMedia(fileURL: partialURL, thumbnailFileURL: partialURL),
            CaptureServiceError.recordingNotInProgress
        )

        #expect(!viewModel.isRecording)
        #expect(viewModel.recordingStartedAt == nil)
        #expect(viewModel.lastMediaURL == partialURL)
        #expect(viewModel.errorMessage?.contains("unexpectedly") == true)
    }

    @Test("restart-required setting changes are deferred while recording and applied after stop")
    @MainActor
    func restartRequiredChangesAreDeferredDuringRecording() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let videoURL = tempRoot.appendingPathComponent("deferred.mov")
        try Data().write(to: videoURL)
        mock.videoOutputURL = videoURL

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        #expect(mock.applyCalls.count == 1)
        #expect(mock.startPreviewCalls == 1)

        // Mode switches restart the preview so the session can use the right preset.
        await viewModel.setMode(.video)
        #expect(mock.applyCalls.count == 2)
        #expect(mock.startPreviewCalls == 2)

        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)

        await viewModel.setVideoResolution(.hd720)
        await viewModel.setVideoFrameRate(.fps60)
        #expect(mock.applyCalls.count == 2)
        #expect(mock.startPreviewCalls == 2)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
        #expect(mock.stopRecordingCalls == 1)
        #expect(mock.applyCalls.count == 3)
        #expect(mock.startPreviewCalls == 3)
        #expect(mock.applyCalls.last?.videoResolution == .hd720)
        #expect(mock.applyCalls.last?.videoFrameRate == .fps60)
    }

    @Test("deferred reconfiguration refreshes inventory and recovers when camera id changes")
    @MainActor
    func deferredReconfigurationRecoversWhenCameraIDChanges() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oldInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-old", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )
        let newInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-new", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let mock = MockCaptureService()
        mock.discoveredInventory = oldInventory
        mock.discoveredInventorySequence = [oldInventory, newInventory]
        mock.enforceInputValidation = true

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        try store.replace(
            with: AppSettings(
                selectedInput: CaptureInputSelection(id: "cam-old", name: "FaceTime", type: .camera)
            )
        )
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)

        await viewModel.initialize()
        #expect(viewModel.settings.selectedInput?.id == "cam-old")
        #expect(mock.applyCalls.count == 1)

        await viewModel.setMode(.video)
        #expect(mock.applyCalls.count == 2)

        await viewModel.captureButtonPressed()
        await viewModel.setVideoResolution(.hd720)
        mock.applyErrors = [CaptureServiceError.cameraNotFound]

        await viewModel.captureButtonPressed()

        #expect(!viewModel.isRecording)
        #expect(viewModel.settings.selectedInput?.id == "cam-new")
        #expect(mock.stopRecordingCalls == 1)
        #expect(mock.applyCalls.count == 4)
        #expect(mock.applyCalls.last?.selectedInput?.id == "cam-new")
    }

    @Test("failed deferred reconfiguration rolls back to last working settings")
    @MainActor
    func failedDeferredReconfigurationRollsBackToLastWorkingSettings() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()
        #expect(viewModel.settings.videoResolution == .hd1080)
        #expect(viewModel.settings.videoFrameRate == .fps30)

        await viewModel.setMode(.video)
        await viewModel.captureButtonPressed()
        await viewModel.setVideoResolution(.uhd4k)
        await viewModel.setVideoFrameRate(.fps60)
        mock.applyErrors = [CaptureServiceError.cameraNotFound]

        await viewModel.captureButtonPressed()

        #expect(!viewModel.isRecording)
        #expect(mock.stopRecordingCalls == 1)
        #expect(viewModel.settings.videoResolution == .hd1080)
        #expect(viewModel.settings.videoFrameRate == .fps30)
        #expect(viewModel.errorMessage?.contains("Reverted") == true)
    }

    @Test("focus converts point to top-left normalized space")
    @MainActor
    func focusConvertsPointToNormalizedSpace() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()

        await viewModel.focus(at: CGPoint(x: 50, y: 25), in: CGSize(width: 100, height: 100))

        let point = try #require(mock.focusPoints.first)
        #expect(point.x == 0.5)
        #expect(point.y == 0.25)
        #expect(viewModel.focusIndicatorPoint == CGPoint(x: 50, y: 25))
    }

    @Test("initialize loads latest media from configured directory")
    @MainActor
    func initializeLoadsLatestMediaFromConfiguredDirectory() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mediaRoot = tempRoot.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)

        let oldPhoto = mediaRoot.appendingPathComponent("IMG_old.jpg")
        let newPhoto = mediaRoot.appendingPathComponent("IMG_new.jpg")
        try Data([0x01]).write(to: oldPhoto)
        try Data([0x02]).write(to: newPhoto)

        let oldDate = Date(timeIntervalSinceNow: -300)
        let newDate = Date(timeIntervalSinceNow: -10)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPhoto.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newPhoto.path)

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        try store.replace(
            with: AppSettings(
                mediaDestination: .photosDirectory,
                mediaDirectoryPath: mediaRoot.path
            )
        )

        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()

        #expect(viewModel.lastMediaURL?.standardizedFileURL == newPhoto.standardizedFileURL)
    }

    @Test("mobile devices are never chosen as defaults")
    @MainActor
    func mobileDevicesNeverDefault() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        // Mobile devices listed first to prove ordering isn't what saves us.
        mock.discoveredInventory = DeviceInventory(
            cameras: [
                DeviceDescriptor(id: "iphone-cam", name: "iPhone Camera", type: .camera),
                DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)
            ],
            microphones: [
                DeviceDescriptor(id: "iphone-mic", name: "iPhone Microphone", type: .microphone),
                DeviceDescriptor(id: "mic-1", name: "Built-in Mic", type: .microphone)
            ],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)],
            mobileDeviceIDs: ["iphone-cam", "iphone-mic"]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()

        #expect(viewModel.settings.selectedInput?.id == "cam-1")
        #expect(viewModel.settings.selectedAudioSources.first(where: { $0.id == "iphone-mic" })?.isEnabled == false)
        #expect(viewModel.settings.selectedAudioSources.first(where: { $0.id == "mic-1" })?.isEnabled == true)
    }

    @Test("migration disables a previously auto-enabled mobile microphone once")
    @MainActor
    func migrationDisablesAutoEnabledMobileMicrophone() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [
                DeviceDescriptor(id: "iphone-mic", name: "iPhone Microphone", type: .microphone),
                DeviceDescriptor(id: "mic-1", name: "Built-in Mic", type: .microphone)
            ],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)],
            mobileDeviceIDs: ["iphone-mic"]
        )

        // Old-build damage: the phone mic ended up enabled (audioDefaultsVersion 0).
        var phoneMic = AudioSourceSelection(id: "iphone-mic", name: "iPhone Microphone", kind: .microphone)
        phoneMic.isEnabled = true
        var builtIn = AudioSourceSelection(id: "mic-1", name: "Built-in Mic", kind: .microphone)
        builtIn.isEnabled = false

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        try store.replace(with: AppSettings(selectedAudioSources: [phoneMic, builtIn]))

        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()

        #expect(viewModel.settings.audioDefaultsVersion == 1)
        #expect(viewModel.settings.selectedAudioSources.first(where: { $0.id == "iphone-mic" })?.isEnabled == false)
        #expect(viewModel.settings.selectedAudioSources.first(where: { $0.id == "mic-1" })?.isEnabled == true)

        // A post-migration user choice of the phone mic is respected.
        await viewModel.setAudioSourceEnabled(id: "iphone-mic", isEnabled: true)
        await viewModel.refreshDevices()
        #expect(viewModel.settings.selectedAudioSources.first(where: { $0.id == "iphone-mic" })?.isEnabled == true)
    }

    @Test("rapid restart-required changes coalesce into one reconfiguration")
    @MainActor
    func rapidChangesCoalesceIntoOneReconfiguration() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(
            settingsStore: store,
            captureService: mock,
            previewRestartDebounce: .milliseconds(40)
        )

        await viewModel.initialize()
        await viewModel.setMode(.video)
        #expect(mock.applyCalls.count == 2)

        await viewModel.setVideoResolution(.hd720)
        await viewModel.setVideoFrameRate(.fps60)
        await viewModel.setVideoResolution(.uhd4k)
        #expect(mock.applyCalls.count == 2)

        try await Task.sleep(for: .milliseconds(400))
        #expect(mock.applyCalls.count == 3)
        #expect(mock.applyCalls.last?.videoResolution == .uhd4k)
        #expect(mock.applyCalls.last?.videoFrameRate == .fps60)
    }

    @Test("a pending debounced change is applied before recording starts")
    @MainActor
    func pendingChangeAppliedBeforeRecording() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-1", name: "FaceTime", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: tempRoot.appendingPathComponent("settings.json"))
        let viewModel = CameraViewModel(
            settingsStore: store,
            captureService: mock,
            previewRestartDebounce: .seconds(30)
        )

        await viewModel.initialize()
        await viewModel.setMode(.video)
        #expect(mock.applyCalls.count == 2)

        await viewModel.setVideoResolution(.hd720)
        #expect(mock.applyCalls.count == 2)

        await viewModel.captureButtonPressed()
        #expect(viewModel.isRecording)
        #expect(mock.applyCalls.count == 3)
        #expect(mock.applyCalls.last?.videoResolution == .hd720)
        #expect(mock.startRecordingCalls == 1)

        await viewModel.captureButtonPressed()
        #expect(!viewModel.isRecording)
    }

    @Test("reset all settings restores defaults and reapplies preview")
    @MainActor
    func resetAllSettingsRestoresDefaultsAndReappliesPreview() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let settingsURL = tempRoot.appendingPathComponent("settings.json")
        let mock = MockCaptureService()
        mock.discoveredInventory = DeviceInventory(
            cameras: [DeviceDescriptor(id: "cam-2", name: "External Cam", type: .camera)],
            microphones: [DeviceDescriptor(id: "mic-1", name: "Mic", type: .microphone)],
            audioOutputs: [DeviceDescriptor(id: "out-1", name: "Output", type: .systemAudioOutput)]
        )

        let store = SettingsStore(fileURL: settingsURL)
        try store.replace(
            with: AppSettings(
                mode: .video,
                photoQuality: .standard,
                photoFormat: .jpeg,
                videoResolution: .uhd4k,
                videoFrameRate: .fps60,
                mediaDestination: .photoLibrary,
                mediaDirectoryPath: tempRoot.appendingPathComponent("custom-media").path,
                selectedInput: CaptureInputSelection(id: "missing-cam", name: "Missing", type: .camera),
                selectedAudioSources: []
            )
        )

        let viewModel = CameraViewModel(settingsStore: store, captureService: mock)
        await viewModel.initialize()
        #expect(mock.applyCalls.count == 1)
        #expect(mock.startPreviewCalls == 1)

        await viewModel.resetAllSettings()

        #expect(viewModel.settings.mode == .photo)
        #expect(viewModel.settings.photoQuality == .high)
        #expect(viewModel.settings.photoFormat == .heic)
        #expect(viewModel.settings.videoResolution == .hd1080)
        #expect(viewModel.settings.videoFrameRate == .fps30)
        #expect(viewModel.settings.mediaDestination == .photosDirectory)
        #expect(viewModel.settings.mediaDirectoryPath == AppSettings.defaultMediaDirectoryPath)
        #expect(viewModel.settings.windowOptions.hideTitleBar == false)
        #expect(viewModel.settings.windowOptions.allowBackgroundDrag == false)
        #expect(viewModel.settings.selectedInput?.id == "cam-2")
        #expect(viewModel.settings.selectedAudioSources.contains(where: { $0.kind == .microphone && $0.isEnabled }))
        #expect(mock.applyCalls.count == 2)
        #expect(mock.startPreviewCalls == 2)

        let verifyStore = SettingsStore(fileURL: settingsURL)
        try verifyStore.load()
        #expect(verifyStore.settings.mode == .photo)
        #expect(verifyStore.settings.videoResolution == .hd1080)
        #expect(verifyStore.settings.mediaDestination == .photosDirectory)
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
