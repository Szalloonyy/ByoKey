//
//  AgentPipeline.swift
//  RecallDrop
//
//  The agent execution engine. For every queued item it runs:
//
//      link preview (links)  →  Vision OCR (images)  →  agent chain
//
//  Each agent receives the image, the OCR text, the user's notes and the
//  results of earlier agents in the chain, and returns structured output
//  (title, summary, actionable steps, tags, thought process) that is stored
//  as an AgentRun. Work items survive restarts: the queue is persisted as
//  `pendingAgentIds` + `processingState` on the item itself, which is also
//  how the share extension hands work to the app.
//
//  Agents that need an AI provider while none is usable (Offline Only, or no
//  API key yet) wait on the item as pending work; the capture gets the
//  on-device analysis meanwhile, and the agents run once AI is available.
//
//  All model access happens on the main actor; OCR, image encoding and
//  network calls run elsewhere and only exchange Sendable values.
//

import Foundation
import Observation
import SwiftData
import RecallDropKit

@MainActor
@Observable
final class AgentPipeline {
    enum Phase: Equatable {
        case queued
        case fetchingLink
        case recognizingText
        case analyzing(agentName: String, step: Int, total: Int)

        var label: String {
            switch self {
            case .queued: "Waiting…"
            case .fetchingLink: "Loading link preview…"
            case .recognizingText: "Reading text…"
            case .analyzing(let name, let step, let total):
                total > 1 ? "\(name) (\(step)/\(total))…" : "\(name) is analyzing…"
            }
        }
    }

    /// Pseudo agent that runs the on-device analyzer instead of an AI provider.
    nonisolated static let onDeviceAgentID = UUID(uuidString: "5E1D0C8A-1D3B-4F57-9C51-2A7E9B3E00FF")!

    private(set) var phases: [UUID: Phase] = [:]

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let catalog: ModelCatalogStore
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var forcedOCR: Set<UUID> = []
    /// Requests that arrived while the item was being processed; they run next.
    @ObservationIgnored private var followUps: [UUID: FollowUp] = [:]
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private let maxConcurrentJobs = 2

    /// Called after an item finished processing (successfully or not).
    @ObservationIgnored var onItemFinished: ((UUID) -> Void)?

    /// Set in the share extension: items it processes are claimed in the shared
    /// defaults, so the app does not work on them at the same time.
    @ObservationIgnored var claimsWork = false

    private struct FollowUp {
        var agentIDs: [UUID] = []
        var forceOCR = false
    }

    init(container: ModelContainer, settings: SettingsStore, catalog: ModelCatalogStore) {
        self.container = container
        self.settings = settings
        self.catalog = catalog
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Public API

    func phase(for itemID: UUID) -> Phase? { phases[itemID] }

    func isBusy(_ itemID: UUID) -> Bool { phases[itemID] != nil }

    var busyCount: Int { phases.count }

    /// The agents a new capture should get, based on the user's settings.
    func defaultAgentIDsForNewCapture() -> [UUID] {
        guard settings.autoAnalyze else { return [] }
        if settings.offlineOnly || settings.aiUnavailableReason != nil {
            // Without a usable provider new captures still get titles and tags on device.
            return [Self.onDeviceAgentID]
        }
        return defaultAgentID().map { [$0] } ?? [Self.onDeviceAgentID]
    }

    func defaultAgentID() -> UUID? {
        let agents = AgentConfig.allSorted(in: context)
        return (agents.first(where: \.isDefault) ?? agents.first)?.id
    }

    /// Queues processing for `item`. `agentIDs` may be empty (text recognition only).
    /// While the item is being processed, the request runs right after the current job.
    func schedule(_ item: CapturedItem, agentIDs: [UUID], forceOCR: Bool = false, prioritized: Bool = false) {
        if running[item.id] != nil {
            var followUp = followUps[item.id] ?? FollowUp()
            followUp.agentIDs = Self.merged(followUp.agentIDs, agentIDs)
            followUp.forceOCR = followUp.forceOCR || forceOCR
            followUps[item.id] = followUp
            return
        }
        // Work that is still pending (queued, or waiting for AI) is kept.
        item.pendingAgentIds = item.processingState == .pending
            ? Self.merged(item.pendingAgentIds, agentIDs)
            : agentIDs
        item.processingState = .pending
        item.processingError = nil
        if forceOCR { forcedOCR.insert(item.id) }
        claim([item.id])
        save()
        enqueue(item.id, prioritized: prioritized)
    }

    /// Runs agents now (e.g. "Re-run with Action Planner" in the detail view).
    func run(_ agentIDs: [UUID], on item: CapturedItem) {
        guard !agentIDs.isEmpty else { return }
        schedule(item, agentIDs: agentIDs, prioritized: true)
    }

    func rerunTextRecognition(on item: CapturedItem) {
        schedule(item, agentIDs: [], forceOCR: true, prioritized: true)
    }

    func cancel(_ itemID: UUID) {
        queue.removeAll { $0 == itemID }
        forcedOCR.remove(itemID)
        followUps.removeValue(forKey: itemID)
        if let task = running[itemID] {
            task.cancel()
        } else {
            phases[itemID] = nil
            if let item = CapturedItem.fetch(id: itemID, in: context) {
                item.pendingAgentIds = []
                item.processingState = item.agentRuns.isEmpty ? .idle : .completed
                save()
            }
        }
    }

    /// Stops all work for an item that is about to be deleted, without touching the model.
    func discard(_ itemID: UUID) {
        queue.removeAll { $0 == itemID }
        forcedOCR.remove(itemID)
        followUps.removeValue(forKey: itemID)
        if let task = running[itemID] {
            task.cancel()
        } else {
            phases[itemID] = nil
        }
    }

    /// Marks items as handled by this process (share extension only).
    func claim(_ itemIDs: [UUID]) {
        guard claimsWork else { return }
        settings.claimProcessing(of: itemIDs)
    }

    func releaseClaims(_ itemIDs: [UUID]) {
        guard claimsWork else { return }
        settings.releaseProcessing(of: itemIDs)
    }

    /// True while `item` holds agents that need an AI provider and none is
    /// usable. They run once AI becomes available.
    func isWaitingForAI(_ item: CapturedItem) -> Bool {
        guard item.processingState == .pending, phases[item.id] == nil else { return false }
        let agentIDs = item.pendingAgentIds
        guard !agentIDs.isEmpty, !agentIDs.contains(Self.onDeviceAgentID) else { return false }
        return settings.aiUnavailableReason != nil
    }

    /// Picks up work left by the share extension or an interrupted run, and
    /// agents that waited for AI once it is available. Call it again after
    /// the AI configuration changed.
    func resumePendingWork() {
        let pending = ProcessingState.pending.rawValue
        let fetchingLink = ProcessingState.fetchingLink.rawValue
        let recognizing = ProcessingState.recognizing.rawValue
        let analyzing = ProcessingState.analyzing.rawValue
        let descriptor = FetchDescriptor<CapturedItem>(
            predicate: #Predicate {
                $0.processingStateRaw == pending || $0.processingStateRaw == fetchingLink
                    || $0.processingStateRaw == recognizing || $0.processingStateRaw == analyzing
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let items = try? context.fetch(descriptor) else { return }
        let claims = claimsWork ? [:] : settings.activeProcessingClaims()
        var nextClaimExpiry: Date?
        for item in items where running[item.id] == nil && !queue.contains(item.id) {
            if let claimed = claims[item.id] {
                // The share extension is working on it right now; look again later.
                let expiry = claimed.addingTimeInterval(SettingsStore.claimLifetime)
                nextClaimExpiry = min(nextClaimExpiry ?? expiry, expiry)
                continue
            }
            // Already processed and only waiting for AI: nothing to do yet.
            if !item.agentRuns.isEmpty, isWaitingForAI(item) { continue }
            if item.processingState != .pending {
                item.processingState = .pending
            }
            enqueue(item.id, prioritized: false)
        }
        save()
        if let nextClaimExpiry {
            scheduleRecheck(at: nextClaimExpiry)
        }
    }

    private func scheduleRecheck(at date: Date) {
        recheckTask?.cancel()
        let delay = max(date.timeIntervalSinceNow, 0) + 1
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumePendingWork()
        }
    }

    // MARK: Queue

    private func enqueue(_ itemID: UUID, prioritized: Bool) {
        guard running[itemID] == nil else { return }
        queue.removeAll { $0 == itemID }
        if prioritized {
            queue.insert(itemID, at: 0)
        } else {
            queue.append(itemID)
        }
        phases[itemID] = .queued
        startNextJobs()
    }

    private func startNextJobs() {
        while running.count < maxConcurrentJobs, !queue.isEmpty {
            let itemID = queue.removeFirst()
            running[itemID] = Task { [weak self] in
                await self?.process(itemID)
                self?.jobFinished(itemID)
            }
        }
    }

    private func jobFinished(_ itemID: UUID) {
        running[itemID] = nil
        phases[itemID] = nil
        releaseClaims([itemID])
        onItemFinished?(itemID)
        if let followUp = followUps.removeValue(forKey: itemID), let item = currentItem(itemID) {
            schedule(item, agentIDs: followUp.agentIDs, forceOCR: followUp.forceOCR, prioritized: true)
        }
        startNextJobs()
    }

    private func setPhase(_ phase: Phase, for itemID: UUID) {
        phases[itemID] = phase
    }

    // MARK: Processing

    private func process(_ itemID: UUID) async {
        guard let item = currentItem(itemID) else { return }
        let agentIDs = item.pendingAgentIds
        let force = forcedOCR.remove(itemID) != nil
        let activity = BackgroundActivity(reason: "Analyzing a capture")
        defer { activity.end() }

        do {
            try await enrichLinkIfNeeded(itemID, force: force)
            try await recognizeTextIfNeeded(itemID, force: force)
            let waitingAgentIDs = try await runAgents(agentIDs, on: itemID)
            guard let item = currentItem(itemID) else { return }
            item.pendingAgentIds = waitingAgentIDs
            if waitingAgentIDs.isEmpty {
                item.processingState = item.agentRuns.isEmpty ? .idle : .completed
            } else {
                // Stays pending until resumePendingWork() finds AI available.
                item.processingState = .pending
            }
            item.processingError = nil
            item.touch()
            save()
        } catch {
            guard let item = currentItem(itemID) else { return }
            let aiError = AIError.from(error)
            if aiError == .cancelled || Task.isCancelled {
                item.pendingAgentIds = []
                item.processingState = item.agentRuns.isEmpty ? .idle : .completed
            } else {
                item.processingState = .failed
                item.processingError = Self.describe(error)
            }
            save()
        }
    }

    /// Loads the page's title, description, preview image and – for posts –
    /// its text. `force` reloads a page that was loaded before.
    private func enrichLinkIfNeeded(_ itemID: UUID, force: Bool) async throws {
        guard let item = currentItem(itemID), item.kind == .link, force || !item.linkMetadataFetched,
              settings.fetchLinkPreviews, let url = item.sourceURL else { return }
        setPhase(.fetchingLink, for: itemID)
        item.processingState = .fetchingLink
        save()

        let metadata = await LinkMetadataFetcher.fetch(url)
        try Task.checkCancellation()
        // Nothing came back (offline, timeout, blocked): try again next time.
        guard !metadata.isEmpty else { return }
        var preview: PreparedImage?
        if let imageURL = metadata.imageURL, currentItem(itemID)?.hasImage == false {
            preview = await Self.downloadPreviewImage(imageURL)
        }

        guard let item = currentItem(itemID) else { return }
        item.linkMetadataFetched = true
        if let title = metadata.title?.trimmedNonEmpty { item.linkTitle = title }
        if let summary = metadata.summary?.trimmedNonEmpty { item.linkDescription = summary }
        if item.sourceAppName == nil {
            item.sourceAppName = metadata.siteName ?? TextHeuristics.sourceAppName(for: url)
        }
        if let body = metadata.bodyText?.trimmedNonEmpty, force || item.extractedText?.trimmedNonEmpty == nil {
            item.extractedText = body
            item.ocrConfidence = nil
            item.ocrLines = []
        }
        if !item.isTitleUserEdited, item.title.trimmedNonEmpty == nil, let title = metadata.title?.trimmedNonEmpty {
            item.title = TextHeuristics.truncate(title, maxLength: AgentOutputParser.maximumTitleLength)
        }
        if let preview {
            item.imageData = preview.storedData
            item.thumbnailData = preview.thumbnailData
            item.imageWidth = Double(preview.pixelWidth)
            item.imageHeight = Double(preview.pixelHeight)
        }
        item.touch()
        save()
    }

    private func recognizeTextIfNeeded(_ itemID: UUID, force: Bool) async throws {
        guard let item = currentItem(itemID), item.hasImage, let imageData = item.imageData,
              force || item.extractedText == nil else { return }
        // A link's own page text beats OCR of its preview picture, so it is kept.
        if item.kind == .link, item.extractedText?.trimmedNonEmpty != nil, item.ocrConfidence == nil { return }

        setPhase(.recognizingText, for: itemID)
        item.processingState = .recognizing
        save()

        let result = try await OCRService.shared.recognizeText(
            in: imageData,
            accuracy: settings.ocrAccuracy,
            languageCorrection: settings.ocrLanguageCorrection
        )
        try Task.checkCancellation()

        guard let item = currentItem(itemID) else { return }
        item.extractedText = result.text
        item.ocrConfidence = result.averageConfidence
        item.ocrLines = result.lines
        if !item.isTitleUserEdited, item.title.trimmedNonEmpty == nil {
            item.title = OCRLayout.headlineCandidate(result.lines)
                ?? TextHeuristics.fallbackTitle(from: result.text)
                ?? ""
        }
        item.touch()
        save()
    }

    /// Runs the agents in order. Returns the agents that need an AI provider
    /// while none is usable; they wait, and a capture without any result
    /// gets the on-device analysis in the meantime.
    private func runAgents(_ agentIDs: [UUID], on itemID: UUID) async throws -> [UUID] {
        guard !agentIDs.isEmpty else { return [] }
        var wantsOnDevice = false
        var personas: [AgentPersona] = []
        for agentID in agentIDs {
            if agentID == Self.onDeviceAgentID {
                wantsOnDevice = true
            } else if let persona = AgentConfig.fetch(id: agentID, in: context)?.persona {
                personas.append(persona)
            }
        }

        let needsInterimResult = settings.aiUnavailableReason != nil && !personas.isEmpty
            && currentItem(itemID)?.agentRuns.isEmpty == true
        if wantsOnDevice || needsInterimResult {
            try await runOnDeviceAnalysis(on: itemID)
            markFinished(Self.onDeviceAgentID, on: itemID)
        }

        var previous: [PreviousAnalysis] = []
        for (index, persona) in personas.enumerated() {
            try Task.checkCancellation()
            // Offline Only may have been turned on (or the key removed) meanwhile.
            guard settings.aiUnavailableReason == nil else {
                return personas[index...].map(\.id)
            }
            claim([itemID])
            setPhase(.analyzing(agentName: persona.displayName, step: index + 1, total: personas.count), for: itemID)
            let output = try await analyze(itemID, with: persona, previous: previous, chainPosition: index)
            previous.append(PreviousAnalysis(agentName: persona.displayName, output: output))
            markFinished(persona.id, on: itemID)
        }
        return []
    }

    /// Takes a finished agent off the item's stored work, so an interrupted
    /// chain resumes after it instead of running it again.
    private func markFinished(_ agentID: UUID, on itemID: UUID) {
        guard let item = currentItem(itemID), let index = item.pendingAgentIds.firstIndex(of: agentID) else { return }
        item.pendingAgentIds.remove(at: index)
        save()
    }

    private func analyze(_ itemID: UUID, with persona: AgentPersona, previous: [PreviousAnalysis],
                         chainPosition: Int) async throws -> AgentOutput {
        guard let startingItem = currentItem(itemID) else { throw CancellationError() }
        startingItem.processingState = .analyzing
        save()

        let provider = settings.provider
        let client = try AIClientFactory.makeClient(configuration: settings.providerConfiguration(for: provider))
        let model = persona.resolvedModel(defaultModel: settings.defaultModel(for: provider))

        var image: AIImageInput?
        if settings.sendImages, startingItem.hasImage, let data = startingItem.imageData {
            image = await Task.detached(priority: .userInitiated) {
                ImageProcessor.uploadJPEG(from: data).map { AIImageInput(data: $0, mimeType: "image/jpeg") }
            }.value
            try Task.checkCancellation()
        }
        // The item may have been deleted while the image was encoded.
        guard let item = currentItem(itemID) else { throw CancellationError() }

        let request = AgentPromptBuilder.analysisRequest(
            persona: persona,
            context: item.captureContext(image: image, previous: previous),
            model: model,
            environment: PromptEnvironment(responseLanguage: settings.responseLanguage),
            maxOutputTokens: catalog.maxOutputTokens(model: model, provider: provider, settings: settings),
            includeImage: image != nil,
            useJSONMode: settings.useJSONMode
        )

        let started = Date()
        let result = try await client.completeAdaptively(request)
        try Task.checkCancellation()
        let parsed = AgentOutputParser.parse(result.response.text)

        guard let resultItem = currentItem(itemID) else { throw CancellationError() }
        let run = AgentRun()
        run.agentId = persona.id
        run.agentName = persona.displayName
        run.agentEmoji = persona.emoji
        run.agentColorName = persona.colorName
        run.modelIdentifier = result.response.model ?? model
        run.providerRaw = provider.rawValue
        run.title = parsed.output.title
        run.summary = parsed.output.summary
        run.actionableSteps = parsed.output.actionableSteps
        run.tags = parsed.output.tags
        run.thoughtProcess = parsed.output.thoughtProcess
        run.suggestedReminder = parsed.output.suggestedReminder
        run.confidence = parsed.output.confidence
        run.rawOutput = result.response.text
        run.durationSeconds = Date().timeIntervalSince(started)
        run.inputTokens = result.response.usage?.inputTokens
        run.outputTokens = result.response.usage?.outputTokens
        run.usedImage = result.finalRequest.containsImages
        run.wasStructured = parsed.wasStructured
        run.chainPosition = chainPosition
        run.adjustmentNotes = Self.notes(for: result.adjustments)
        context.insert(run)
        run.item = resultItem

        resultItem.apply(parsed.output, agentID: persona.id, agentName: persona.displayName, agentEmoji: persona.emoji,
                         agentColorName: persona.colorName)
        save()
        return parsed.output
    }

    private func runOnDeviceAnalysis(on itemID: UUID) async throws {
        guard let item = currentItem(itemID) else { return }
        setPhase(.analyzing(agentName: LocalAnalysis.agentName, step: 1, total: 1), for: itemID)
        let kind = item.kind
        let text = item.extractedText?.trimmedNonEmpty ?? item.userNotes
        let lines = item.ocrLines
        let sourceURL = item.sourceURL
        let linkTitle = item.linkTitle
        let started = Date()
        let output = await Task.detached(priority: .userInitiated) {
            LocalAnalyzer.analyze(kind: kind, text: text, lines: lines, sourceURL: sourceURL, linkTitle: linkTitle)
        }.value
        try Task.checkCancellation()

        guard let item = currentItem(itemID) else { return }
        let run = AgentRun()
        run.agentId = Self.onDeviceAgentID
        run.agentName = LocalAnalysis.agentName
        run.agentEmoji = "📱"
        run.agentColorName = AgentColor.gray.rawValue
        run.modelIdentifier = "Vision + NaturalLanguage"
        run.title = output.title
        run.summary = output.summary
        run.actionableSteps = output.actionableSteps
        run.tags = output.tags
        run.thoughtProcess = output.thoughtProcess
        run.suggestedReminder = output.suggestedReminder
        run.durationSeconds = Date().timeIntervalSince(started)
        run.isOffline = true
        context.insert(run)
        run.item = item
        item.apply(output, agentID: Self.onDeviceAgentID, agentName: LocalAnalysis.agentName, agentEmoji: "📱",
                   agentColorName: AgentColor.gray.rawValue)
        save()
    }

    // MARK: Helpers

    private func currentItem(_ itemID: UUID) -> CapturedItem? {
        guard let item = CapturedItem.fetch(id: itemID, in: context), !item.isDeleted else { return nil }
        return item
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private nonisolated static func downloadPreviewImage(_ url: URL) async -> PreparedImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(LinkMetadataFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 15_000_000 else { return nil }
        return await Task.detached(priority: .utility) {
            try? ImageProcessor.prepare(data)
        }.value
    }

    /// `base` followed by the entries of `extra` it does not contain yet.
    private static func merged(_ base: [UUID], _ extra: [UUID]) -> [UUID] {
        var result = base
        for id in extra where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private static func notes(for adjustments: AIRequestAdjustments) -> [String] {
        var notes: [String] = []
        if adjustments.contains(.droppedImages) {
            notes.append("The model does not accept images, so only the extracted text was analyzed.")
        }
        if adjustments.contains(.droppedTemperature) {
            notes.append("The model uses a fixed temperature; the agent's temperature was not applied.")
        }
        if adjustments.contains(.reducedMaxTokens) {
            notes.append("The output limit was lowered to fit the model or the account balance.")
        }
        if adjustments.contains(.droppedJSONMode) {
            notes.append("The server does not support JSON mode; the reply was parsed from text.")
        }
        return notes
    }

    static func describe(_ error: any Error) -> String {
        if let aiError = error as? AIError {
            return [aiError.errorDescription, aiError.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
