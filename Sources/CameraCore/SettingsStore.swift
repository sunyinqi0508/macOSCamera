import Foundation

public final class SettingsStore {
    public enum SettingsStoreError: Error {
        case failedToEncode
        case failedToDecode
    }

    public private(set) var settings: AppSettings

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(
        fileURL: URL = SettingsStore.defaultURL(),
        fileManager: FileManager = .default,
        initialSettings: AppSettings = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.settings = initialSettings

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    public func load() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try persist()
            return
        }

        let data = try Data(contentsOf: fileURL)
        do {
            settings = try decoder.decode(AppSettings.self, from: data)
        } catch {
            // Self-heal instead of failing every launch: keep the unreadable
            // file aside for inspection and start over from defaults.
            let backupURL = fileURL.appendingPathExtension("corrupt")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.moveItem(at: fileURL, to: backupURL)
            settings = .default
            try persist()
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) throws {
        mutate(&settings)
        try persist()
    }

    public func replace(with settings: AppSettings) throws {
        self.settings = settings
        try persist()
    }

    public func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            throw SettingsStoreError.failedToEncode
        }

        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MBCAMERA_SETTINGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mbCamera", isDirectory: true)

        return appSupport.appendingPathComponent("settings.json")
    }
}
