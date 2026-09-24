//
//  ChatSession.swift
//  RecallDrop
//
//  "Chat with Screenshot": a streaming conversation about one capture,
//  held in the voice of the selected agent. The image, OCR text, summary
//  and notes travel as context; messages are stored with the item.
//

import Foundation
import Observation
import SwiftData
import RecallDropKit

@MainActor
@Observable
final class ChatSession {
    private(set) var streamingText = ""
    private(set) var isStreaming = false
    var errorMessage: String?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Messages beyond this many are left out of the request to bound cost.
    private let historyLimit = 24

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var context: ModelContext { environment.container.mainContext }

    func send(_ text: String, about item: CapturedItem, persona: AgentPersona, includeImage: Bool) {
        guard let text = text.trimmedNonEmpty, !isStreaming else { return }
        let message = ChatMessage(role: .user, content: text)
        context.insert(message)
        message.item = item
        try? context.save()

        errorMessage = nil
        isStreaming = true
        streamingText = ""
        let itemID = item.id
        task = Task { [weak self] in
            await self?.respond(itemID: itemID, persona: persona, includeImage: includeImage)
        }
    }

    func stop() {
        task?.cancel()
    }

    func clearConversation(of item: CapturedItem) {
        stop()
        for message in item.chatMessages {
            context.delete(message)
        }
        try? context.save()
        errorMessage = nil
    }

    private func respond(itemID: UUID, persona: AgentPersona, includeImage: Bool) async {
        defer {
            isStreaming = false
            streamingText = ""
            task = nil
        }
        let settings = environment.settings
        guard let item = CapturedItem.fetch(id: itemID, in: context) else { return }

        do {
            if settings.offlineOnly { throw AIError.offlineMode }
            let provider = settings.provider
            let client = try AIClientFactory.makeClient(configuration: settings.providerConfiguration(for: provider))
            let model = persona.resolvedModel(defaultModel: settings.defaultModel(for: provider))

            var image: AIImageInput?
            if includeImage, settings.sendImages, item.hasImage, let data = item.imageData {
                image = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.uploadJPEG(from: data).map { AIImageInput(data: $0, mimeType: "image/jpeg") }
                }.value
            }

            let history = item.sortedChatMessages
                .filter { !$0.isError }
                .suffix(historyLimit)
                .map { $0.role == .user ? AIMessage.user($0.content) : AIMessage.assistant($0.content) }

            let request = AgentPromptBuilder.chatRequest(
                persona: persona,
                context: item.captureContext(image: image),
                history: Array(history),
                model: model,
                environment: PromptEnvironment(responseLanguage: settings.responseLanguage),
                maxOutputTokens: environment.catalog.maxOutputTokens(model: model, provider: provider, settings: settings),
                includeImage: image != nil
            )

            for try await event in client.streamAdaptively(request) {
                if case .textDelta(let delta) = event {
                    streamingText += delta
                }
            }
            try Task.checkCancellation()
            storeReply(streamingText, for: itemID, persona: persona, model: model)
        } catch {
            let aiError = AIError.from(error)
            if aiError == .cancelled || Task.isCancelled {
                if let partial = streamingText.trimmedNonEmpty {
                    storeReply(partial + " …", for: itemID, persona: persona, model: nil)
                }
            } else {
                errorMessage = AgentPipeline.describe(error)
            }
        }
    }

    private func storeReply(_ text: String, for itemID: UUID, persona: AgentPersona, model: String?) {
        guard let item = CapturedItem.fetch(id: itemID, in: context), let text = text.trimmedNonEmpty else { return }
        let reply = ChatMessage(role: .assistant, content: text)
        reply.agentId = persona.id
        reply.agentName = persona.displayName
        reply.modelIdentifier = model
        context.insert(reply)
        reply.item = item
        try? context.save()
    }
}
