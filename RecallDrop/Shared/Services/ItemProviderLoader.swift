//
//  ItemProviderLoader.swift
//  RecallDrop
//
//  Reads whatever arrives via drag and drop, paste or the share sheet
//  (NSItemProvider) into plain values: image data, URLs and text.
//  Safari, Instagram, X, Photos and Finder all describe their content
//  differently; this is the one place that knows how.
//

import Foundation
import UniformTypeIdentifiers

struct CapturedPayload: Sendable {
    struct Image: Sendable {
        var data: Data
        /// Where the image came from (e.g. the page it was dragged out of).
        var sourceURL: URL?
    }

    var images: [Image] = []
    var urls: [URL] = []
    var texts: [String] = []

    var isEmpty: Bool { images.isEmpty && urls.isEmpty && texts.isEmpty }

    mutating func append(_ other: CapturedPayload) {
        images.append(contentsOf: other.images)
        urls.append(contentsOf: other.urls)
        texts.append(contentsOf: other.texts)
    }
}

@MainActor
enum ItemProviderLoader {
    /// Types to accept for drops and paste.
    static let supportedTypes: [UTType] = [.image, .fileURL, .url, .plainText, .text]

    static func load(_ providers: [NSItemProvider]) async -> CapturedPayload {
        var payload = CapturedPayload()
        for provider in providers {
            payload.append(await load(provider))
        }
        return payload
    }

    static func load(_ provider: NSItemProvider) async -> CapturedPayload {
        var payload = CapturedPayload()

        // Finder and Files hand over files; images among them are read directly.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let fileURL = await loadURL(from: provider), fileURL.isFileURL {
            if ImageProcessor.isImageFile(fileURL), let data = await readFile(fileURL) {
                payload.images.append(.init(data: data, sourceURL: nil))
            } else if let text = await readTextFile(fileURL) {
                payload.texts.append(text)
            }
            return payload
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            var sourceURL: URL?
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                sourceURL = await loadURL(from: provider).flatMap { $0.isFileURL ? nil : $0 }
            }
            if let data = await loadImageData(from: provider) {
                payload.images.append(.init(data: data, sourceURL: sourceURL))
                return payload
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider), !url.isFileURL {
            payload.urls.append(url)
            return payload
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let text = await loadText(from: provider)?.trimmedNonEmpty {
            payload.texts.append(text)
        }
        return payload
    }

    // MARK: Primitive loaders

    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        // Prefer formats that keep quality; fall back to whatever image type is offered.
        let preferred: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .webP, .image]
        for type in preferred where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(from: provider, type: type) { return data }
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    /// Reads a file, honoring security scope (Files app, sandboxed drops).
    static func readFile(_ url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    private static func readTextFile(_ url: URL) async -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text),
              let data = await readFile(url), data.count < 2_000_000 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmedNonEmpty
    }
}
