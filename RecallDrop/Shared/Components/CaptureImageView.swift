//
//  CaptureImageView.swift
//  RecallDrop
//
//  Images decoded off the main thread and cached by key, so scrolling a
//  grid of screenshots stays smooth.
//

import SwiftUI

actor ImageDecodeCache {
    static let shared = ImageDecodeCache()

    /// Decoded bitmaps take 4 bytes per pixel, so the cache is bounded by
    /// memory rather than by count.
    #if os(macOS)
    private let byteLimit = 256 * 1024 * 1024
    #else
    private let byteLimit = 96 * 1024 * 1024
    #endif
    /// Larger decodes (full-screen viewers, detail heroes) are not kept.
    private let largestCachedPixelSize = 1200

    private var storage: [String: (image: DecodedImage, bytes: Int)] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var totalBytes = 0

    func image(for key: String, data: Data, maxPixelSize: Int) -> DecodedImage? {
        let sizedKey = "\(key)@\(maxPixelSize)"
        if let cached = storage[sizedKey] {
            order.removeAll { $0 == sizedKey }
            order.append(sizedKey)
            return cached.image
        }
        guard let decoded = ImageProcessor.decodedImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        guard maxPixelSize <= largestCachedPixelSize else { return decoded }

        let bytes = decoded.cgImage.bytesPerRow * decoded.cgImage.height
        storage[sizedKey] = (decoded, bytes)
        order.append(sizedKey)
        totalBytes += bytes
        while totalBytes > byteLimit, let evicted = order.first {
            order.removeFirst()
            totalBytes -= storage.removeValue(forKey: evicted)?.bytes ?? 0
        }
        return decoded
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
        totalBytes = 0
    }
}

struct CaptureImageView: View {
    /// Identity for caching; change it when the image data changes.
    let cacheKey: String
    let data: Data?
    var maxPixelSize: Int = 900
    var contentMode: ContentMode = .fill

    @State private var image: DecodedImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Theme.placeholderFill)
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: cacheKey) {
            guard let data else {
                image = nil
                return
            }
            let decoded = await ImageDecodeCache.shared.image(for: cacheKey, data: data, maxPixelSize: maxPixelSize)
            withAnimation(.easeOut(duration: 0.15)) {
                image = decoded
                failed = decoded == nil
            }
        }
    }
}

extension CapturedItem {
    /// Cache key that changes when the thumbnail is replaced.
    var thumbnailCacheKey: String {
        "\(id.uuidString)-thumb-\(thumbnailData?.count ?? 0)"
    }

    var fullImageCacheKey: String {
        "\(id.uuidString)-full-\(Int(imageWidth))x\(Int(imageHeight))"
    }
}
