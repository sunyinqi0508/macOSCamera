import Foundation

public enum PhotoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case high
    case max

    public var id: String { rawValue }
}

public enum PhotoFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case heic
    case jpeg
    case png

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .heic:
            return "heic"
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        }
    }
}

public enum VideoResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd720
    case hd1080
    case uhd4k

    public var id: String { rawValue }

    public var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd720:
            return (1280, 720)
        case .hd1080:
            return (1920, 1080)
        case .uhd4k:
            return (3840, 2160)
        }
    }
}

public enum VideoFrameRate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }
}

public enum MediaDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case photosDirectory
    case photoLibrary

    public var id: String { rawValue }
}

public enum CaptureInputSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case screen

    public var id: String { rawValue }
}

public struct CaptureInputSelection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var type: CaptureInputSourceType

    public init(id: String, name: String, type: CaptureInputSourceType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public enum AudioSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemOutput

    public var id: String { rawValue }
}

public struct AudioSourceSelection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var kind: AudioSourceKind
    public var gain: Double
    public var isEnabled: Bool

    public init(id: String, name: String, kind: AudioSourceKind, gain: Double = 1.0, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.gain = gain
        self.isEnabled = isEnabled
    }
}

public enum PiPCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }
}

public struct ScreenRecordingOptions: Codable, Equatable, Sendable {
    public var includeSystemAudio: Bool
    public var includeMicrophoneAudio: Bool
    public var isPiPEnabled: Bool
    public var pipCorner: PiPCorner

    public init(
        includeSystemAudio: Bool = true,
        includeMicrophoneAudio: Bool = true,
        isPiPEnabled: Bool = true,
        pipCorner: PiPCorner = .bottomRight
    ) {
        self.includeSystemAudio = includeSystemAudio
        self.includeMicrophoneAudio = includeMicrophoneAudio
        self.isPiPEnabled = isPiPEnabled
        self.pipCorner = pipCorner
    }
}

public struct WindowOptions: Codable, Equatable, Sendable {
    public var hideTitleBar: Bool
    public var allowBackgroundDrag: Bool

    public init(
        hideTitleBar: Bool = false,
        allowBackgroundDrag: Bool = false
    ) {
        self.hideTitleBar = hideTitleBar
        self.allowBackgroundDrag = allowBackgroundDrag
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mode: CaptureMode
    public var photoQuality: PhotoQuality
    public var photoFormat: PhotoFormat
    public var videoResolution: VideoResolution
    public var videoFrameRate: VideoFrameRate
    public var mediaDestination: MediaDestination
    public var mediaDirectoryPath: String
    /// Security-scoped bookmark for a user-chosen media folder, so sandboxed
    /// builds keep access across launches.
    public var mediaDirectoryBookmark: Data?
    public var selectedInput: CaptureInputSelection?
    public var selectedAudioSources: [AudioSourceSelection]
    public var screenRecording: ScreenRecordingOptions
    public var windowOptions: WindowOptions
    /// Bumped when default-selection policy changes so old persisted selections
    /// can be migrated once (e.g. un-defaulting mobile microphones).
    public var audioDefaultsVersion: Int

    public init(
        mode: CaptureMode = .photo,
        photoQuality: PhotoQuality = .high,
        photoFormat: PhotoFormat = .heic,
        videoResolution: VideoResolution = .hd1080,
        videoFrameRate: VideoFrameRate = .fps30,
        mediaDestination: MediaDestination = .photosDirectory,
        mediaDirectoryPath: String = AppSettings.defaultMediaDirectoryPath,
        mediaDirectoryBookmark: Data? = nil,
        selectedInput: CaptureInputSelection? = nil,
        selectedAudioSources: [AudioSourceSelection] = [],
        screenRecording: ScreenRecordingOptions = ScreenRecordingOptions(),
        windowOptions: WindowOptions = WindowOptions(),
        audioDefaultsVersion: Int = 0
    ) {
        self.mode = mode
        self.photoQuality = photoQuality
        self.photoFormat = photoFormat
        self.videoResolution = videoResolution
        self.videoFrameRate = videoFrameRate
        self.mediaDestination = mediaDestination
        self.mediaDirectoryPath = mediaDirectoryPath
        self.mediaDirectoryBookmark = mediaDirectoryBookmark
        self.selectedInput = selectedInput
        self.selectedAudioSources = selectedAudioSources
        self.screenRecording = screenRecording
        self.windowOptions = windowOptions
        self.audioDefaultsVersion = audioDefaultsVersion
    }

    public static var `default`: AppSettings {
        AppSettings()
    }

    public static var defaultMediaDirectoryPath: String {
        // Sandboxed (App Store) builds can only reach ~/Pictures via entitlement;
        // unsandboxed builds keep the original ~/Photos default.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
           let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            return pictures.appendingPathComponent("Camera", isDirectory: true).path
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Photos", isDirectory: true).path
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case photoQuality
        case photoFormat
        case videoResolution
        case videoFrameRate
        case mediaDestination
        case mediaDirectoryPath
        case mediaDirectoryBookmark
        case selectedInput
        case selectedAudioSources
        case screenRecording
        case windowOptions
        case audioDefaultsVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .photo
        photoQuality = try container.decodeIfPresent(PhotoQuality.self, forKey: .photoQuality) ?? .high
        photoFormat = try container.decodeIfPresent(PhotoFormat.self, forKey: .photoFormat) ?? .heic
        videoResolution = try container.decodeIfPresent(VideoResolution.self, forKey: .videoResolution) ?? .hd1080
        videoFrameRate = try container.decodeIfPresent(VideoFrameRate.self, forKey: .videoFrameRate) ?? .fps30
        mediaDestination = try container.decodeIfPresent(MediaDestination.self, forKey: .mediaDestination) ?? .photosDirectory
        mediaDirectoryPath = try container.decodeIfPresent(String.self, forKey: .mediaDirectoryPath) ?? AppSettings.defaultMediaDirectoryPath
        mediaDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .mediaDirectoryBookmark)
        selectedInput = try container.decodeIfPresent(CaptureInputSelection.self, forKey: .selectedInput)
        selectedAudioSources = try container.decodeIfPresent([AudioSourceSelection].self, forKey: .selectedAudioSources) ?? []
        screenRecording = try container.decodeIfPresent(ScreenRecordingOptions.self, forKey: .screenRecording) ?? ScreenRecordingOptions()
        windowOptions = try container.decodeIfPresent(WindowOptions.self, forKey: .windowOptions) ?? WindowOptions()
        audioDefaultsVersion = try container.decodeIfPresent(Int.self, forKey: .audioDefaultsVersion) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(photoQuality, forKey: .photoQuality)
        try container.encode(photoFormat, forKey: .photoFormat)
        try container.encode(videoResolution, forKey: .videoResolution)
        try container.encode(videoFrameRate, forKey: .videoFrameRate)
        try container.encode(mediaDestination, forKey: .mediaDestination)
        try container.encode(mediaDirectoryPath, forKey: .mediaDirectoryPath)
        try container.encodeIfPresent(mediaDirectoryBookmark, forKey: .mediaDirectoryBookmark)
        try container.encodeIfPresent(selectedInput, forKey: .selectedInput)
        try container.encode(selectedAudioSources, forKey: .selectedAudioSources)
        try container.encode(screenRecording, forKey: .screenRecording)
        try container.encode(windowOptions, forKey: .windowOptions)
        try container.encode(audioDefaultsVersion, forKey: .audioDefaultsVersion)
    }
}
