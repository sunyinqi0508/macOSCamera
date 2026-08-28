import CameraCore
import Foundation
import Testing

@Suite("MediaPathResolver")
struct MediaPathResolverTests {
    @Test("photo urls use selected extension")
    func photoURLUsesFormatExtension() {
        let resolver = MediaPathResolver()
        let settings = AppSettings(
            photoFormat: .jpeg,
            mediaDestination: .photosDirectory,
            mediaDirectoryPath: "/tmp/photos"
        )

        let url = resolver.nextPhotoURL(
            for: settings,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(url.pathExtension == "jpg")
        #expect(url.path.contains("/tmp/photos/"))
    }

    @Test("video urls use mov extension")
    func videoURLUsesMovExtension() {
        let resolver = MediaPathResolver()
        let settings = AppSettings(mediaDestination: .photosDirectory, mediaDirectoryPath: "/tmp/videos")

        let url = resolver.nextVideoURL(
            for: settings,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(url.pathExtension == "mov")
        #expect(url.lastPathComponent.hasPrefix("VID_"))
    }

    @Test("uniqued url leaves free names untouched")
    func uniquedURLLeavesFreeNames() {
        let resolver = MediaPathResolver()
        let url = URL(fileURLWithPath: "/tmp/photos/IMG_1.jpg")

        #expect(resolver.uniquedURL(for: url, isTaken: { _ in false }) == url)
    }

    @Test("uniqued url appends a numeric suffix on collisions")
    func uniquedURLAppendsSuffix() {
        let resolver = MediaPathResolver()
        let url = URL(fileURLWithPath: "/tmp/photos/IMG_1.jpg")
        let taken: Set<String> = [
            "/tmp/photos/IMG_1.jpg",
            "/tmp/photos/IMG_1_1.jpg"
        ]

        let unique = resolver.uniquedURL(for: url) { taken.contains($0.path) }

        #expect(unique.path == "/tmp/photos/IMG_1_2.jpg")
    }
}
