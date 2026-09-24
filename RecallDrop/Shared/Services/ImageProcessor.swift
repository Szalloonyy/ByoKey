//
//  ImageProcessor.swift
//  RecallDrop
//
//  Decoding, downscaling and re-encoding with ImageIO only, so it works the
//  same on iOS, macOS and in the share extension without UIKit/AppKit.
//  All functions are synchronous and meant to run off the main actor.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RecallDropKit

struct PreparedImage: Sendable {
    var storedData: Data
    var thumbnailData: Data?
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ImageProcessingError: LocalizedError {
    case unreadable

    var errorDescription: String? { "The image could not be read." }
}

/// A decoded image that may cross actors (CGImage is immutable).
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

enum ImageProcessor {
    /// Longest edge kept in the library.
    static let maxStoredDimension = 4096
    /// Longest edge of grid thumbnails.
    static let thumbnailDimension = 640
    /// Longest edge sent to vision models – larger images cost more tokens without helping.
    static let uploadDimension = 1568
    /// Originals larger than this are re-encoded.
    static let maxStoredBytes = 12 * 1024 * 1024

    private static let keptTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, "public.heif"
    ]

    /// Normalizes an incoming image for storage and builds its thumbnail.
    static func prepare(_ data: Data) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let (width, height) = orientedPixelSize(of: source) else {
            throw ImageProcessingError.unreadable
        }

        let type = CGImageSourceGetType(source) as String? ?? ""
        let needsReencode = data.count > maxStoredBytes
            || max(width, height) > maxStoredDimension
            || !keptTypes.contains(type)

        var stored = data
        var storedSize = (width, height)
        if needsReencode {
            guard let image = downsampledImage(from: source, maxPixelSize: maxStoredDimension),
                  let jpeg = encodeJPEG(image, quality: 0.88) else {
                throw ImageProcessingError.unreadable
            }
            stored = jpeg
            storedSize = (image.width, image.height)
        }

        let thumbnail = downsampledImage(from: source, maxPixelSize: thumbnailDimension).flatMap {
            encodeJPEG($0, quality: 0.8)
        }
        return PreparedImage(storedData: stored, thumbnailData: thumbnail,
                             pixelWidth: storedSize.0, pixelHeight: storedSize.1)
    }

    /// JPEG for AI upload, at most `maxPixelSize` on the long edge.
    static func uploadJPEG(from data: Data, maxPixelSize: Int = uploadDimension, quality: Double = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsampledImage(from: source, maxPixelSize: maxPixelSize) else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    /// Upright image scaled to fit `maxPixelSize` (never upscaled).
    static func decodedImage(from data: Data, maxPixelSize: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsampledImage(from: source, maxPixelSize: maxPixelSize) else { return nil }
        return DecodedImage(cgImage: image)
    }

    static func downsampledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let longest = orientedPixelSize(of: source).map { max($0.0, $0.1) } ?? maxPixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, longest))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size after applying the EXIF orientation.
    static func orientedPixelSize(of source: CGImageSource) -> (Int, Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // Orientations 5–8 rotate by 90°.
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// PNG encoding, used when the pasteboard only offers TIFF.
    static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// File extension matching the image data ("jpg", "png", "heic", …).
    static func fileExtension(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let utType = UTType(type) else { return "jpg" }
        return utType.preferredFilenameExtension ?? "jpg"
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
