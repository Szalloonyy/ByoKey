//
//  ShareExtensionModel.swift
//  RecallDrop Share Extension
//
//  Loads what the host app shared (Safari, Instagram, X, Photos, …), saves
//  it to the shared SwiftData store and – if the user picked an agent –
//  analyzes it right away. Anything unfinished when the sheet closes is
//  completed by the app on its next launch.
//

import Foundation
import Observation
import SwiftData
import RecallDropKit

@MainActor
@Observable
final class ShareExtensionModel {
    enum Phase: Equatable {
        case loading
        case ready
        case saving
        case analyzing(String)
        case done
        case failed(String)
    }

    var phase: Phase = .loading
    private(set) var payload = CapturedPayload()
    private(set) var previewImages: [DecodedImage] = []
    var note = ""
    var choice: AgentChoice = .none
    var reminder: ReminderPreset?
    private(set) var resultTitle: String?
    private(set) var resultSummary: String?
    private(set) var resultSteps: [String] = []

    let environment: AppEnvironment
    @ObservationIgnored private let extensionItems: [NSExtensionItem]
    @ObservationIgnored private let onComplete: () -> Void
    @ObservationIgnored private let onCancel: () -> Void
    @ObservationIgnored private var savedItemIDs: [UUID] = []

    init(environment: AppEnvironment, extensionItems: [NSExtensionItem],
         onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.environment = environment
        self.extensionItems = extensionItems
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var aiUnavailableReason: String? { environment.settings.aiUnavailableReason }

    var summaryLine: String {
        var parts: [String] = []
        if !payload.images.isEmpty { parts.append("\(payload.images.count) image\(payload.images.count == 1 ? "" : "s")") }
        if !payload.urls.isEmpty { parts.append("\(payload.urls.count) link\(payload.urls.count == 1 ? "" : "s")") }
        if payload.images.isEmpty && payload.urls.isEmpty && !payload.texts.isEmpty { parts.append("text") }
        return parts.joined(separator: " · ")
    }

    func load() async {
        var providers: [NSItemProvider] = []
        var sharedTexts: [String] = []
        for item in extensionItems {
            providers.append(contentsOf: item.attachments ?? [])
            if let text = item.attributedContentText?.string.trimmedNonEmpty {
                sharedTexts.append(text)
            }
        }
        var loaded = await ItemProviderLoader.load(providers)
        for text in sharedTexts where !loaded.texts.contains(text) {
            loaded.texts.append(text)
        }
        payload = loaded

        let imageData = loaded.images.prefix(4).map(\.data)
        previewImages = await Task.detached(priority: .userInitiated) {
            imageData.compactMap { ImageProcessor.decodedImage(from: $0, maxPixelSize: 360) }
        }.value

        choice = AgentChoice(agentIDs: environment.pipeline.defaultAgentIDsForNewCapture())
        if case .inMemoryFallback = environment.persistenceIssue {
            // Anything saved now would be lost when the sheet closes.
            phase = .failed("RecallDrop could not open its library. Open the RecallDrop app once, then share again.")
        } else {
            phase = loaded.isEmpty ? .failed("There is nothing RecallDrop can save in this item.") : .ready
        }
    }

    func save() async {
        guard phase == .ready else { return }
        phase = .saving
        let reminderDate = reminder?.date(relativeTo: Date(), schedule: environment.settings.reminderSchedule)
        let options = CaptureService.Options(agentIDs: choice.agentIDs, notes: note.trimmedNonEmpty, reminderDate: reminderDate)
        let items = await environment.capture.capture(payload, options: options)
        guard !items.isEmpty else {
            phase = .failed("The item could not be saved.")
            return
        }
        savedItemIDs = items.map(\.id)

        guard !choice.agentIDs.isEmpty else {
            // Nothing to analyze here; the app reads the text right away.
            environment.pipeline.releaseClaims(savedItemIDs)
            notifyApp()
            onComplete()
            return
        }
        // The items stay claimed while this extension analyzes them.
        notifyApp()

        // Analyze here while the sheet is open; the app finishes anything left over.
        let label = agentLabel
        phase = .analyzing(label)
        for item in items {
            environment.pipeline.schedule(item, agentIDs: choice.agentIDs)
        }
        await waitForPipeline(timeout: 90)
        notifyApp()

        if let first = savedItemIDs.first,
           let item = CapturedItem.fetch(id: first, in: environment.container.mainContext) {
            resultTitle = item.displayTitle
            resultSummary = item.aiSummary
            resultSteps = Array(item.openActionItems.prefix(3))
            if item.processingState == .failed, let error = item.processingError {
                resultSummary = "Saved, but the analysis failed: \(error) Open the capture in RecallDrop to try again."
            }
        }
        phase = .done
    }

    func finish() {
        onComplete()
    }

    func cancel() {
        if savedItemIDs.isEmpty {
            onCancel()
        } else {
            // Already saved: leave pending work for the app and close normally.
            onComplete()
        }
    }

    private var agentLabel: String {
        switch choice {
        case .none: "Saving…"
        case .onDevice: "\(LocalAnalysis.agentName)…"
        case .agent(let id):
            AgentConfig.fetch(id: id, in: environment.container.mainContext).map { "\($0.emoji) \($0.displayName) is analyzing…" }
                ?? "Analyzing…"
        }
    }

    private func waitForPipeline(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, savedItemIDs.contains(where: { environment.pipeline.isBusy($0) }) {
            if case .analyzing = phase, let first = savedItemIDs.first,
               let current = environment.pipeline.phase(for: first) {
                phase = .analyzing(current.label)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func notifyApp() {
        environment.settings.markExternalChange()
        ExternalChangeMonitor.postChange()
    }
}
