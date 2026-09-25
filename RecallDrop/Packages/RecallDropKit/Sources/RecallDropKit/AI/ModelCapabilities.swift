//
//  ModelCapabilities.swift
//  RecallDropKit
//
//  Heuristics about model IDs for providers whose model lists don't say
//  what a model can do. OpenRouter and Anthropic report vision support
//  directly; OpenAI and local servers don't.
//

import Foundation

public enum ModelCapabilities {
    /// The model-family part of an ID: `anthropic/claude-sonnet-5` → `claude-sonnet-5`.
    static func family(of modelID: String) -> String {
        let lowered = modelID.lowercased()
        return lowered.split(separator: "/").last.map(String.init) ?? lowered
    }

    public static func vendor(of modelID: String) -> String {
        if let slash = modelID.firstIndex(of: "/") {
            return String(modelID[..<slash]).lowercased()
        }
        let id = modelID.lowercased()
        let table: [(prefixes: [String], vendor: String)] = [
            (["claude"], "anthropic"),
            (["gpt", "o1", "o3", "o4", "chatgpt"], "openai"),
            (["gemini", "gemma"], "google"),
            (["llama", "llava"], "meta"),
            (["qwen"], "qwen"),
            (["mistral", "mixtral", "pixtral", "ministral", "magistral", "devstral"], "mistral"),
            (["deepseek"], "deepseek"),
            (["phi"], "microsoft"),
            (["grok"], "x-ai"),
            (["granite"], "ibm")
        ]
        for entry in table where entry.prefixes.contains(where: id.hasPrefix) {
            return entry.vendor
        }
        return "other"
    }

    public static func likelySupportsVision(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        let hints = [
            "vision", "-vl", "vl-", "vl:", "llava", "pixtral", "moondream", "minicpm-v",
            "qwen2.5vl", "qwen3-vl", "gemma3", "gemma-3", "llama4", "llama-4", "granite3.2-vision",
            "mistral-small3", "mistral-small-3", "internvl", "cogvlm", "idefics", "smolvlm", "multimodal", "omni"
        ]
        if hints.contains(where: id.contains) { return true }

        let family = family(of: modelID)
        if family.hasPrefix("claude-") {
            return !family.hasPrefix("claude-2") && !family.hasPrefix("claude-instant")
        }
        if family.hasPrefix("gpt-4o") || family.hasPrefix("gpt-4.1") || family.hasPrefix("gpt-4-turbo")
            || family.hasPrefix("gpt-5") || family.hasPrefix("chatgpt-4o") || family.hasPrefix("o4") {
            return true
        }
        if (family.hasPrefix("o1") && !family.hasPrefix("o1-mini")) || (family.hasPrefix("o3") && !family.hasPrefix("o3-mini")) {
            return true
        }
        if family.hasPrefix("gemini") { return true }
        if family.hasPrefix("grok-4") || family.hasPrefix("grok-2-vision") { return true }
        return false
    }

    /// OpenAI reasoning models only accept the default temperature.
    public static func isOpenAIReasoningModel(_ modelID: String) -> Bool {
        let family = family(of: modelID)
        if family.contains("-chat") { return false }
        return family.hasPrefix("o1") || family.hasPrefix("o3") || family.hasPrefix("o4") || family.hasPrefix("gpt-5")
    }

    /// Filters OpenAI's model list down to models usable with Chat Completions.
    public static func isOpenAIChatModel(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        let excluded = [
            "embedding", "whisper", "tts", "dall-e", "davinci", "babbage", "moderation", "audio",
            "realtime", "transcribe", "image", "search", "sora", "computer-use", "instruct"
        ]
        guard !excluded.contains(where: id.contains) else { return false }
        return id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
            || id.hasPrefix("chatgpt") || id.hasPrefix("ft:")
    }

    /// Current Claude generations reject `temperature`, `top_p` and `top_k`.
    public static func anthropicRejectsSamplingParameters(_ modelID: String) -> Bool {
        let family = family(of: modelID)
        let prefixes = [
            "claude-fable-5", "claude-mythos", "claude-opus-5", "claude-opus-4-8",
            "claude-opus-4-7", "claude-sonnet-5"
        ]
        return prefixes.contains(where: family.hasPrefix)
    }

    /// Picks a sensible model when the configured default is not offered.
    public static func suggestedDefault(from models: [AIModelInfo], provider: AIProviderKind) -> AIModelInfo? {
        guard !models.isEmpty else { return nil }
        if let exact = models.first(where: { $0.id == provider.defaultModel }) { return exact }

        let preferences: [String]
        switch provider {
        case .openRouter: preferences = ["anthropic/claude-sonnet", "google/gemini", "openai/gpt-4o", "openai/gpt-5"]
        case .openAI: preferences = ["gpt-4o", "gpt-4.1", "gpt-5-mini", "gpt-5"]
        case .anthropic: preferences = ["claude-sonnet", "claude-opus", "claude-haiku"]
        case .custom: preferences = []
        }
        for prefix in preferences {
            let candidates = models.filter { $0.id.lowercased().hasPrefix(prefix) && $0.effectiveVisionSupport }
            if let best = candidates.max(by: isOlder) { return best }
        }
        return models.first(where: \.effectiveVisionSupport) ?? models.first
    }

    private static func isOlder(_ lhs: AIModelInfo, _ rhs: AIModelInfo) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right: return left < right
        default: return lhs.id < rhs.id
        }
    }
}
