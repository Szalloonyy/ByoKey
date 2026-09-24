//
//  AITypes.swift
//  RecallDropKit
//
//  Provider-neutral request/response types. Each client translates these
//  into its own wire format, so the rest of the app never deals with JSON.
//

import Foundation

public enum AIRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

/// An image attached to a message. Always sent inline (base64); RecallDrop
/// never uploads images anywhere else.
public struct AIImageInput: Sendable, Hashable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data
        self.mimeType = mimeType
    }

    public var base64: String { data.base64EncodedString() }
    public var dataURL: String { "data:\(mimeType);base64,\(base64)" }
}

public enum AIContentPart: Sendable, Hashable {
    case text(String)
    case image(AIImageInput)
}

public struct AIMessage: Sendable, Hashable {
    public var role: AIRole
    public var parts: [AIContentPart]

    public init(role: AIRole, parts: [AIContentPart]) {
        self.role = role
        self.parts = parts
    }

    public static func user(_ text: String, images: [AIImageInput] = []) -> AIMessage {
        var parts: [AIContentPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        parts.append(contentsOf: images.map(AIContentPart.image))
        return AIMessage(role: .user, parts: parts)
    }

    public static func assistant(_ text: String) -> AIMessage {
        AIMessage(role: .assistant, parts: [.text(text)])
    }

    /// All text parts joined by blank lines.
    public var text: String {
        parts.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }
        .joined(separator: "\n\n")
    }

    public var images: [AIImageInput] {
        parts.compactMap { part -> AIImageInput? in
            if case .image(let image) = part { return image }
            return nil
        }
    }

    public var hasImages: Bool { !images.isEmpty }

    /// The same message with every image part removed.
    public func removingImages() -> AIMessage {
        AIMessage(role: role, parts: parts.filter { part in
            if case .image = part { return false }
            return true
        })
    }
}

public enum AIResponseFormat: String, Sendable, Hashable {
    case text
    /// Ask for a single JSON object where the provider supports a JSON mode.
    case jsonObject
}

public struct AIRequest: Sendable, Hashable {
    public var model: String
    public var systemPrompt: String?
    public var messages: [AIMessage]
    /// `nil` leaves the provider default in place. Some current models reject
    /// sampling parameters entirely; the clients omit them for those.
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var responseFormat: AIResponseFormat

    public init(
        model: String,
        systemPrompt: String? = nil,
        messages: [AIMessage],
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        responseFormat: AIResponseFormat = .text
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.responseFormat = responseFormat
    }

    public var containsImages: Bool { messages.contains(where: \.hasImages) }

    public func removingImages() -> AIRequest {
        var copy = self
        copy.messages = messages.map { $0.removingImages() }
        return copy
    }
}

public struct AITokenUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int? {
        switch (inputTokens, outputTokens) {
        case (nil, nil): nil
        default: (inputTokens ?? 0) + (outputTokens ?? 0)
        }
    }

    /// Combines two partial reports (streams deliver input and output separately).
    public func merged(with other: AITokenUsage) -> AITokenUsage {
        AITokenUsage(
            inputTokens: other.inputTokens ?? inputTokens,
            outputTokens: other.outputTokens ?? outputTokens
        )
    }
}

public struct AIResponse: Sendable, Hashable {
    public var text: String
    public var model: String?
    public var usage: AITokenUsage?
    public var finishReason: String?

    public init(text: String, model: String? = nil, usage: AITokenUsage? = nil, finishReason: String? = nil) {
        self.text = text
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
    }
}

public enum AIStreamEvent: Sendable, Hashable {
    case textDelta(String)
    case usage(AITokenUsage)
    case finished(reason: String?)
}

/// A model as reported by a provider's model list.
public struct AIModelInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var displayName: String
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    /// `nil` means the provider did not say; the UI then falls back to
    /// `ModelCapabilities.likelySupportsVision`.
    public var supportsVision: Bool?
    /// USD per one million input tokens (OpenRouter only).
    public var promptPricePerMillion: Double?
    /// USD per one million output tokens (OpenRouter only).
    public var completionPricePerMillion: Double?
    public var createdAt: Date?

    public init(
        id: String,
        displayName: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        promptPricePerMillion: Double? = nil,
        completionPricePerMillion: Double? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.promptPricePerMillion = promptPricePerMillion
        self.completionPricePerMillion = completionPricePerMillion
        self.createdAt = createdAt
    }

    public var isFree: Bool {
        promptPricePerMillion == 0 && completionPricePerMillion == 0
    }

    /// Vision support as reported, or inferred from the model ID.
    public var effectiveVisionSupport: Bool {
        supportsVision ?? ModelCapabilities.likelySupportsVision(id)
    }

    /// The vendor part of an OpenRouter-style ID (`anthropic/claude…` → `anthropic`).
    public var vendor: String { ModelCapabilities.vendor(of: id) }
}
