//
//  AIClient.swift
//  RecallDropKit
//
//  The provider-neutral client interface, the factory that picks an
//  implementation, and the adaptive retry that keeps requests working when a
//  model rejects an optional parameter (images, temperature, JSON mode, a too
//  generous output ceiling).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIProviderConfiguration: Sendable, Equatable {
    public var kind: AIProviderKind
    public var baseURL: URL
    public var apiKey: String?
    public var requestTimeout: TimeInterval
    /// Sent to OpenRouter as `X-Title` so usage shows up under the app's name.
    public var appTitle: String

    public init(
        kind: AIProviderKind,
        baseURL: URL? = nil,
        apiKey: String?,
        requestTimeout: TimeInterval = 120,
        appTitle: String = "RecallDrop"
    ) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.appTitle = appTitle
    }

    var trimmedAPIKey: String? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// `base` + `path`, tolerating a trailing slash on the base URL.
    func endpoint(_ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? baseURL.appendingPathComponent(path)
    }
}

public protocol AIClient: Sendable {
    var configuration: AIProviderConfiguration { get }
    func complete(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, any Error>
    func listModels() async throws -> [AIModelInfo]
}

public enum AIClientFactory {
    public static func makeClient(
        configuration: AIProviderConfiguration,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws -> any AIClient {
        if configuration.kind.requiresAPIKey, configuration.trimmedAPIKey == nil {
            throw AIError.missingAPIKey(configuration.kind)
        }
        switch configuration.kind.wireFormat {
        case .openAIChatCompletions:
            return OpenAICompatibleClient(configuration: configuration, transport: transport)
        case .anthropicMessages:
            return AnthropicClient(configuration: configuration, transport: transport)
        }
    }
}

// MARK: - Adaptive retry

/// What had to be changed so the provider accepted a request.
public struct AIRequestAdjustments: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let droppedImages = AIRequestAdjustments(rawValue: 1 << 0)
    public static let droppedTemperature = AIRequestAdjustments(rawValue: 1 << 1)
    public static let reducedMaxTokens = AIRequestAdjustments(rawValue: 1 << 2)
    public static let droppedJSONMode = AIRequestAdjustments(rawValue: 1 << 3)
}

public struct AIAdaptiveResult: Sendable {
    public var response: AIResponse
    public var adjustments: AIRequestAdjustments
    /// The request that finally succeeded (e.g. without images).
    public var finalRequest: AIRequest
}

public enum AIRequestAdapter {
    /// Output ceiling assumed when a request did not set one explicitly.
    public static let assumedDefaultMaxTokens = 16000
    public static let minimumMaxTokens = 1024

    /// A modified request that avoids the parameter the provider complained
    /// about, or `nil` when the error is not caused by an optional parameter.
    public static func adjust(_ request: AIRequest, after error: AIError) -> (AIRequest, AIRequestAdjustments)? {
        guard case .http(let status, _, _) = error, (400..<500).contains(status),
              status != 401, status != 403, status != 429 else { return nil }
        var adjusted = request
        if error.indicatesTemperatureUnsupported, request.temperature != nil {
            adjusted.temperature = nil
            return (adjusted, .droppedTemperature)
        }
        if error.indicatesMaxTokensProblem {
            let current = request.maxOutputTokens ?? assumedDefaultMaxTokens
            if current > minimumMaxTokens {
                adjusted.maxOutputTokens = max(minimumMaxTokens, current / 2)
                return (adjusted, .reducedMaxTokens)
            }
        }
        if error.indicatesJSONModeUnsupported, request.responseFormat == .jsonObject {
            adjusted.responseFormat = .text
            return (adjusted, .droppedJSONMode)
        }
        if error.indicatesImageUnsupported, request.containsImages {
            return (request.removingImages(), .droppedImages)
        }
        return nil
    }
}

extension AIClient {
    /// Sends the request and transparently retries when the provider rejects
    /// an optional parameter, or once after a transient failure.
    public func completeAdaptively(_ request: AIRequest, transientRetries: Int = 1) async throws -> AIAdaptiveResult {
        var current = request
        var adjustments: AIRequestAdjustments = []
        var transientLeft = transientRetries
        for _ in 0..<8 {
            try Task.checkCancellation()
            do {
                let response = try await complete(current)
                return AIAdaptiveResult(response: response, adjustments: adjustments, finalRequest: current)
            } catch {
                let aiError = AIError.from(error)
                if aiError == .cancelled { throw aiError }
                if let (next, adjustment) = AIRequestAdapter.adjust(current, after: aiError) {
                    current = next
                    adjustments.insert(adjustment)
                    continue
                }
                if aiError.isTransient, transientLeft > 0 {
                    transientLeft -= 1
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw aiError
            }
        }
        throw AIError.invalidResponse("gave up after repeated retries")
    }

    /// Streaming counterpart of `completeAdaptively`. Parameters are only
    /// adjusted while nothing has been streamed yet.
    public func streamAdaptively(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var current = request
                for _ in 0..<6 {
                    var receivedText = false
                    do {
                        for try await event in self.stream(current) {
                            if case .textDelta = event { receivedText = true }
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch {
                        let aiError = AIError.from(error)
                        if !receivedText, aiError != .cancelled,
                           let (next, _) = AIRequestAdapter.adjust(current, after: aiError) {
                            current = next
                            continue
                        }
                        continuation.finish(throwing: aiError)
                        return
                    }
                }
                continuation.finish(throwing: AIError.invalidResponse("gave up after repeated retries"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared helpers for clients

enum ClientSupport {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func httpError(_ response: HTTPResponse, provider: AIProviderKind) -> AIError {
        let message = AIError.extractMessage(from: response.body) ?? ""
        return .http(status: response.statusCode, message: message, provider: provider)
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let string as String: return Int(string)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Reads a streamed error body after a non-2xx status.
    static func drainBody(
        _ iterator: inout AsyncThrowingStream<HTTPStreamEvent, any Error>.AsyncIterator
    ) async -> Data {
        var lines: [String] = []
        while let event = try? await iterator.next() {
            if case .line(let line) = event { lines.append(line) }
            if lines.count > 200 { break }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
