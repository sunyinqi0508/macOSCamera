import CameraCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes captured stills into the format and quality the user actually chose,
/// off the main actor. Files always get an extension matching their real contents.
enum PhotoEncoding {
    struct EncodedPhoto: Sendable {
        let data: Data
        let fileExtension: String
    }

    static func compressionQuality(for quality: PhotoQuality) -> CGFloat {
        switch quality {
        case .standard:
            return 0.65
        case .high:
            return 0.85
        case .max:
            return 1.0
        }
    }

    /// Turns the camera's native photo data (HEIC or JPEG) into the requested
    /// format/quality. Falls back to the original bytes — with a truthful file
    /// extension — when the platform can't encode the target format.
    static func finalizeCameraPhoto(
        data: Data,
        capturedCodecIsHEVC: Bool,
        format: PhotoFormat,
        quality: PhotoQuality
    ) async -> EncodedPhoto {
        let lossyQuality = compressionQuality(for: quality)
        let nativeExtension = capturedCodecIsHEVC ? "heic" : "jpg"

        switch format {
        case .heic:
            if capturedCodecIsHEVC, quality == .max {
                return EncodedPhoto(data: data, fileExtension: "heic")
            }
            if let transcoded = transcode(data: data, to: .heic, lossyQuality: lossyQuality) {
                return EncodedPhoto(data: transcoded, fileExtension: "heic")
            }

        case .jpeg:
            if !capturedCodecIsHEVC, quality == .max {
                return EncodedPhoto(data: data, fileExtension: "jpg")
            }
            if let transcoded = transcode(data: data, to: .jpeg, lossyQuality: lossyQuality) {
                return EncodedPhoto(data: transcoded, fileExtension: "jpg")
            }

        case .png:
            if let transcoded = transcode(data: data, to: .png, lossyQuality: 1.0) {
                return EncodedPhoto(data: transcoded, fileExtension: "png")
            }
        }

        return EncodedPhoto(data: data, fileExtension: nativeExtension)
    }

    /// Captures a still of the given display and encodes it in the requested format.
    static func captureScreenPhoto(
        displayID: CGDirectDisplayID,
        format: PhotoFormat,
        quality: PhotoQuality
    ) async throws -> EncodedPhoto {
        guard let image = CGDisplayCreateImage(displayID) else {
            throw CaptureServiceError.screenNotFound
        }

        let lossyQuality = compressionQuality(for: quality)
        if let encoded = encode(image: image, to: format, lossyQuality: lossyQuality) {
            return EncodedPhoto(data: encoded, fileExtension: format.fileExtension)
        }

        // HEIC needs hardware HEVC support; fall back to JPEG rather than failing.
        if format == .heic, let fallback = encode(image: image, to: .jpeg, lossyQuality: lossyQuality) {
            return EncodedPhoto(data: fallback, fileExtension: "jpg")
        }

        throw CaptureServiceError.failedToEncodeImage
    }

    // MARK: - ImageIO plumbing

    private static func utType(for format: PhotoFormat) -> UTType {
        switch format {
        case .heic:
            return .heic
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    /// Re-encodes image data into another format, carrying source metadata
    /// (EXIF, orientation) over to the output.
    private static func transcode(data: Data, to format: PhotoFormat, lossyQuality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            utType(for: format).identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: lossyQuality] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return nil
        }

        return output as Data
    }

    private static func encode(image: CGImage, to format: PhotoFormat, lossyQuality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            utType(for: format).identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: lossyQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return nil
        }

        return output as Data
    }
}
