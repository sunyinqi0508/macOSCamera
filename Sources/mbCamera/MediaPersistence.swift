import CameraCore
import Foundation
@preconcurrency import Photos

enum MediaPersistenceError: LocalizedError {
    case photoLibraryPermissionDenied

    var errorDescription: String? {
        switch self {
        case .photoLibraryPermissionDenied:
            return "Photo library permission was denied. Allow access in System Settings → Privacy & Security → Photos."
        }
    }
}

/// Persists captured media. Stateless and nonisolated so file I/O and Photos
/// library work happen off the main actor.
final class MediaPersistence: Sendable {
    private let pathResolver = MediaPathResolver()

    func persistPhoto(data: Data, destinationURL: URL, destination: MediaDestination) async throws -> CapturedMedia {
        switch destination {
        case .photosDirectory:
            let target = try prepareUniqueDestination(for: destinationURL)
            try data.write(to: target, options: .atomic)
            return CapturedMedia(fileURL: target, thumbnailFileURL: target)

        case .photoLibrary:
            try await ensurePhotoLibraryAuthorization()
            try await performPhotoLibraryChange {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            return CapturedMedia(thumbnailData: data)
        }
    }

    func persistVideo(sourceURL: URL, destinationURL: URL, destination: MediaDestination) async throws -> CapturedMedia {
        switch destination {
        case .photosDirectory:
            let target = try prepareUniqueDestination(for: destinationURL)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: target)
            } catch {
                // Moves fail across volumes (e.g. an external-drive destination).
                try FileManager.default.copyItem(at: sourceURL, to: target)
                try? FileManager.default.removeItem(at: sourceURL)
            }
            return CapturedMedia(fileURL: target, thumbnailFileURL: target)

        case .photoLibrary:
            try await ensurePhotoLibraryAuthorization()
            try await performPhotoLibraryChange {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: sourceURL, options: nil)
            }
            // The temp file stays behind as the thumbnail source; the system
            // cleans the temporary directory up on its own.
            return CapturedMedia(thumbnailFileURL: sourceURL)
        }
    }

    private func prepareUniqueDestination(for url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return pathResolver.uniquedURL(for: url) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func ensurePhotoLibraryAuthorization() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status: PHAuthorizationStatus

        if current == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            status = current
        }

        guard status == .authorized || status == .limited else {
            throw MediaPersistenceError.photoLibraryPermissionDenied
        }
    }

    private func performPhotoLibraryChange(_ changes: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: MediaPersistenceError.photoLibraryPermissionDenied)
                }
            }
        }
    }
}
