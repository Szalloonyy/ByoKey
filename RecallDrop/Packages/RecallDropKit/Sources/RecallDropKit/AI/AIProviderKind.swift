//
//  AIProviderKind.swift
//  RecallDropKit
//
//  The AI backends RecallDrop can talk to. Every provider is "bring your own
//  key": requests go straight from the device to the provider the user chose,
//  never through a RecallDrop server.
//

import Foundation

/// How a provider expects requests to be shaped on the wire.
public enum AIWireFormat: String, Sendable {
    /// `POST {base}/chat/completions` – OpenAI, OpenRouter, Ollama, LM Studio, vLLM, …
    case openAIChatCompletions
    /// `POST {base}/messages` – Anthropic's Messages API.
    case anthropicMessages
}

public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter
    case openAI
    case anthropic
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .custom: "Custom / Local"
        }
    }

    public var summary: String {
        switch self {
        case .openRouter:
            "One key for hundreds of models, including Claude, GPT and Gemini vision models."
        case .openAI:
            "Direct access to OpenAI models such as GPT-4o."
        case .anthropic:
            "Direct access to Claude models via the Anthropic API."
        case .custom:
            "Any OpenAI-compatible server – Ollama, LM Studio, vLLM or your own endpoint."
        }
    }

    public var symbolName: String {
        switch self {
        case .openRouter: "arrow.triangle.branch"
        case .openAI: "circle.hexagongrid"
        case .anthropic: "asterisk"
        case .custom: "server.rack"
        }
    }

    public var wireFormat: AIWireFormat {
        self == .anthropic ? .anthropicMessages : .openAIChatCompletions
    }

    public var defaultBaseURL: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .custom: URL(string: "http://localhost:11434/v1")!
        }
    }

    /// Model used until the user picks one from the live model list.
    public var defaultModel: String {
        switch self {
        case .openRouter: "anthropic/claude-sonnet-5"
        case .openAI: "gpt-4o"
        case .anthropic: "claude-sonnet-5"
        case .custom: "llama3.2-vision"
        }
    }

    /// Output-token ceiling used when the user has not changed it.
    ///
    /// OpenRouter reserves credit for the full `max_tokens` up front, so a
    /// small balance fails with 402 when the ceiling is generous. Anthropic's
    /// current models think adaptively and bill only what they generate, so a
    /// roomy ceiling avoids truncated answers there.
    public var defaultMaxOutputTokens: Int {
        switch self {
        case .openRouter: 4096
        case .openAI: 8192
        case .anthropic: 16000
        case .custom: 4096
        }
    }

    /// A custom server (e.g. Ollama on localhost) usually needs no key.
    public var requiresAPIKey: Bool { self != .custom }

    public var apiKeyPlaceholder: String {
        switch self {
        case .openRouter: "sk-or-v1-…"
        case .openAI: "sk-…"
        case .anthropic: "sk-ant-…"
        case .custom: "Optional"
        }
    }

    /// Where the user can create a key for this provider.
    public var apiKeyURL: URL? {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .custom: nil
        }
    }

    /// Temperature range the provider accepts.
    public var temperatureRange: ClosedRange<Double> {
        self == .anthropic ? 0...1 : 0...2
    }

    /// Turns whatever the user typed into a usable base URL.
    ///
    /// Accepts `localhost:11434`, `http://host:1234/v1/`, or a full
    /// `…/chat/completions` endpoint pasted from documentation. For custom
    /// servers an empty path gets `/v1`, which is where Ollama, LM Studio and
    /// vLLM expose their OpenAI-compatible API.
    public func normalizedBaseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0")
                || text.hasPrefix("192.168.") || text.hasPrefix("10.") || text.hasSuffix(".local")
                || text.range(of: #"^[^/]+\.local(:\d+)?(/|$)"#, options: .regularExpression) != nil
            text = (isLocal ? "http://" : "https://") + text
        }
        for suffix in ["/chat/completions", "/messages", "/completions", "/models"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        if self == .custom, components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        }
        return components.url
    }
}

/// Well-known local servers offered as one-tap presets for `.custom`.
public struct LocalServerPreset: Sendable, Hashable, Identifiable {
    public let name: String
    public let baseURL: URL
    public let suggestedModel: String
    public let note: String

    public var id: String { name }

    public init(name: String, baseURL: URL, suggestedModel: String, note: String) {
        self.name = name
        self.baseURL = baseURL
        self.suggestedModel = suggestedModel
        self.note = note
    }

    public static let all: [LocalServerPreset] = [
        LocalServerPreset(
            name: "Ollama",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            suggestedModel: "llama3.2-vision",
            note: "Run `ollama pull llama3.2-vision` for image understanding."
        ),
        LocalServerPreset(
            name: "LM Studio",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            suggestedModel: "",
            note: "Start the local server in LM Studio's Developer tab."
        ),
        LocalServerPreset(
            name: "vLLM",
            baseURL: URL(string: "http://localhost:8000/v1")!,
            suggestedModel: "",
            note: "Uses the OpenAI-compatible server started with `vllm serve`."
        ),
        LocalServerPreset(
            name: "Jan",
            baseURL: URL(string: "http://localhost:1337/v1")!,
            suggestedModel: "",
            note: "Enable the API server in Jan's settings."
        )
    ]
}
