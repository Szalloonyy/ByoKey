//
//  AIConnectionTester.swift
//  RecallDropKit
//
//  Backs the "Test Connection" button: checks that the key works, that the
//  selected model exists, and that it actually answers.
//

import Foundation

public struct ConnectionTestResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success
        case warning
        case failure
    }

    public var outcome: Outcome
    public var title: String
    public var details: [String]
    public var latency: TimeInterval?
    public var availableModels: [AIModelInfo]

    public init(outcome: Outcome, title: String, details: [String] = [], latency: TimeInterval? = nil, availableModels: [AIModelInfo] = []) {
        self.outcome = outcome
        self.title = title
        self.details = details
        self.latency = latency
        self.availableModels = availableModels
    }
}

public enum AIConnectionTester {
    public static func run(client: any AIClient, model: String) async -> ConnectionTestResult {
        var details: [String] = []
        var models: [AIModelInfo] = []
        let provider = client.configuration.kind

        do {
            models = try await client.listModels()
            details.append("\(provider.displayName) lists \(models.count) model\(models.count == 1 ? "" : "s").")
            if !models.isEmpty, !models.contains(where: { $0.id == model }) {
                details.append("“\(model)” is not in that list – the request below shows whether it still works.")
            }
        } catch {
            let aiError = AIError.from(error)
            switch aiError {
            case .http(let status, _, _) where status == 401 || status == 403:
                return ConnectionTestResult(outcome: .failure, title: aiError.errorDescription ?? "Authentication failed",
                                            details: [aiError.recoverySuggestion].compactMap { $0 })
            case .network, .timedOut:
                return ConnectionTestResult(outcome: .failure, title: aiError.errorDescription ?? "Network error",
                                            details: [aiError.recoverySuggestion].compactMap { $0 })
            case .cancelled:
                return ConnectionTestResult(outcome: .failure, title: "Cancelled")
            default:
                // Some compatible servers have no model list; the completion test decides.
                details.append("The model list is unavailable (\(aiError.errorDescription ?? "unknown error")).")
            }
        }

        let request = AIRequest(
            model: model,
            systemPrompt: "You are a connectivity check. Answer with the single word OK.",
            messages: [.user("Reply with OK.")],
            maxOutputTokens: 1024
        )
        let start = Date()
        do {
            let result = try await client.completeAdaptively(request, transientRetries: 0)
            let latency = Date().timeIntervalSince(start)
            let reply = result.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            details.append("“\(model)” answered: \(reply.prefix(60))")
            if result.adjustments.contains(.droppedTemperature) {
                details.append("This model uses a fixed temperature; agent temperature settings are ignored for it.")
            }
            return ConnectionTestResult(outcome: .success, title: "Connected to \(provider.displayName)",
                                        details: details, latency: latency, availableModels: models)
        } catch {
            let aiError = AIError.from(error)
            let latency = Date().timeIntervalSince(start)
            if aiError == .outputTruncated || aiError == .emptyResponse {
                details.append("The model responded but returned no text within the test budget.")
                return ConnectionTestResult(outcome: .warning, title: "Connected, but the model returned no text",
                                            details: details, latency: latency, availableModels: models)
            }
            details.append(contentsOf: [aiError.recoverySuggestion].compactMap { $0 })
            return ConnectionTestResult(outcome: .failure, title: aiError.errorDescription ?? "Request failed",
                                        details: details, latency: latency, availableModels: models)
        }
    }
}
