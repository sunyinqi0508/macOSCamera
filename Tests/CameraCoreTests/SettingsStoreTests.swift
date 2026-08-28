import CameraCore
import Foundation
import Testing

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test("load persists defaults when file is missing")
    func loadPersistsDefaultsWhenMissing() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)

        try store.load()

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.settings == .default)
    }

    @Test("replace saves and load restores values")
    func replaceSavesAndLoadsValues() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("settings.json")
        let expected = AppSettings(
            mode: .video,
            photoQuality: .max,
            photoFormat: .jpeg,
            videoResolution: .uhd4k,
            videoFrameRate: .fps60,
            mediaDestination: .photosDirectory,
            mediaDirectoryPath: "/tmp/custom"
        )

        let writer = SettingsStore(fileURL: fileURL)
        try writer.replace(with: expected)

        let reader = SettingsStore(fileURL: fileURL)
        try reader.load()

        #expect(reader.settings == expected)
    }

    @Test("load supports settings files without newer window options")
    func loadSupportsOlderSettingsSchema() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("settings.json")
        let oldJSON = """
        {
          "mode": "video",
          "photoQuality": "high",
          "photoFormat": "jpeg",
          "videoResolution": "hd1080",
          "videoFrameRate": 30,
          "mediaDestination": "photosDirectory",
          "mediaDirectoryPath": "/tmp/legacy",
          "selectedAudioSources": [],
          "screenRecording": {
            "includeSystemAudio": true,
            "includeMicrophoneAudio": true,
            "isPiPEnabled": true,
            "pipCorner": "bottomRight"
          }
        }
        """
        guard let oldData = oldJSON.data(using: .utf8) else {
            throw SettingsStore.SettingsStoreError.failedToEncode
        }
        try oldData.write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        try store.load()

        #expect(store.settings.mode == .video)
        #expect(store.settings.mediaDirectoryPath == "/tmp/legacy")
        #expect(store.settings.windowOptions.hideTitleBar == false)
        #expect(store.settings.windowOptions.allowBackgroundDrag == false)
    }

    @Test("load self-heals a corrupt settings file")
    func loadSelfHealsCorruptFile() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("settings.json")
        try Data("not json at all {{{".utf8).write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        try store.load()

        #expect(store.settings == .default)
        // The unreadable file is kept aside and a fresh default file written.
        #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))

        let reloaded = SettingsStore(fileURL: fileURL)
        try reloaded.load()
        #expect(reloaded.settings == .default)
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
