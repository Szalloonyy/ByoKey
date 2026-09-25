//
//  CapturedItem+Logic.swift
//  RecallDrop
//
//  Behavior around the stored properties: typed accessors, display values,
//  applying agent results, search indexing and export.
//

import Foundation
import SwiftData
import RecallDropKit

extension CapturedItem {
    var kind: CaptureKind {
        get { CaptureKind(rawValue: kindRaw) ?? .screenshot }
        set { kindRaw = newValue.rawValue }
    }

    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .idle }
        set { processingStateRaw = newValue.rawValue }
    }

    /// Cheap check that avoids loading the external image data.
    var hasImage: Bool { imageWidth > 0 && imageHeight > 0 }

    var displayTitle: String {
        if let title = title.trimmedNonEmpty { return title }
        if let linkTitle = linkTitle?.trimmedNonEmpty { return linkTitle }
        if let text = extractedText, let fallback = TextHeuristics.fallbackTitle(from: text) { return fallback }
        if let url = sourceURL { return url.host ?? url.absoluteString }
        return "Untitled \(kind.label)"
    }

    /// One or two lines for cards: the summary, the link description or the start of the text.
    var previewText: String? {
        if let summary = aiSummary?.trimmedNonEmpty { return summary }
        if let description = linkDescription?.trimmedNonEmpty { return description }
        if let text = extractedText?.trimmedNonEmpty {
            let snippet = TextHeuristics.previewSnippet(from: text, maxLength: 220)
            return snippet.isEmpty ? nil : snippet
        }
        return userNotes?.trimmedNonEmpty
    }

    /// Height ÷ width of the image, clamped for the grid.
    var aspectRatio: Double {
        MasonryDistributor.clampedAspectRatio(width: imageWidth, height: imageHeight)
    }

    var hasReminder: Bool { reminderDate != nil }

    var lastUsedAgentColor: AgentColor { AgentColor(loose: lastUsedAgentColorName ?? "indigo") }

    func isReminderOverdue(now: Date = Date()) -> Bool {
        guard let reminderDate else { return false }
        return reminderDate <= now
    }

    var openActionItems: [String] {
        actionItems.filter { !completedActionItems.contains($0) }
    }

    var sortedRuns: [AgentRun] {
        agentRuns.sorted { $0.createdAt > $1.createdAt }
    }

    var latestRun: AgentRun? { sortedRuns.first }

    var sortedChatMessages: [ChatMessage] {
        chatMessages.sorted { $0.createdAt < $1.createdAt }
    }

    var ocrLines: [OCRLine] {
        get {
            guard let ocrLinesData else { return [] }
            return (try? JSONDecoder().decode([OCRLine].self, from: ocrLinesData)) ?? []
        }
        set {
            ocrLinesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// Whether on-device text recognition has already run (an empty string
    /// means "ran, found nothing").
    var hasRecognizedText: Bool { extractedText != nil }

    // MARK: Mutations

    /// Marks the item as changed and rebuilds its search index.
    func touch(_ date: Date = Date()) {
        updatedAt = date
        refreshSearchIndex()
    }

    func refreshSearchIndex() {
        searchIndex = computedSearchIndex()
    }

    func computedSearchIndex() -> String {
        var agentNames = Set(agentRuns.map(\.agentName))
        if let lastUsedAgentName { agentNames.insert(lastUsedAgentName) }
        return SearchText.buildIndex(
            title: displayTitle,
            extractedText: extractedText,
            notes: userNotes,
            summary: aiSummary,
            tags: tags,
            actionItems: actionItems,
            sourceURL: sourceURL,
            agentName: nil,
            extra: [linkTitle, linkDescription, sourceAppName].compactMap { $0 } + agentNames.sorted()
        )
    }

    func toggleActionItem(_ step: String) {
        if let index = completedActionItems.firstIndex(of: step) {
            completedActionItems.remove(at: index)
        } else {
            completedActionItems.append(step)
        }
        touch()
    }

    func setTags(_ newTags: [String]) {
        tags = TagNormalizer.normalize(newTags, limit: 30)
        touch()
    }

    /// Takes over an agent's result. Tags are merged; the title only changes
    /// while the user hasn't renamed the item.
    func apply(_ output: AgentOutput, agentID: UUID?, agentName: String, agentEmoji: String, agentColorName: String) {
        if !isTitleUserEdited, let newTitle = output.title.trimmedNonEmpty {
            title = newTitle
        }
        if let summary = output.summary.trimmedNonEmpty {
            aiSummary = summary
        }
        if !output.actionableSteps.isEmpty {
            actionItems = output.actionableSteps
            completedActionItems = completedActionItems.filter { output.actionableSteps.contains($0) }
        }
        tags = TagNormalizer.merge(tags, with: output.tags, limit: 30)
        if let reminder = output.suggestedReminder {
            suggestedReminderDate = reminder
        }
        lastUsedAgentId = agentID
        lastUsedAgentName = agentName
        lastUsedAgentEmoji = agentEmoji
        lastUsedAgentColorName = agentColorName
        touch()
    }

    /// Shows the results of an earlier run again ("switch agent").
    func adopt(_ run: AgentRun) {
        apply(run.output, agentID: run.agentId, agentName: run.agentName, agentEmoji: run.agentEmoji,
              agentColorName: run.agentColorName)
    }

    // MARK: Agent context

    func captureContext(image: AIImageInput?, previous: [PreviousAnalysis] = []) -> CaptureContext {
        CaptureContext(
            kind: kind.contextKind,
            title: isTitleUserEdited ? title : title.trimmedNonEmpty,
            extractedText: extractedText,
            userNotes: userNotes,
            sourceURL: sourceURL,
            sourceAppName: sourceAppName,
            linkTitle: linkTitle,
            linkDescription: linkDescription,
            existingTags: tags,
            capturedAt: createdAt,
            image: image,
            existingSummary: aiSummary,
            existingActionItems: actionItems,
            previousAnalyses: previous
        )
    }

    // MARK: Search

    var searchFlags: Set<SearchQuery.Flag> {
        var flags: Set<SearchQuery.Flag> = []
        if isPinned { flags.insert(.pinned) }
        if isArchived { flags.insert(.archived) }
        if kind == .link { flags.insert(.link) }
        if kind == .note { flags.insert(.note) }
        if hasImage { flags.insert(.image) }
        if hasReminder { flags.insert(.reminder) }
        if !openActionItems.isEmpty { flags.insert(.actions) }
        if agentRuns.isEmpty { flags.insert(.unanalyzed) }
        if processingState == .failed { flags.insert(.failed) }
        return flags
    }

    var searchRecord: SearchRecord {
        var agents = agentRuns.map { SearchText.fold($0.agentName) }
        if let lastUsedAgentName { agents.append(SearchText.fold(lastUsedAgentName)) }
        return SearchRecord(
            foldedTitle: SearchText.fold(displayTitle),
            foldedIndex: searchIndex.isEmpty ? computedSearchIndex() : searchIndex,
            tags: tags,
            flags: searchFlags,
            foldedAgentNames: agents
        )
    }

    // MARK: Export

    var exportRepresentation: ExportedCapture {
        ExportedCapture(
            id: id,
            createdAt: createdAt,
            kind: kind.rawValue,
            title: displayTitle,
            summary: aiSummary,
            actionItems: actionItems,
            completedActionItems: completedActionItems,
            tags: tags,
            extractedText: extractedText,
            notes: userNotes,
            sourceURL: sourceURL,
            sourceApp: sourceAppName,
            reminderDate: reminderDate,
            isPinned: isPinned,
            isArchived: isArchived,
            lastAgentName: lastUsedAgentName
        )
    }

    var markdownExport: String {
        CaptureMarkdownExporter.markdown(for: exportRepresentation)
    }

    /// Notification body for reminders.
    var reminderBody: String {
        if let step = openActionItems.first { return "Next: \(step)" }
        if let preview = previewText { return TextHeuristics.truncate(preview, maxLength: 160) }
        return "You saved this \(kind.label.lowercased()) to come back to it."
    }

    // MARK: Fetching

    static func fetch(id itemID: UUID, in context: ModelContext) -> CapturedItem? {
        var descriptor = FetchDescriptor<CapturedItem>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

extension AgentRun {
    var output: AgentOutput {
        AgentOutput(
            title: title,
            summary: summary,
            actionableSteps: actionableSteps,
            tags: tags,
            thoughtProcess: thoughtProcess,
            suggestedReminder: suggestedReminder,
            confidence: confidence
        )
    }

    var agentColor: AgentColor { AgentColor(loose: agentColorName) }

    var provider: AIProviderKind? { AIProviderKind(rawValue: providerRaw) }

    var tokenSummary: String? {
        switch (inputTokens, outputTokens) {
        case (nil, nil): return nil
        case let (input, output): return "\(input.map(String.init) ?? "–") in · \(output.map(String.init) ?? "–") out"
        }
    }
}

extension ChatMessage {
    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }
}

extension String {
    /// Trimmed copy, or `nil` when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
