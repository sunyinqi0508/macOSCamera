@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO

/// An immutable image handed across concurrency domains after creation.
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Builds small preview thumbnails off the main actor, so a 4K frame or a 12MP
/// HEIC never gets decoded at full size on the UI thread.
enum ThumbnailFactory {
    static let maxPixelSize = 480

    private static let movieExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func makeThumbnail(from media: CapturedMedia) async -> SendableImage? {
        if let data = media.thumbnailData {
            return imageThumbnail(from: .data(data))
        }

        guard let url = media.thumbnailFileURL else {
            return nil
        }

        if movieExtensions.contains(url.pathExtension.lowercased()) {
            return await movieThumbnail(from: url)
        }

        return imageThumbnail(from: .file(url))
    }

    private enum ImageSource {
        case data(Data)
        case file(URL)
    }

    private static func imageThumbnail(from source: ImageSource) -> SendableImage? {
        let imageSource: CGImageSource?
        switch source {
        case .data(let data):
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        case .file(let url):
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        }

        guard let imageSource else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return SendableImage(image: image)
    }

    private static func movieThumbnail(from url: URL) async -> SendableImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return SendableImage(image: image)
        } catch {
            return nil
        }
    }
}
