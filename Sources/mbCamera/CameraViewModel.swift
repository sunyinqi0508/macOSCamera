import AppKit
import AVFoundation
import CameraCore
import Foundation
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var settings: AppSettings = .default
    @Published var inventory: DeviceInventory = DeviceInventory()
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var isCapturingPhoto = false
    @Published var isInitialized = false
    @Published var lastMediaURL: URL?
    @Published var lastMediaIsInPhotoLibrary = false
    @Published var lastThumbnail: NSImage?
    @Published var focusIndicatorPoint: CGPoint?
    @Published var errorMessage: String?
    @Published var isSettingsPresented = false
    /// Aspect ratio of the frames the session actually delivers, so the preview
    /// window matches the real content instead of a guess.
    @Published var activeVideoAspectRatio: CGFloat?

    var previewLayer: AVCaptureVideoPreviewLayer {
        captureService.previewLayer
    }

    private var stateMachine = CaptureStateMachine()
    private let settingsStore: SettingsStore
    private let captureService: CaptureServiceProtocol
    private var hasDeferredPreviewReconfiguration = false
    private var lastAppliedSettings: AppSettings?
    private var persistDebounceTask: Task<Void, Never>?
    private var focusIndicatorResetTask: Task<Void, Never>?
    private var deviceRevalidationTask: Task<Void, Never>?
    private var previewRestartTask: Task<Void, Never>?
    private let previewRestartDebounce: Duration
    private var thumbnailGeneration = 0
    private var notificationObservers: [NSObjectProtocol] = []
    private var isTogglingRecording = false

    init(
        settingsStore: SettingsStore = SettingsStore(),
        captureService: CaptureServiceProtocol = CaptureService(),
        previewRestartDebounce: Duration = .milliseconds(600)
    ) {
        self.settingsStore = settingsStore
        self.captureService = captureService
        self.previewRestartDebounce = previewRestartDebounce
    }

    func initialize() async {
        if isInitialized {
            // The window was reopened; the session just needs to resume.
            await captureService.startPreview()
            return
        }

        captureService.onRecordingFinishedUnexpectedly = { [weak self] media, error in
            self?.handleUnexpectedRecordingFinish(media: media, error: error)
        }

        let permissions = await captureService.requestPermissions()
        if !permissions.cameraGranted {
            errorMessage = "Camera access is denied. Enable it in System Settings → Privacy & Security → Camera to see a preview."
        } else if !permissions.microphoneGranted {
            errorMessage = "Microphone access is denied. Recordings will have no audio unless it is enabled in System Settings → Privacy & Security → Microphone."
        }

        do {
            try settingsStore.load()
            settings = settingsStore.settings
        } catch {
            errorMessage = error.localizedDescription
        }

        resolveMediaDirectoryBookmark()
        await refreshInventory()
        ensureSelectionsAreValid()
        await loadLatestMediaPreviewFromMediaDirectory()

        do {
            try await applyPreviewConfigurationWithRollbackIfNeeded()
            isInitialized = true
        } catch {
            errorMessage = error.localizedDescription
        }

        registerNotificationObservers()
    }

    func refreshInventory() async {
        inventory = await captureService.discoverDevices()
    }

    /// Refreshes device lists and reconciles selections; used when the settings
    /// sheet opens so it always shows what is currently connected.
    func refreshDevices() async {
        await revalidateDevices()
    }

    func setMode(_ mode: CaptureMode) async {
        guard !isRecording, settings.mode != mode else {
            return
        }
        await mutateSettings(restart: .immediate) { $0.mode = mode }
    }

    func setPhotoFormat(_ format: PhotoFormat) async {
        guard settings.photoFormat != format else {
            return
        }
        await mutateSettings() { $0.photoFormat = format }
    }

    func setPhotoQuality(_ quality: PhotoQuality) async {
        guard settings.photoQuality != quality else {
            return
        }
        await mutateSettings() { $0.photoQuality = quality }
    }

    func setVideoResolution(_ resolution: VideoResolution) async {
        guard settings.videoResolution != resolution else {
            return
        }
        await mutateSettings(restart: .debounced) { $0.videoResolution = resolution }
    }

    func setVideoFrameRate(_ frameRate: VideoFrameRate) async {
        guard settings.videoFrameRate != frameRate else {
            return
        }
        await mutateSettings(restart: .debounced) { $0.videoFrameRate = frameRate }
    }

    func setMediaDestination(_ destination: MediaDestination) async {
        guard settings.mediaDestination != destination else {
            return
        }
        await mutateSettings() { $0.mediaDestination = destination }
    }

    func setMediaDirectory(path: String) async {
        guard settings.mediaDirectoryPath != path else {
            return
        }
        await mutateSettings(persistence: .debounced) { $0.mediaDirectoryPath = path }
    }

    func selectInput(id: String) async {
        guard settings.selectedInput?.id != id else {
            return
        }
        await mutateSettings(restart: .debounced) { settings in
            settings.selectedInput = inventory.selectableVideoInputs.first(where: { $0.id == id })
        }
    }

    func setAudioSourceEnabled(id: String, isEnabled: Bool) async {
        await mutateSettings(restart: .immediate) { settings in
            guard let index = settings.selectedAudioSources.firstIndex(where: { $0.id == id }) else {
                return
            }
            settings.selectedAudioSources[index].isEnabled = isEnabled
        }
    }

    func setAudioSourceGain(id: String, gain: Double) async {
        await mutateSettings(persistence: .debounced) { settings in
            guard let index = settings.selectedAudioSources.firstIndex(where: { $0.id == id }) else {
                return
            }
            settings.selectedAudioSources[index].gain = gain
        }
    }

    func setPiPEnabled(_ enabled: Bool) async {
        await mutateSettings() { settings in
            settings.screenRecording.isPiPEnabled = enabled
        }
    }

    func setPiPCorner(_ corner: PiPCorner) async {
        await mutateSettings() { settings in
            settings.screenRecording.pipCorner = corner
        }
    }

    func setIncludeSystemAudio(_ enabled: Bool) async {
        await mutateSettings() { settings in
            settings.screenRecording.includeSystemAudio = enabled
        }
    }

    func setIncludeMicrophoneAudio(_ enabled: Bool) async {
        await mutateSettings(restart: .immediate) { settings in
            settings.screenRecording.includeMicrophoneAudio = enabled
        }
    }

    func setHideTitleBar(_ hidden: Bool) async {
        await mutateSettings() { settings in
            settings.windowOptions.hideTitleBar = hidden
        }
    }

    func setAllowBackgroundDrag(_ enabled: Bool) async {
        await mutateSettings() { settings in
            settings.windowOptions.allowBackgroundDrag = enabled
        }
    }

    func captureButtonPressed() async {
        switch settings.mode {
        case .photo:
            await capturePhoto()
        case .video:
            await toggleRecording()
        }
    }

    func resetAllSettings() async {
        if isRecording {
            do {
                _ = try await stopRecordingWithRetry()
            } catch {
                // The recording has ended either way; report but keep resetting.
                if (error as? CaptureServiceError) != .recordingNotInProgress {
                    errorMessage = error.localizedDescription
                }
            }
            isRecording = false
            recordingStartedAt = nil
            _ = try? stateMachine.transition(.stopRecording)
        }

        settings = .default
        hasDeferredPreviewReconfiguration = false
        lastAppliedSettings = nil
        previewRestartTask?.cancel()
        previewRestartTask = nil
        await refreshInventory()
        ensureSelectionsAreValid()

        do {
            try await applyPreviewConfigurationWithRollbackIfNeeded()
            isInitialized = true
        } catch {
            errorMessage = error.localizedDescription
        }

        lastMediaURL = nil
        lastThumbnail = nil
        lastMediaIsInPhotoLibrary = false
        await loadLatestMediaPreviewFromMediaDirectory()
    }

    /// `location` is a top-left-origin point inside a preview of the given size.
    func focus(at location: CGPoint, in size: CGSize) async {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let normalized = CGPoint(
            x: max(0.0, min(1.0, location.x / size.width)),
            y: max(0.0, min(1.0, location.y / size.height))
        )

        focusIndicatorPoint = location
        focusIndicatorResetTask?.cancel()
        focusIndicatorResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else {
                return
            }
            self?.focusIndicatorPoint = nil
        }

        do {
            try await captureService.setFocusAndExposure(normalizedPoint: normalized)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openLastMediaInFinder() {
        if let lastMediaURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastMediaURL])
            return
        }

        if lastMediaIsInPhotoLibrary,
           let photosApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: photosApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openMediaDirectory() {
        let url = URL(fileURLWithPath: settings.mediaDirectoryPath, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    func chooseMediaDirectoryFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK,
           let selected = panel.url {
            // Keep access across launches in sandboxed builds.
            let bookmark = Self.makeDirectoryBookmark(for: selected)
            _ = selected.startAccessingSecurityScopedResource()

            Task {
                await mutateSettings { settings in
                    settings.mediaDirectoryPath = selected.path
                    settings.mediaDirectoryBookmark = bookmark
                }
                await loadLatestMediaPreviewFromMediaDirectory()
            }
        }
    }

    /// Restores access to a previously chosen media folder (no-op outside the
    /// sandbox, where the plain path already works).
    private func resolveMediaDirectoryBookmark() {
        guard let bookmark = settings.mediaDirectoryBookmark else {
            return
        }

        var isStale = false
        var resolved: URL?
        do {
            resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        }

        guard let url = resolved else {
            return
        }

        _ = url.startAccessingSecurityScopedResource()

        var changed = false
        if url.path != settings.mediaDirectoryPath {
            settings.mediaDirectoryPath = url.path
            changed = true
        }
        if isStale, let fresh = Self.makeDirectoryBookmark(for: url) {
            settings.mediaDirectoryBookmark = fresh
            changed = true
        }
        if changed {
            persistSettings()
        }
    }

    private static func makeDirectoryBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    /// Finishes an in-flight recording (used before app termination).
    func finishActiveRecording() async {
        persistSettings()
        guard isRecording else {
            return
        }

        _ = try? await stopRecordingWithRetry()
        isRecording = false
        recordingStartedAt = nil
    }

    // MARK: - Capture

    private func capturePhoto() async {
        guard !isCapturingPhoto else {
            return
        }

        await flushPendingPreviewRestart()

        isCapturingPhoto = true
        defer { isCapturingPhoto = false }

        do {
            let media = try await captureService.capturePhoto(with: settings)
            updateLastMedia(media)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleRecording() async {
        // Serialize presses: a double-click must not race two start/stop calls
        // into the capture service.
        guard !isTogglingRecording else {
            return
        }
        isTogglingRecording = true
        defer { isTogglingRecording = false }

        if isRecording {
            do {
                let media = try await stopRecordingWithRetry()
                isRecording = false
                recordingStartedAt = nil
                _ = try? stateMachine.transition(.stopRecording)
                updateLastMedia(media)
            } catch {
                // Every stop-side failure means the recording has ended; never
                // strand the UI in a recording state with no way out.
                isRecording = false
                recordingStartedAt = nil
                _ = try? stateMachine.transition(.stopRecording)

                if let captureError = error as? CaptureServiceError,
                   case .videoPersistenceFailed(let tempPath) = captureError {
                    // Keep the preserved movie reachable via the thumbnail.
                    let tempURL = URL(fileURLWithPath: tempPath)
                    updateLastMedia(CapturedMedia(fileURL: tempURL, thumbnailFileURL: tempURL))
                }
                errorMessage = error.localizedDescription
            }
            await applyDeferredPreviewConfigurationIfNeeded()
            return
        }

        await flushPendingPreviewRestart()

        do {
            try await captureService.startRecording(with: settings)
            isRecording = true
            recordingStartedAt = Date()
            _ = try? stateMachine.transition(.startRecording)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecordingWithRetry() async throws -> CapturedMedia {
        let maxRetries = 6
        for attempt in 0..<maxRetries {
            do {
                return try await captureService.stopRecording(with: settings)
            } catch CaptureServiceError.recordingNotInProgress where attempt < (maxRetries - 1) {
                try await Task.sleep(for: .milliseconds(120))
                continue
            }
        }

        throw CaptureServiceError.recordingNotInProgress
    }

    private func handleUnexpectedRecordingFinish(media: CapturedMedia?, error: Error?) {
        guard isRecording else {
            return
        }

        isRecording = false
        recordingStartedAt = nil
        _ = try? stateMachine.transition(.stopRecording)

        if let media {
            updateLastMedia(media)
        }

        if let error {
            errorMessage = "Recording stopped unexpectedly: \(error.localizedDescription)"
        }

        Task {
            await applyDeferredPreviewConfigurationIfNeeded()
        }
    }

    // MARK: - Media previews

    private func updateLastMedia(_ media: CapturedMedia) {
        lastMediaURL = media.fileURL
        lastMediaIsInPhotoLibrary = media.fileURL == nil

        thumbnailGeneration += 1
        let generation = thumbnailGeneration
        Task { [weak self] in
            let thumbnail = await ThumbnailFactory.makeThumbnail(from: media)
            guard let self, self.thumbnailGeneration == generation else {
                return
            }
            self.lastThumbnail = thumbnail?.image
        }
    }

    private func loadLatestMediaPreviewFromMediaDirectory() async {
        guard settings.mediaDestination == .photosDirectory else {
            return
        }

        let directory = URL(fileURLWithPath: settings.mediaDirectoryPath, isDirectory: true)
        guard let latest = await Self.scanLatestMedia(in: directory) else {
            return
        }

        updateLastMedia(CapturedMedia(fileURL: latest, thumbnailFileURL: latest))
    }

    /// Scans the media directory off the main actor; big folders must not stall launch.
    private nonisolated static func scanLatestMedia(in directory: URL) async -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return nil
        }

        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "gif"]
        let mediaExtensions = imageExtensions + ["mov", "mp4", "m4v"]

        if let latestPhoto = latestFileURL(in: directory, matchingExtensions: imageExtensions) {
            return latestPhoto
        }

        return latestFileURL(in: directory, matchingExtensions: mediaExtensions)
    }

    private nonisolated static func latestFileURL(in directory: URL, matchingExtensions extensions: [String]) -> URL? {
        let allowed = Set(extensions.map { $0.lowercased() })
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latest: (url: URL, modified: Date)?
        for case let fileURL as URL in enumerator {
            guard allowed.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            let modified = values.contentModificationDate ?? .distantPast
            if let current = latest {
                if modified > current.modified {
                    latest = (fileURL, modified)
                }
            } else {
                latest = (fileURL, modified)
            }
        }

        return latest?.url
    }

    // MARK: - Configuration plumbing

    private func ensureSelectionsAreValid() {
        let videoInputs = inventory.selectableVideoInputs
        let mobileIDs = inventory.mobileDeviceIDs
        if settings.selectedInput == nil || !videoInputs.contains(where: { $0.id == settings.selectedInput?.id }) {
            // A phone-backed source is selectable but never a default.
            settings.selectedInput = videoInputs.first(where: { !mobileIDs.contains($0.id) }) ?? videoInputs.first
        }

        settings.selectedAudioSources = AudioSourceMerger.merge(
            existing: settings.selectedAudioSources,
            discovered: inventory.selectableAudioSources,
            mobileSourceIDs: mobileIDs
        )

        migrateAudioDefaultsIfNeeded(mobileIDs: mobileIDs)

        if settings.mediaDirectoryPath.isEmpty {
            settings.mediaDirectoryPath = AppSettings.defaultMediaDirectoryPath
        }

        persistSettings()
    }

    /// One-time migration: earlier builds could auto-enable a phone's microphone
    /// (whatever macOS reported as the default input). Disable those and re-point
    /// the default at a local microphone; anything the user chooses after this
    /// migration is respected and never touched again.
    private func migrateAudioDefaultsIfNeeded(mobileIDs: Set<String>) {
        guard settings.audioDefaultsVersion < 1 else {
            return
        }
        settings.audioDefaultsVersion = 1

        guard !mobileIDs.isEmpty else {
            return
        }

        var disabledAny = false
        for index in settings.selectedAudioSources.indices
        where settings.selectedAudioSources[index].isEnabled
            && settings.selectedAudioSources[index].kind == .microphone
            && mobileIDs.contains(settings.selectedAudioSources[index].id) {
            settings.selectedAudioSources[index].isEnabled = false
            disabledAny = true
        }

        if disabledAny,
           !settings.selectedAudioSources.contains(where: { $0.kind == .microphone && $0.isEnabled }),
           let replacement = settings.selectedAudioSources.firstIndex(where: {
               $0.kind == .microphone && !mobileIDs.contains($0.id)
           }) {
            settings.selectedAudioSources[replacement].isEnabled = true
        }
    }

    private func configureAndStartPreviewWithRecovery() async throws {
        do {
            let applied = try await captureService.apply(settings: settings)
            activeVideoAspectRatio = applied.videoAspectRatio
            await captureService.startPreview()
            if let sourceID = settings.selectedInput?.id {
                _ = try? stateMachine.transition(.startPreview(sourceID: sourceID))
            }
        } catch {
            guard await recoverFromInputSelectionError(error) else {
                throw error
            }

            let applied = try await captureService.apply(settings: settings)
            activeVideoAspectRatio = applied.videoAspectRatio
            await captureService.startPreview()
            if let sourceID = settings.selectedInput?.id {
                _ = try? stateMachine.transition(.startPreview(sourceID: sourceID))
            }
        }
    }

    private func applyPreviewConfigurationWithRollbackIfNeeded() async throws {
        do {
            try await configureAndStartPreviewWithRecovery()
            lastAppliedSettings = settings
            return
        } catch {
            guard let previous = lastAppliedSettings, previous != settings else {
                throw error
            }

            settings = previous
            hasDeferredPreviewReconfiguration = false
            persistSettings()

            try await configureAndStartPreviewWithRecovery()
            lastAppliedSettings = settings
            errorMessage = "Selected capture settings are unavailable. Reverted to last working configuration."
        }
    }

    private func recoverFromInputSelectionError(_ error: Error) async -> Bool {
        guard let captureError = error as? CaptureServiceError else {
            return false
        }

        switch captureError {
        case .cameraNotFound, .cameraUnavailable, .screenNotFound, .missingInputSource:
            break
        default:
            return false
        }

        await refreshInventory()
        let mobileIDs = inventory.mobileDeviceIDs
        let allCandidates = inventory.selectableVideoInputs
        // Prefer local devices when hunting for a replacement input.
        let candidates = allCandidates.filter { !mobileIDs.contains($0.id) }
            + allCandidates.filter { mobileIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            return false
        }

        guard let current = settings.selectedInput else {
            settings.selectedInput = candidates[0]
            persistSettings()
            return true
        }

        let sameTypeAndName = candidates.first {
            $0.id != current.id && $0.type == current.type && $0.name == current.name
        }
        let sameType = candidates.first {
            $0.id != current.id && $0.type == current.type
        }
        let anyDifferent = candidates.first {
            $0.id != current.id
        }

        guard let fallbackInput = sameTypeAndName ?? sameType ?? anyDifferent else {
            return false
        }

        settings.selectedInput = fallbackInput
        persistSettings()
        return true
    }

    private func applyDeferredPreviewConfigurationIfNeeded() async {
        guard hasDeferredPreviewReconfiguration else {
            return
        }

        do {
            try await applyPreviewConfigurationWithRollbackIfNeeded()
            hasDeferredPreviewReconfiguration = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private enum PersistenceMode {
        case immediate
        case debounced
    }

    private enum RestartMode {
        case none
        case immediate
        /// Coalesces rapid changes (value cycling, scroll-stepping) into a single
        /// session reconfiguration after a short quiet period.
        case debounced
    }

    private func mutateSettings(
        restart: RestartMode = .none,
        persistence: PersistenceMode = .immediate,
        _ mutate: (inout AppSettings) -> Void
    ) async {
        mutate(&settings)

        switch persistence {
        case .immediate:
            persistSettings()
        case .debounced:
            schedulePersistSettings()
        }

        switch restart {
        case .none:
            return

        case .immediate:
            previewRestartTask?.cancel()
            previewRestartTask = nil
            if isRecording {
                hasDeferredPreviewReconfiguration = true
                return
            }

            do {
                try await applyPreviewConfigurationWithRollbackIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
            }

        case .debounced:
            if isRecording {
                hasDeferredPreviewReconfiguration = true
                return
            }
            schedulePreviewRestart()
        }
    }

    private func schedulePreviewRestart() {
        previewRestartTask?.cancel()
        previewRestartTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: self.previewRestartDebounce)
            guard !Task.isCancelled else {
                return
            }

            self.previewRestartTask = nil
            if self.isRecording {
                self.hasDeferredPreviewReconfiguration = true
                return
            }

            do {
                try await self.applyPreviewConfigurationWithRollbackIfNeeded()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Applies a still-pending debounced reconfiguration right now — captures must
    /// run against the settings the user just chose, not the previous ones.
    private func flushPendingPreviewRestart() async {
        guard previewRestartTask != nil else {
            return
        }

        previewRestartTask?.cancel()
        previewRestartTask = nil

        if isRecording {
            hasDeferredPreviewReconfiguration = true
            return
        }

        do {
            try await applyPreviewConfigurationWithRollbackIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistSettings() {
        persistDebounceTask?.cancel()
        persistDebounceTask = nil

        do {
            try settingsStore.replace(with: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Coalesces the write for high-frequency updates (gain sliders, path typing)
    /// so the main thread isn't hammered with disk I/O.
    private func schedulePersistSettings() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else {
                return
            }
            self.persistSettings()
        }
    }

    // MARK: - Device change tracking

    private func registerNotificationObservers() {
        guard notificationObservers.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        let deviceChangeNames: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            NSApplication.didChangeScreenParametersNotification
        ]

        for name in deviceChangeNames {
            notificationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleDeviceRevalidation()
                }
            })
        }

        notificationObservers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistSettings()
            }
        })
    }

    private func scheduleDeviceRevalidation() {
        deviceRevalidationTask?.cancel()
        deviceRevalidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else {
                return
            }
            await self.revalidateDevices()
        }
    }

    /// Re-checks selections against what is connected: falls over to surviving
    /// devices when the active camera or microphone disappears, and picks up new
    /// arrivals for the pickers.
    private func revalidateDevices() async {
        await refreshInventory()

        let previousInput = settings.selectedInput
        let previousEnabledAudio = Set(settings.selectedAudioSources.filter(\.isEnabled).map(\.id))
        ensureSelectionsAreValid()

        let inputChanged = settings.selectedInput != previousInput
        let audioChanged = Set(settings.selectedAudioSources.filter(\.isEnabled).map(\.id)) != previousEnabledAudio
        guard inputChanged || audioChanged else {
            return
        }

        if isRecording {
            hasDeferredPreviewReconfiguration = true
            return
        }

        do {
            try await applyPreviewConfigurationWithRollbackIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
