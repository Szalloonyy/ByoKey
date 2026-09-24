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

    private var storage: [String: DecodedImage] = [:]
    private var order: [String] = []
    private let limit = 250

    func image(for key: String, data: Data, maxPixelSize: Int) -> DecodedImage? {
        if let cached = storage[key] { return cached }
        guard let decoded = ImageProcessor.decodedImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        storage[key] = decoded
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            storage[evicted] = nil
        }
        return decoded
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
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
