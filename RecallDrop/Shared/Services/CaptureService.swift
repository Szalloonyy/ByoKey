//
//  CaptureService.swift
//  RecallDrop
//
//  Turns raw input – image data, URLs, text, drops, pastes, shared items –
//  into CapturedItems and hands them to the pipeline. Images are normalized
//  and thumbnailed off the main actor before anything is stored.
//

import Foundation
import SwiftData
import RecallDropKit

@MainActor
final class CaptureService {
    struct Options {
        /// `nil` applies the user's auto-analyze setting.
        var agentIDs: [UUID]?
        var notes: String?
        var sourceAppName: String?
        var reminderDate: Date?
        var tags: [String] = []

        init(agentIDs: [UUID]? = nil, notes: String? = nil, sourceAppName: String? = nil,
             reminderDate: Date? = nil, tags: [String] = []) {
            self.agentIDs = agentIDs
            self.notes = notes
            self.sourceAppName = sourceAppName
            self.reminderDate = reminderDate
            self.tags = tags
        }
    }

    private let container: ModelContainer
    private let pipeline: AgentPipeline
    private let reminders: ReminderService

    /// Hands each new capture to the pipeline. The share extension turns this
    /// off and decides itself whether to analyze in place or leave it to the app.
    var processesImmediately = true

    init(container: ModelContainer, pipeline: AgentPipeline, reminders: ReminderService) {
        self.container = container
        self.pipeline = pipeline
        self.reminders = reminders
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Entry points

    @discardableResult
    func captureImage(_ data: Data, kind: CaptureKind = .screenshot, sourceURL: URL? = nil,
                      options: Options = Options()) async throws -> CapturedItem {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ImageProcessor.prepare(data)
        }.value

        let item = CapturedItem(kind: kind)
        item.imageData = prepared.storedData
        item.thumbnailData = prepared.thumbnailData
        item.imageWidth = Double(prepared.pixelWidth)
        item.imageHeight = Double(prepared.pixelHeight)
        item.sourceURL = sourceURL
        item.sourceAppName = options.sourceAppName ?? sourceURL.flatMap(TextHeuristics.sourceAppName(for:))
        return await finish(item, options: options)
    }

    @discardableResult
    func captureLink(_ url: URL, options: Options = Options()) async -> CapturedItem {
        let item = CapturedItem(kind: .link)
        item.sourceURL = url
        item.sourceAppName = options.sourceAppName ?? TextHeuristics.sourceAppName(for: url)
        return await finish(item, options: options)
    }

    /// A fleeting idea or pasted text. A bare URL becomes a link capture.
    @discardableResult
    func captureText(_ text: String, options: Options = Options()) async -> CapturedItem? {
        guard let text = text.trimmedNonEmpty else { return nil }
        if let url = TextHeuristics.standaloneURL(in: text) {
            return await captureLink(url, options: options)
        }
        let item = CapturedItem(kind: .note)
        item.extractedText = text
        if let firstLine = TextHeuristics.fallbackTitle(from: text, maxLength: 70) {
            item.title = firstLine
        }
        return await finish(item, options: options)
    }

    /// Everything from a drop, paste or share. Returns the new items.
    @discardableResult
    func capture(_ payload: CapturedPayload, options: Options = Options()) async -> [CapturedItem] {
        var created: [CapturedItem] = []
        let accompanyingText = payload.texts
            .filter { TextHeuristics.standaloneURL(in: $0) == nil }
            .joined(separator: "\n\n")
            .trimmedNonEmpty
        var itemOptions = options
        if itemOptions.notes == nil { itemOptions.notes = accompanyingText }

        if !payload.images.isEmpty {
            let sharedLink = payload.images.count == 1 ? payload.urls.first : nil
            for image in payload.images {
                if let item = try? await captureImage(image.data, sourceURL: image.sourceURL ?? sharedLink, options: itemOptions) {
                    created.append(item)
                }
            }
            return created
        }

        let urls = payload.urls + payload.texts.compactMap(TextHeuristics.standaloneURL(in:))
        if !urls.isEmpty {
            var seen = Set<URL>()
            for url in urls where seen.insert(url).inserted {
                created.append(await captureLink(url, options: itemOptions))
            }
            return created
        }

        if let text = payload.texts.joined(separator: "\n\n").trimmedNonEmpty,
           let item = await captureText(text, options: options) {
            created.append(item)
        }
        return created
    }

    func capture(providers: [NSItemProvider], options: Options = Options()) async -> [CapturedItem] {
        let payload = await ItemProviderLoader.load(providers)
        return await capture(payload, options: options)
    }

    /// Files chosen in an open panel or the Files app.
    func capture(fileURLs: [URL], options: Options = Options()) async -> [CapturedItem] {
        var payload = CapturedPayload()
        for url in fileURLs {
            guard let data = await ItemProviderLoader.readFile(url) else { continue }
            if ImageProcessor.isImageFile(url) {
                payload.images.append(.init(data: data, sourceURL: nil))
            } else if let text = String(data: data, encoding: .utf8)?.trimmedNonEmpty {
                payload.texts.append(text)
            }
        }
        return await capture(payload, options: options)
    }

    // MARK: Private

    private func finish(_ item: CapturedItem, options: Options) async -> CapturedItem {
        if let notes = options.notes?.trimmedNonEmpty { item.userNotes = notes }
        if !options.tags.isEmpty { item.tags = TagNormalizer.normalize(options.tags) }
        item.touch()
        context.insert(item)
        let agentIDs = options.agentIDs ?? pipeline.defaultAgentIDsForNewCapture()
        item.pendingAgentIds = agentIDs
        item.processingState = .pending
        try? context.save()

        if let reminderDate = options.reminderDate {
            await reminders.schedule(item, at: reminderDate)
        }
        if processesImmediately {
            pipeline.schedule(item, agentIDs: agentIDs)
        }
        return item
    }
}
