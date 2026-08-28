import Foundation

public struct MediaPathResolver: Sendable {
    public init() {}

    public func destinationDirectory(for settings: AppSettings) -> URL {
        switch settings.mediaDestination {
        case .photosDirectory:
            return URL(fileURLWithPath: settings.mediaDirectoryPath, isDirectory: true)
        case .photoLibrary:
            return URL(fileURLWithPath: settings.mediaDirectoryPath, isDirectory: true)
        }
    }

    public func nextPhotoURL(for settings: AppSettings, now: Date = Date()) -> URL {
        let filename = "IMG_\(Self.timestamp(from: now)).\(settings.photoFormat.fileExtension)"
        return destinationDirectory(for: settings).appendingPathComponent(filename)
    }

    public func nextVideoURL(for settings: AppSettings, now: Date = Date()) -> URL {
        let filename = "VID_\(Self.timestamp(from: now)).mov"
        return destinationDirectory(for: settings).appendingPathComponent(filename)
    }

    /// Returns `url` unchanged when free, otherwise the first `name_N.ext` variant
    /// that `isTaken` reports as available, so rapid captures never overwrite each other.
    public func uniquedURL(for url: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(url) else {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for suffix in 1...9999 {
            var candidate = directory.appendingPathComponent("\(baseName)_\(suffix)")
            if !ext.isEmpty {
                candidate = candidate.appendingPathExtension(ext)
            }
            if !isTaken(candidate) {
                return candidate
            }
        }

        var fallback = directory.appendingPathComponent("\(baseName)_\(UUID().uuidString)")
        if !ext.isEmpty {
            fallback = fallback.appendingPathExtension(ext)
        }
        return fallback
    }

    // Fixed Gregorian calendar so filenames are stable regardless of the user's
    // regional settings (e.g. non-Gregorian calendars).
    private static func timestamp(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d_%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
