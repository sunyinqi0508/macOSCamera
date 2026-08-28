import AppKit
@preconcurrency import AVFoundation
import CameraCore
import CoreAudio
import Foundation

struct CapturePermissions: Sendable, Equatable {
    var cameraGranted: Bool
    var microphoneGranted: Bool
}

struct AppliedCaptureConfiguration: Sendable, Equatable {
    var videoAspectRatio: CGFloat?
}

/// The outcome of a capture: where the media landed and what to build its thumbnail from.
struct CapturedMedia: Sendable, Equatable {
    /// User-visible file; `nil` when the media was saved to the Photos library.
    var fileURL: URL?
    /// File to derive the thumbnail from (may be a temporary file for library saves).
    var thumbnailFileURL: URL?
    /// In-memory image data for the thumbnail when no file remains on disk.
    var thumbnailData: Data?

    init(fileURL: URL? = nil, thumbnailFileURL: URL? = nil, thumbnailData: Data? = nil) {
        self.fileURL = fileURL
        self.thumbnailFileURL = thumbnailFileURL
        self.thumbnailData = thumbnailData
    }
}

@MainActor
protocol CaptureServiceProtocol: AnyObject {
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    /// Invoked when a recording ends without a stop request (device unplugged, disk
    /// error, …). The partial file is persisted when possible and passed along.
    var onRecordingFinishedUnexpectedly: ((CapturedMedia?, Error?) -> Void)? { get set }
    func requestPermissions() async -> CapturePermissions
    func discoverDevices() async -> DeviceInventory
    @discardableResult
    func apply(settings: AppSettings) async throws -> AppliedCaptureConfiguration
    func startPreview() async
    func stopPreview() async
    func capturePhoto(with settings: AppSettings) async throws -> CapturedMedia
    func startRecording(with settings: AppSettings) async throws
    func stopRecording(with settings: AppSettings) async throws -> CapturedMedia
    func setFocusAndExposure(normalizedPoint: CGPoint) async throws
}

enum CaptureServiceError: LocalizedError, Equatable {
    case cameraNotFound
    case cameraUnavailable
    case screenNotFound
    case missingInputSource
    case photoCaptureUnavailable
    case photoCaptureTimedOut
    case failedToEncodeImage
    case recordingNotInProgress
    case recordingStartTimedOut
    case videoRecordingUnavailable
    case videoPersistenceFailed(tempPath: String)
    case photoLibraryPermissionDenied

    var errorDescription: String? {
        switch self {
        case .cameraNotFound:
            return "Could not find the selected camera device."
        case .cameraUnavailable:
            return "The selected camera is unavailable. It may be in use by another app."
        case .screenNotFound:
            return "Could not find the selected screen source."
        case .missingInputSource:
            return "Select a camera or screen input first."
        case .photoCaptureUnavailable:
            return "Photo capture is unavailable for the current source."
        case .photoCaptureTimedOut:
            return "The photo capture timed out."
        case .failedToEncodeImage:
            return "Failed to encode captured image data."
        case .recordingNotInProgress:
            return "Recording is not in progress."
        case .recordingStartTimedOut:
            return "The recording could not be started."
        case .videoRecordingUnavailable:
            return "Video recording is unavailable for the current configuration."
        case .videoPersistenceFailed(let tempPath):
            return "The recording could not be saved to its destination. The video is preserved at \(tempPath)."
        case .photoLibraryPermissionDenied:
            return "Photo library permission was denied."
        }
    }
}

@MainActor
final class CaptureService: CaptureServiceProtocol {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onRecordingFinishedUnexpectedly: ((CapturedMedia?, Error?) -> Void)?

    private let runner = CaptureSessionRunner()
    private let mediaPersistence = MediaPersistence()
    private let pathResolver = MediaPathResolver()

    private var appliedSourceType: CaptureInputSourceType = .camera
    private var appliedDisplayID: CGDirectDisplayID?

    // Photo capture bookkeeping: keyed so overlapping captures can't clobber each other.
    private var photoContinuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private var photoDelegates: [Int: PhotoCaptureDelegate] = [:]
    private var nextPhotoCaptureID = 0

    // Recording bookkeeping, driven by an explicit phase so a finish that arrives at
    // any moment (including with no stop request) is handled exactly once.
    private enum RecordingPhase {
        case idle
        case starting
        case active
        case stopping
    }

    private var recordingPhase: RecordingPhase = .idle
    private var recordingStartContinuation: CheckedContinuation<Void, Error>?
    private var recordingStopContinuation: CheckedContinuation<URL, Error>?
    private var recordingDelegate: MovieRecordingDelegate?
    private var activeRecordingSettings: AppSettings?
    private var recordingStartedBeforeContinuation = false
    private var pendingRecordingStartFailure: Error?
    /// Incremented for every start attempt; delegate callbacks and timeout tasks
    /// carry the id they were created for and are ignored once superseded.
    private var recordingAttemptID = 0

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: runner.session)
        previewLayer.videoGravity = .resizeAspect
    }

    func requestPermissions() async -> CapturePermissions {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return CapturePermissions(cameraGranted: camera, microphoneGranted: microphone)
    }

    func discoverDevices() async -> DeviceInventory {
        // Screens are enumerated on the main actor (AppKit); the rest off it.
        let screens: [DeviceDescriptor] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return DeviceDescriptor(
                id: String(number.uint32Value),
                name: screen.localizedName,
                type: .screen
            )
        }

        let mediaDevices = await DeviceDiscovery.mediaDevices()

        return DeviceInventory(
            cameras: mediaDevices.cameras,
            screens: screens,
            microphones: mediaDevices.microphones,
            audioOutputs: mediaDevices.audioOutputs,
            mobileDeviceIDs: mediaDevices.mobileDeviceIDs
        )
    }

    @discardableResult
    func apply(settings: AppSettings) async throws -> AppliedCaptureConfiguration {
        let applied = try await runner.configure(settings: settings)

        appliedSourceType = settings.selectedInput?.type ?? .camera
        appliedDisplayID = settings.selectedInput.flatMap { input in
            input.type == .screen ? UInt32(input.id) : nil
        }
        updatePreviewMirroring()

        return applied
    }

    func startPreview() async {
        await runner.startRunning()
    }

    func stopPreview() async {
        await runner.stopRunning()
    }

    func capturePhoto(with settings: AppSettings) async throws -> CapturedMedia {
        switch appliedSourceType {
        case .camera:
            var requestHEVC = false
            if settings.photoFormat == .heic {
                requestHEVC = await runner.supportsHEVCPhotoCapture()
            }
            let data = try await captureCameraPhotoDataWithWarmupRetry(
                requestHEVC: requestHEVC,
                quality: settings.photoQuality
            )
            let encoded = await PhotoEncoding.finalizeCameraPhoto(
                data: data,
                capturedCodecIsHEVC: requestHEVC,
                format: settings.photoFormat,
                quality: settings.photoQuality
            )

            let destination = pathResolver
                .nextPhotoURL(for: settings)
                .deletingPathExtension()
                .appendingPathExtension(encoded.fileExtension)
            return try await mediaPersistence.persistPhoto(
                data: encoded.data,
                destinationURL: destination,
                destination: settings.mediaDestination
            )

        case .screen:
            guard let displayID = appliedDisplayID else {
                throw CaptureServiceError.screenNotFound
            }

            let encoded = try await PhotoEncoding.captureScreenPhoto(
                displayID: displayID,
                format: settings.photoFormat,
                quality: settings.photoQuality
            )

            let destination = pathResolver
                .nextPhotoURL(for: settings)
                .deletingPathExtension()
                .appendingPathExtension(encoded.fileExtension)
            return try await mediaPersistence.persistPhoto(
                data: encoded.data,
                destinationURL: destination,
                destination: settings.mediaDestination
            )
        }
    }

    func startRecording(with settings: AppSettings) async throws {
        guard recordingPhase == .idle else {
            throw CaptureServiceError.videoRecordingUnavailable
        }

        // Claim the phase before any suspension so a re-entrant call can't share
        // the single continuation slot.
        recordingPhase = .starting
        recordingAttemptID += 1
        let attemptID = recordingAttemptID
        recordingStartedBeforeContinuation = false
        pendingRecordingStartFailure = nil
        activeRecordingSettings = settings

        // Wait out the brief window after a session (re)start where connections
        // report inactive, so recording right after a mode switch just works.
        var connectionReady = await runner.hasActiveMovieConnection()
        var warmupAttempts = 0
        while !connectionReady, warmupAttempts < 10 {
            try? await Task.sleep(for: .milliseconds(150))
            connectionReady = await runner.hasActiveMovieConnection()
            warmupAttempts += 1
        }

        guard connectionReady else {
            recordingPhase = .idle
            activeRecordingSettings = nil
            throw CaptureServiceError.videoRecordingUnavailable
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbCamera-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let delegate = MovieRecordingDelegate(
            onStart: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRecordingStarted(attemptID: attemptID)
                }
            },
            onFinish: { [weak self] outputURL, error in
                Task { @MainActor [weak self] in
                    self?.handleRecordingFinished(attemptID: attemptID, url: outputURL, error: error)
                }
            }
        )
        recordingDelegate = delegate

        await runner.startMovieRecording(to: tempURL, delegate: delegate)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if recordingStartedBeforeContinuation {
                recordingStartedBeforeContinuation = false
                continuation.resume(returning: ())
                return
            }

            if let failure = pendingRecordingStartFailure {
                pendingRecordingStartFailure = nil
                continuation.resume(throwing: failure)
                return
            }

            recordingStartContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.failPendingRecordingStart(attemptID: attemptID)
            }
        }
    }

    func stopRecording(with settings: AppSettings) async throws -> CapturedMedia {
        guard recordingPhase == .active else {
            throw CaptureServiceError.recordingNotInProgress
        }

        recordingPhase = .stopping
        let attemptID = recordingAttemptID
        let recordedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            recordingStopContinuation = continuation
            Task { [runner] in
                await runner.stopMovieRecording()
            }
            // Backstop: never leave the UI stranded if the finish callback is lost.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.failPendingRecordingStop(attemptID: attemptID)
            }
        }

        let destinationURL = pathResolver.nextVideoURL(for: settings)
        do {
            return try await mediaPersistence.persistVideo(
                sourceURL: recordedURL,
                destinationURL: destinationURL,
                destination: settings.mediaDestination
            )
        } catch {
            // The movie exists; never lose the only reference to it.
            throw CaptureServiceError.videoPersistenceFailed(tempPath: recordedURL.path)
        }
    }

    /// `normalizedPoint` uses top-left-origin view coordinates in [0, 1].
    func setFocusAndExposure(normalizedPoint: CGPoint) async throws {
        guard appliedSourceType == .camera else {
            return
        }

        var devicePoint = CGPoint(
            x: max(0.0, min(1.0, normalizedPoint.x)),
            y: max(0.0, min(1.0, normalizedPoint.y))
        )

        // The preview is mirrored for cameras; the sensor is not.
        if previewLayer.connection?.isVideoMirrored == true {
            devicePoint.x = 1.0 - devicePoint.x
        }

        try await runner.focus(devicePoint: devicePoint)
    }

    // MARK: - Recording lifecycle

    private func handleRecordingStarted(attemptID: Int) {
        guard attemptID == recordingAttemptID, recordingPhase == .starting else {
            return
        }

        recordingPhase = .active
        if let continuation = recordingStartContinuation {
            recordingStartContinuation = nil
            continuation.resume(returning: ())
        } else {
            recordingStartedBeforeContinuation = true
        }
    }

    private func handleRecordingFinished(attemptID: Int, url: URL, error: Error?) {
        guard attemptID == recordingAttemptID else {
            // A superseded attempt's delegate; its temp file stays in the
            // system-purged temporary directory.
            return
        }

        switch recordingPhase {
        case .idle:
            break

        case .starting:
            // The recording failed to start (or died instantly).
            let failure = error ?? CaptureServiceError.recordingStartTimedOut
            if let continuation = recordingStartContinuation {
                recordingStartContinuation = nil
                continuation.resume(throwing: failure)
            } else {
                pendingRecordingStartFailure = failure
            }
            clearRecordingState()

        case .stopping:
            let continuation = recordingStopContinuation
            recordingStopContinuation = nil
            clearRecordingState()

            if let error, !Self.recordingFileIsUsable(after: error) {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: url)
            }

        case .active:
            // Unsolicited finish: device unplugged, disk full, display disconnected, …
            let settings = activeRecordingSettings
            clearRecordingState()

            guard let settings else {
                return
            }

            let fileUsable = error == nil
                || Self.recordingFileIsUsable(after: error!)
                || FileManager.default.fileExists(atPath: url.path)

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                var media: CapturedMedia?
                if fileUsable {
                    let destinationURL = self.pathResolver.nextVideoURL(for: settings)
                    media = try? await self.mediaPersistence.persistVideo(
                        sourceURL: url,
                        destinationURL: destinationURL,
                        destination: settings.mediaDestination
                    )
                }
                self.onRecordingFinishedUnexpectedly?(media, error)
            }
        }
    }

    private func failPendingRecordingStart(attemptID: Int) {
        guard attemptID == recordingAttemptID,
              recordingPhase == .starting,
              let continuation = recordingStartContinuation else {
            return
        }

        recordingStartContinuation = nil
        clearRecordingState()
        Task { [runner] in
            await runner.stopMovieRecording()
        }
        continuation.resume(throwing: CaptureServiceError.recordingStartTimedOut)
    }

    private func failPendingRecordingStop(attemptID: Int) {
        guard attemptID == recordingAttemptID,
              recordingPhase == .stopping,
              let continuation = recordingStopContinuation else {
            return
        }

        recordingStopContinuation = nil
        clearRecordingState()
        continuation.resume(throwing: CaptureServiceError.recordingNotInProgress)
    }

    private func clearRecordingState() {
        recordingPhase = .idle
        recordingDelegate = nil
        activeRecordingSettings = nil
    }

    /// AVFoundation reports some interruptions as errors even though the movie file
    /// on disk is complete and playable.
    private static func recordingFileIsUsable(after error: Error) -> Bool {
        ((error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
    }

    // MARK: - Photo capture

    /// The photo connection reports inactive for a moment right after the session
    /// (re)starts; retry briefly so a shutter press during warm-up still lands.
    private func captureCameraPhotoDataWithWarmupRetry(requestHEVC: Bool, quality: PhotoQuality) async throws -> Data {
        let maxAttempts = 10
        for attempt in 1...maxAttempts {
            do {
                return try await captureCameraPhotoData(requestHEVC: requestHEVC, quality: quality)
            } catch let error as CaptureServiceError where error == .photoCaptureUnavailable && attempt < maxAttempts {
                try await Task.sleep(for: .milliseconds(150))
            }
        }

        throw CaptureServiceError.photoCaptureUnavailable
    }

    private func captureCameraPhotoData(requestHEVC: Bool, quality: PhotoQuality) async throws -> Data {
        let captureID = nextPhotoCaptureID
        nextPhotoCaptureID += 1

        let delegate = PhotoCaptureDelegate { [weak self] result in
            Task { @MainActor [weak self] in
                self?.resolvePhotoCapture(id: captureID, with: result)
            }
        }
        photoDelegates[captureID] = delegate

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            photoContinuations[captureID] = continuation

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    try await self.runner.capturePhoto(requestHEVC: requestHEVC, quality: quality, delegate: delegate)
                } catch {
                    self.resolvePhotoCapture(id: captureID, with: .failure(error))
                    return
                }

                try? await Task.sleep(for: .seconds(10))
                self.resolvePhotoCapture(id: captureID, with: .failure(CaptureServiceError.photoCaptureTimedOut))
            }
        }
    }

    private func resolvePhotoCapture(id: Int, with result: Result<Data, Error>) {
        guard let continuation = photoContinuations.removeValue(forKey: id) else {
            return
        }
        photoDelegates[id] = nil
        continuation.resume(with: result)
    }

    // MARK: - Preview helpers

    private func updatePreviewMirroring() {
        applyPreviewMirroring()
        // The layer's connection is rebuilt asynchronously after configuration
        // changes; retry once so mirroring never silently stays off.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.applyPreviewMirroring()
        }
    }

    private func applyPreviewMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else {
            return
        }

        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = appliedSourceType == .camera
    }
}

// MARK: - Session runner

/// Owns the capture graph and confines every mutation to one serial queue so the
/// main thread never blocks on `AVCaptureSession` work (Apple documents
/// `startRunning()`/configuration as blocking calls).
private final class CaptureSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.yurika.mbCamera.capture-session")

    private var activeVideoDevice: AVCaptureDevice?

    func configure(settings: AppSettings) async throws -> AppliedCaptureConfiguration {
        try await performThrowing { [self] in
            try configureOnQueue(settings: settings)
        }
    }

    func startRunning() async {
        await perform { [self] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stopRunning() async {
        await perform { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func supportsHEVCPhotoCapture() async -> Bool {
        await perform { [self] in
            session.outputs.contains(photoOutput)
                && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        }
    }

    func capturePhoto(requestHEVC: Bool, quality: PhotoQuality, delegate: PhotoCaptureDelegate) async throws {
        try await performThrowing { [self] in
            // capturePhoto(with:delegate:) raises an Objective-C exception when the
            // output has no active connection (e.g. the session is still spinning
            // up); fail cleanly instead so the caller can retry.
            guard session.outputs.contains(photoOutput),
                  photoOutput.connections.contains(where: { $0.isEnabled && $0.isActive }) else {
                throw CaptureServiceError.photoCaptureUnavailable
            }

            let settings: AVCapturePhotoSettings
            if requestHEVC, photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }

            let requested = Self.qualityPrioritization(for: quality)
            let ceiling = photoOutput.maxPhotoQualityPrioritization
            settings.photoQualityPrioritization = requested.rawValue <= ceiling.rawValue ? requested : ceiling

            let maxDimensions = photoOutput.maxPhotoDimensions
            if maxDimensions.width > 0, maxDimensions.height > 0 {
                settings.maxPhotoDimensions = maxDimensions
            }

            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func hasActiveMovieConnection() async -> Bool {
        await perform { [self] in
            session.outputs.contains(movieOutput)
                && movieOutput.connections.contains { $0.isEnabled && $0.isActive }
        }
    }

    func startMovieRecording(to url: URL, delegate: MovieRecordingDelegate) async {
        await perform { [self] in
            // Silently skipping here is safe: the caller's start timeout unwinds it.
            // Starting with no attached output or active connection would raise an
            // Objective-C exception and crash.
            guard session.outputs.contains(movieOutput),
                  movieOutput.connections.contains(where: { $0.isEnabled && $0.isActive }),
                  !movieOutput.isRecording else {
                return
            }
            movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func stopMovieRecording() async {
        await perform { [self] in
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
        }
    }

    func focus(devicePoint: CGPoint) async throws {
        try await performThrowing { [self] in
            guard let device = activeVideoDevice,
                  device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported else {
                return
            }

            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    // MARK: Queue-confined configuration

    private func configureOnQueue(settings: AppSettings) throws -> AppliedCaptureConfiguration {
        guard let selectedInput = settings.selectedInput else {
            throw CaptureServiceError.missingInputSource
        }

        session.beginConfiguration()
        var aspectRatio: CGFloat?
        do {
            aspectRatio = try rebuildGraphOnQueue(settings: settings, selectedInput: selectedInput)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()

        // Post-commit: the device's active format is now final, so the frame rate can
        // be applied against real capabilities and the aspect ratio read back.
        if let device = activeVideoDevice {
            if settings.mode == .video {
                applyFrameRate(settings.videoFrameRate, to: device)
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            if dimensions.height > 0 {
                aspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            }

            if session.outputs.contains(photoOutput),
               let best = device.activeFormat.supportedMaxPhotoDimensions
                   .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = best
            }
        }

        return AppliedCaptureConfiguration(videoAspectRatio: aspectRatio)
    }

    /// Runs between `beginConfiguration`/`commitConfiguration`; returns the aspect
    /// ratio when it is already known (screen sources).
    private func rebuildGraphOnQueue(
        settings: AppSettings,
        selectedInput: CaptureInputSelection
    ) throws -> CGFloat? {
        for input in session.inputs {
            session.removeInput(input)
        }

        for output in session.outputs {
            session.removeOutput(output)
        }

        activeVideoDevice = nil

        // Neutral preset first so input compatibility isn't judged against a stale,
        // possibly unsupported preset (the root cause of the old "camera not found"
        // failures after resolution changes).
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        var aspectRatio: CGFloat?

        switch selectedInput.type {
        case .camera:
            guard let device = DeviceDiscovery.videoDiscoverySession().devices
                .first(where: { $0.uniqueID == selectedInput.id }) else {
                throw CaptureServiceError.cameraNotFound
            }

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureServiceError.cameraUnavailable
            }
            session.addInput(input)
            activeVideoDevice = device

            // Choose the best preset the attached device actually supports.
            for preset in Self.presetLadder(mode: settings.mode, resolution: settings.videoResolution)
            where session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }

            photoOutput.maxPhotoQualityPrioritization = .quality
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }

        case .screen:
            guard let displayID = UInt32(selectedInput.id),
                  let screenInput = AVCaptureScreenInput(displayID: displayID) else {
                throw CaptureServiceError.screenNotFound
            }

            screenInput.minFrameDuration = CMTime(value: 1, timescale: Int32(settings.videoFrameRate.rawValue))
            screenInput.capturesCursor = true

            guard session.canAddInput(screenInput) else {
                throw CaptureServiceError.screenNotFound
            }
            session.addInput(screenInput)

            let bounds = CGDisplayBounds(displayID)
            if bounds.height > 0 {
                aspectRatio = bounds.width / bounds.height
            }
        }

        attachAudioInputsIfNeeded(settings: settings, sourceType: selectedInput.type)

        // The movie output is only part of the graph in video mode; photo mode can
        // then use the sensor's native photo format (iPhone-style 4:3 stills).
        if settings.mode == .video {
            guard session.canAddOutput(movieOutput) else {
                throw CaptureServiceError.videoRecordingUnavailable
            }
            session.addOutput(movieOutput)
        }

        return aspectRatio
    }

    private func attachAudioInputsIfNeeded(settings: AppSettings, sourceType: CaptureInputSourceType) {
        // Screen recordings can opt out of microphone audio entirely.
        if sourceType == .screen, !settings.screenRecording.includeMicrophoneAudio {
            return
        }

        let enabledMicrophones = settings.selectedAudioSources.filter {
            $0.isEnabled && $0.kind == .microphone
        }

        var attachedAny = false
        if !enabledMicrophones.isEmpty {
            let audioDevices = DeviceDiscovery.audioDiscoverySession().devices
            for selection in enabledMicrophones {
                guard let device = audioDevices.first(where: { $0.uniqueID == selection.id }),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    continue
                }
                session.addInput(input)
                attachedAny = true
            }
        }

        // Fall back to a (never mobile-backed) microphone when an enabled device
        // disappeared, or when no microphone selections exist yet. Deliberately
        // disabling every microphone stays respected (no audio is attached).
        let hasMicrophoneSelections = settings.selectedAudioSources.contains { $0.kind == .microphone }
        if !attachedAny, !enabledMicrophones.isEmpty || !hasMicrophoneSelections {
            if let fallback = DeviceDiscovery.fallbackMicrophone(),
               let input = try? AVCaptureDeviceInput(device: fallback),
               session.canAddInput(input) {
                session.addInput(input)
            }
        }
    }

    private func applyFrameRate(_ frameRate: VideoFrameRate, to device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let supported = ranges.map { $0.minFrameRate...$0.maxFrameRate }

        guard let resolved = FrameRatePlanner.resolve(requested: frameRate.rawValue, supported: supported) else {
            return
        }

        // When the planner clamped to a range boundary, use that range's exact
        // rational CMTime: rebuilding 29.97/59.94 from a rounded integer would
        // produce a duration outside every supported range and raise an
        // Objective-C exception when set.
        let epsilon = 0.001
        var duration = CMTime(value: 1, timescale: Int32(resolved.rounded()))
        if let boundary = ranges.first(where: { abs($0.maxFrameRate - resolved) < epsilon }) {
            duration = boundary.minFrameDuration
        } else if let boundary = ranges.first(where: { abs($0.minFrameRate - resolved) < epsilon }) {
            duration = boundary.maxFrameDuration
        }

        // Final gate: never set a duration no range accepts.
        guard ranges.contains(where: {
            CMTimeCompare(duration, $0.minFrameDuration) >= 0
                && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
        }) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // Frame rate is best-effort; the session still runs at the default rate.
        }
    }

    private static func presetLadder(mode: CaptureMode, resolution: VideoResolution) -> [AVCaptureSession.Preset] {
        switch mode {
        case .photo:
            return [.photo, .high, .hd1920x1080, .hd1280x720]
        case .video:
            switch resolution {
            case .uhd4k:
                return [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            case .hd1080:
                return [.hd1920x1080, .hd1280x720, .high]
            case .hd720:
                return [.hd1280x720, .hd1920x1080, .high]
            }
        }
    }

    private static func qualityPrioritization(for quality: PhotoQuality) -> AVCapturePhotoOutput.QualityPrioritization {
        switch quality {
        case .standard:
            return .speed
        case .high:
            return .balanced
        case .max:
            return .quality
        }
    }

    // MARK: Queue bridging

    private func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func performThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}

// MARK: - Device discovery

enum DeviceDiscovery {
    struct MediaDevices: Sendable {
        var cameras: [DeviceDescriptor]
        var microphones: [DeviceDescriptor]
        var audioOutputs: [DeviceDescriptor]
        var mobileDeviceIDs: Set<String>
    }

    /// True for devices backed by an iPhone/iPad (Continuity Camera and its
    /// microphone). Selecting one triggers a live connection to the phone, so they
    /// are supported as sources but must never be picked automatically.
    static func isMobileBackedDevice(_ device: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *), device.deviceType == .continuityCamera {
            return true
        }
        if device.deviceType == .deskViewCamera {
            return true
        }

        let model = device.modelID.lowercased()
        let name = device.localizedName.lowercased()
        return model.contains("iphone") || model.contains("ipad")
            || name.contains("iphone") || name.contains("ipad")
    }

    /// Enumerates AVFoundation and CoreAudio devices off the main actor. Devices
    /// are ordered non-mobile first so "pick the first" defaults never land on a
    /// phone; mobile-backed ids are reported alongside.
    static func mediaDevices() async -> MediaDevices {
        var mobileIDs: Set<String> = []

        let cameraDevices = videoDiscoverySession().devices
        for device in cameraDevices where isMobileBackedDevice(device) {
            mobileIDs.insert(device.uniqueID)
        }
        let cameras = cameraDevices
            .sortedNonMobileFirst()
            .map { DeviceDescriptor(id: $0.uniqueID, name: $0.localizedName, type: .camera) }

        var microphoneDevices = audioDiscoverySession().devices
        for device in microphoneDevices where isMobileBackedDevice(device) {
            mobileIDs.insert(device.uniqueID)
        }

        // Keep the system-default microphone first — unless it is mobile-backed.
        if let defaultDevice = AVCaptureDevice.default(for: .audio),
           !isMobileBackedDevice(defaultDevice),
           let index = microphoneDevices.firstIndex(where: { $0.uniqueID == defaultDevice.uniqueID }),
           index != 0 {
            microphoneDevices.insert(microphoneDevices.remove(at: index), at: 0)
        }
        let microphones = microphoneDevices
            .sortedNonMobileFirst()
            .map { DeviceDescriptor(id: $0.uniqueID, name: $0.localizedName, type: .microphone) }

        return MediaDevices(
            cameras: cameras,
            microphones: microphones,
            audioOutputs: AudioOutputDiscovery.discover(),
            mobileDeviceIDs: mobileIDs
        )
    }

    /// The microphone to fall back to when no explicit selection is usable —
    /// never a mobile-backed device unless nothing else exists.
    static func fallbackMicrophone() -> AVCaptureDevice? {
        if let systemDefault = AVCaptureDevice.default(for: .audio),
           !isMobileBackedDevice(systemDefault) {
            return systemDefault
        }

        let devices = audioDiscoverySession().devices
        return devices.first { !isMobileBackedDevice($0) } ?? devices.first
    }

    /// The camera to use when no specific one was chosen (e.g. the PiP overlay) —
    /// never a mobile-backed device unless nothing else exists.
    static func fallbackCamera() -> AVCaptureDevice? {
        let devices = videoDiscoverySession().devices
        return devices.first { !isMobileBackedDevice($0) } ?? devices.first
    }

    static func videoDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .deskViewCamera
        ]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.continuityCamera, .external])
        } else {
            types.append(.externalUnknown)
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
    }

    static func audioDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        )
    }
}

private extension Array where Element == AVCaptureDevice {
    /// Stable partition: non-mobile devices keep their order, ahead of mobile ones.
    func sortedNonMobileFirst() -> [AVCaptureDevice] {
        let nonMobile = filter { !DeviceDiscovery.isMobileBackedDevice($0) }
        let mobile = filter { DeviceDiscovery.isMobileBackedDevice($0) }
        return nonMobile + mobile
    }
}

// MARK: - Capture delegates

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let onComplete: @Sendable (Result<Data, Error>) -> Void

    init(onComplete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            onComplete(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            onComplete(.failure(CaptureServiceError.failedToEncodeImage))
            return
        }

        onComplete(.success(data))
    }
}

private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, Sendable {
    private let onStart: @Sendable () -> Void
    private let onComplete: @Sendable (URL, Error?) -> Void

    init(
        onStart: @escaping @Sendable () -> Void,
        onFinish: @escaping @Sendable (URL, Error?) -> Void
    ) {
        self.onStart = onStart
        self.onComplete = onFinish
        super.init()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onStart()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        onComplete(outputFileURL, error)
    }
}

// MARK: - CoreAudio output discovery

private enum AudioOutputDiscovery {
    static func discover() -> [DeviceDescriptor] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return [fallbackSystemOutput()]
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return [fallbackSystemOutput()]
        }

        let outputs = deviceIDs.compactMap { deviceID -> DeviceDescriptor? in
            guard hasOutputChannels(deviceID) else {
                return nil
            }

            let name = deviceName(deviceID) ?? "Output \(deviceID)"
            return DeviceDescriptor(
                id: String(deviceID),
                name: name,
                type: .systemAudioOutput
            )
        }

        return outputs.isEmpty ? [fallbackSystemOutput()] : outputs
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferList
        ) == noErr else {
            return false
        }

        let audioBufferList = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channelCount = buffers.reduce(0) { partial, buffer in
            partial + Int(buffer.mNumberChannels)
        }

        return channelCount > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr else {
            return nil
        }

        return name as String?
    }

    private static func fallbackSystemOutput() -> DeviceDescriptor {
        DeviceDescriptor(id: "system.default.output", name: "System Output", type: .systemAudioOutput)
    }
}
