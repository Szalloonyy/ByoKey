//
//  AIError.swift
//  RecallDropKit
//
//  One error type for every provider, with messages a user can act on.
//  Provider error bodies differ (OpenAI, OpenRouter, Anthropic, Ollama,
//  FastAPI-based servers); `extractMessage(from:)` understands all of them.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIError: Error, Sendable, Equatable {
    /// "Offline Only" is on – no request may leave the device.
    case offlineMode
    case missingAPIKey(AIProviderKind)
    case missingModel
    case invalidBaseURL(String)
    case http(status: Int, message: String, provider: AIProviderKind)
    case network(String)
    case timedOut
    case emptyResponse
    /// The model stopped because it hit the output ceiling before answering.
    case outputTruncated
    /// The model or a safety system declined the request.
    case refused(String)
    case invalidResponse(String)
    case cancelled
}

extension AIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offlineMode:
            return "Offline Only is on, so RecallDrop won't contact an AI provider."
        case .missingAPIKey(let provider):
            return "No API key for \(provider.displayName) yet."
        case .missingModel:
            return "No model is selected."
        case .invalidBaseURL(let value):
            return "“\(value)” is not a valid server address."
        case .http(let status, let message, let provider):
            return Self.describe(status: status, message: message, provider: provider)
        case .network(let message):
            return "Network problem: \(message)"
        case .timedOut:
            return "The AI provider took too long to answer."
        case .emptyResponse:
            return "The model returned an empty answer."
        case .outputTruncated:
            return "The model ran out of output tokens before it finished."
        case .refused(let message):
            return message.isEmpty ? "The model declined to answer this request." : message
        case .invalidResponse(let detail):
            return "Unexpected answer from the AI provider (\(detail))."
        case .cancelled:
            return "The request was cancelled."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .offlineMode:
            return "Turn off Offline Only in Settings › AI to use agents."
        case .missingAPIKey:
            return "Add your key in Settings › AI. It is stored in the Keychain on this device."
        case .missingModel:
            return "Pick a model in Settings › AI or in the agent's settings."
        case .invalidBaseURL:
            return "Use a full address such as http://localhost:11434/v1."
        case .http(let status, _, _):
            switch status {
            case 401, 403: return "Check the API key in Settings › AI."
            case 402: return "Top up your account or lower Max Output Tokens in Settings › AI."
            case 404: return "Choose another model in Settings › AI – this one may be retired or misspelled."
            case 413: return "Try again with a smaller image."
            case 429: return "Wait a moment, then try again."
            case 500...599: return "The provider has a temporary problem. Try again later."
            default: return nil
            }
        case .network:
            return "Check your internet connection. For local servers, make sure the server is running and reachable."
        case .timedOut:
            return "Try again, or raise the request timeout in Settings › AI."
        case .emptyResponse, .invalidResponse:
            return "Try again or switch to another model."
        case .outputTruncated:
            return "Raise Max Output Tokens in Settings › AI, or pick a non-reasoning model."
        case .refused:
            return "Try another agent or model."
        case .cancelled:
            return nil
        }
    }

    private static func describe(status: Int, message: String, provider: AIProviderKind) -> String {
        let name = provider.displayName
        let detail = message.isEmpty ? "" : ": \(message)"
        switch status {
        case 400: return "\(name) rejected the request (400)\(detail)"
        case 401: return "\(name) rejected the API key (401)\(detail)"
        case 402: return "\(name) reports insufficient credits (402)\(detail)"
        case 403: return "\(name) denied access (403)\(detail)"
        case 404: return "\(name) could not find that model or endpoint (404)\(detail)"
        case 408: return "\(name) timed out (408)\(detail)"
        case 413: return "The request was too large for \(name) (413)\(detail)"
        case 429: return "\(name) rate limit reached (429)\(detail)"
        case 500...599: return "\(name) had a server error (\(status))\(detail)"
        default: return "\(name) returned an error (\(status))\(detail)"
        }
    }
}

extension AIError {
    /// Worth retrying the identical request after a short pause.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .network: return true
        case .http(let status, _, _): return status == 408 || status == 409 || status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    private var lowercasedMessage: String? {
        if case .http(let status, let message, _) = self, (400..<500).contains(status) {
            return message.lowercased()
        }
        return nil
    }

    /// The model (or its route) cannot read images.
    public var indicatesImageUnsupported: Bool {
        guard let message = lowercasedMessage else { return false }
        let hints = ["image", "vision", "multimodal", "multi-modal", "image_url"]
        return hints.contains { message.contains($0) }
    }

    /// The model does not accept a custom temperature.
    public var indicatesTemperatureUnsupported: Bool {
        guard let message = lowercasedMessage else { return false }
        return message.contains("temperature") || message.contains("sampling parameter")
    }

    /// The output ceiling is too high for the model or the account balance.
    public var indicatesMaxTokensProblem: Bool {
        guard let message = lowercasedMessage else { return false }
        return message.contains("max_tokens") || message.contains("max_completion_tokens")
            || message.contains("max output tokens") || message.contains("maximum output")
            || (message.contains("more credits") && message.contains("tokens"))
    }

    /// The server does not support `response_format`.
    public var indicatesJSONModeUnsupported: Bool {
        guard let message = lowercasedMessage else { return false }
        return message.contains("response_format") || message.contains("json_object")
    }

    public static func from(_ error: any Error) -> AIError {
        if let aiError = error as? AIError { return aiError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError { return from(urlError) }
        return .network(error.localizedDescription)
    }

    public static func from(_ urlError: URLError) -> AIError {
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .notConnectedToInternet: return .network("You appear to be offline.")
        case .cannotFindHost, .dnsLookupFailed: return .network("The server address could not be found.")
        case .cannotConnectToHost: return .network("Could not connect to the server. Is it running?")
        case .networkConnectionLost: return .network("The connection was lost.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .network("A secure connection could not be established.")
        case .appTransportSecurityRequiresSecureConnection:
            return .network("Plain HTTP is only allowed for local servers. Use HTTPS for remote endpoints.")
        default: return .network(urlError.localizedDescription)
        }
    }

    /// Pulls a human-readable message out of any provider's error body.
    public static func extractMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var message: String?
            if let error = object["error"] as? [String: Any] {
                message = error["message"] as? String
                // OpenRouter wraps the upstream provider's answer in metadata.raw.
                if let metadata = error["metadata"] as? [String: Any] {
                    if let raw = metadata["raw"] as? String, !raw.isEmpty {
                        let nested = extractMessage(from: Data(raw.utf8)) ?? raw
                        message = [message, nested].compactMap { $0 }.joined(separator: " – ")
                    } else if let reasons = metadata["reasons"] as? [String], !reasons.isEmpty {
                        message = [message, reasons.joined(separator: ", ")].compactMap { $0 }.joined(separator: " – ")
                    }
                }
            } else if let error = object["error"] as? String {
                message = error
            }
            if message == nil { message = object["message"] as? String }
            if message == nil, let detail = object["detail"] as? String { message = detail }
            if message == nil, let details = object["detail"] as? [[String: Any]] {
                message = details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
            if let message, !message.isEmpty { return sanitized(message) }
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // HTML error pages from proxies are useless to show verbatim.
        if text.hasPrefix("<") { return nil }
        return sanitized(text)
    }

    /// Masks anything that looks like an API key and caps the length.
    public static func sanitized(_ message: String) -> String {
        let redacted = message.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_.-])(sk-ant-|sk-or-|sk-proj-|sk-|gsk_|xai-|AIza)[A-Za-z0-9._-]{6,}"#,
            with: "•••",
            options: .regularExpression
        )
        let collapsed = redacted.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard collapsed.count > 400 else { return collapsed }
        return String(collapsed.prefix(400)) + "…"
    }
}
