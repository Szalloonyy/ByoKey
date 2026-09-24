//
//  AnthropicClient.swift
//  RecallDropKit
//
//  Native client for Anthropic's Messages API (`POST /v1/messages`).
//
//  Notes that shape this implementation:
//    • Current Claude models (Sonnet 5, Opus 4.7+, Opus 5.x, Fable 5.x) reject
//      sampling parameters with a 400, so `temperature` is omitted for them.
//      Unknown future models are covered by the adaptive retry in AIClient.
//    • Those models think adaptively by default; thinking blocks are skipped
//      and only `text` blocks form the answer.
//    • Assistant prefill is no longer accepted, so a trailing assistant turn
//      is never sent.
//    • `stop_reason: "refusal"` arrives with HTTP 200 and must be checked
//      before reading the content.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicClient: AIClient {
    public static let apiVersion = "2023-06-01"
    /// Output ceiling when the caller sets none.
    public static let defaultMaxTokens = 16000

    public let configuration: AIProviderConfiguration
    private let transport: any HTTPTransport

    public init(configuration: AIProviderConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: - Request building

    public func makeURLRequest(for request: AIRequest, stream: Bool) throws -> URLRequest {
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.missingModel }

        let messages = Self.normalizedMessages(request.messages)
        guard !messages.isEmpty else { throw AIError.invalidResponse("nothing to send") }

        var body = MessagesBody(
            model: model,
            maxTokens: max(1, request.maxOutputTokens ?? Self.defaultMaxTokens),
            messages: messages
        )
        if let system = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            body.system = system
        }
        if let temperature = request.temperature, !ModelCapabilities.anthropicRejectsSamplingParameters(model) {
            body.temperature = min(max(temperature, 0), 1)
        }
        if stream { body.stream = true }

        var urlRequest = URLRequest(url: configuration.endpoint("/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        applyCommonHeaders(to: &urlRequest)
        urlRequest.httpBody = try ClientSupport.encode(body)
        return urlRequest
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        if let key = configuration.trimmedAPIKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    /// Merges consecutive turns of the same role, starts with a user turn and
    /// ends with one. Images go before text, as recommended for Claude.
    static func normalizedMessages(_ messages: [AIMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []
        for message in messages {
            var blocks: [AnthropicBlock] = message.images.map {
                .image(mediaType: $0.mimeType, base64: $0.base64)
            }
            let text = message.text
            if !text.isEmpty { blocks.append(.text(text)) }
            guard !blocks.isEmpty else { continue }
            if let last = result.last, last.role == message.role.rawValue {
                result[result.count - 1].content.append(contentsOf: blocks)
            } else {
                result.append(AnthropicMessage(role: message.role.rawValue, content: blocks))
            }
        }
        while result.first?.role == AIRole.assistant.rawValue { result.removeFirst() }
        while result.last?.role == AIRole.assistant.rawValue { result.removeLast() }
        return result
    }

    // MARK: - Completion

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let urlRequest = try makeURLRequest(for: request, stream: false)
        let response = try await transport.send(urlRequest)
        guard response.isSuccess else {
            throw ClientSupport.httpError(response, provider: .anthropic)
        }
        return try Self.parseMessage(response.body)
    }

    public static func parseMessage(_ data: Data) throws -> AIResponse {
        guard let object = ClientSupport.jsonObject(from: data) else {
            throw AIError.invalidResponse("the body is not JSON")
        }
        if (object["type"] as? String) == "error" {
            throw errorEvent(object)
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let stopReason = object["stop_reason"] as? String

        if stopReason == "refusal" {
            throw AIError.refused(refusalMessage(object["stop_details"]))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw stopReason == "max_tokens" ? AIError.outputTruncated : AIError.emptyResponse
        }
        return AIResponse(
            text: text,
            model: object["model"] as? String,
            usage: usage(from: object["usage"]),
            finishReason: stopReason
        )
    }

    // MARK: - Streaming

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(for: request, stream: true)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AIError.from(error)) }
        }
        let transport = self.transport

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var iterator = transport.streamLines(urlRequest).makeAsyncIterator()
                    guard case .head(let status, let headers)? = try await iterator.next() else {
                        throw AIError.invalidResponse("no response head")
                    }
                    guard (200..<300).contains(status) else {
                        let body = await ClientSupport.drainBody(&iterator)
                        throw ClientSupport.httpError(
                            HTTPResponse(statusCode: status, headers: headers, body: body),
                            provider: .anthropic
                        )
                    }

                    var parser = SSELineParser()
                    var sawText = false
                    var stopReason: String?

                    streamLoop: while let event = try await iterator.next() {
                        guard case .line(let line) = event, let sse = parser.consume(line),
                              let json = ClientSupport.jsonObject(from: Data(sse.data.utf8)) else { continue }

                        switch json["type"] as? String {
                        case "message_start":
                            let message = json["message"] as? [String: Any]
                            if let usage = Self.usage(from: message?["usage"]) {
                                continuation.yield(.usage(AITokenUsage(inputTokens: usage.inputTokens)))
                            }
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               (delta["type"] as? String) == "text_delta",
                               let text = delta["text"] as? String, !text.isEmpty {
                                sawText = true
                                continuation.yield(.textDelta(text))
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                                if reason == "refusal" {
                                    throw AIError.refused(Self.refusalMessage(delta["stop_details"]))
                                }
                            }
                            if let usage = json["usage"] as? [String: Any],
                               let output = ClientSupport.int(usage["output_tokens"]) {
                                continuation.yield(.usage(AITokenUsage(outputTokens: output)))
                            }
                        case "message_stop":
                            break streamLoop
                        case "error":
                            throw Self.errorEvent(json)
                        default:
                            continue
                        }
                    }

                    if !sawText {
                        throw stopReason == "max_tokens" ? AIError.outputTruncated : AIError.emptyResponse
                    }
                    continuation.yield(.finished(reason: stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Models

    public func listModels() async throws -> [AIModelInfo] {
        var models: [AIModelInfo] = []
        var afterID: String?
        for _ in 0..<10 {
            var components = URLComponents(url: configuration.endpoint("/models"), resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            components?.queryItems = query
            guard let url = components?.url else { throw AIError.invalidBaseURL(configuration.baseURL.absoluteString) }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.timeoutInterval = min(configuration.requestTimeout, 30)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            applyCommonHeaders(to: &urlRequest)

            let response = try await transport.send(urlRequest)
            guard response.isSuccess else {
                throw ClientSupport.httpError(response, provider: .anthropic)
            }
            let page = try Self.parseModelPage(response.body)
            models.append(contentsOf: page.models)
            guard page.hasMore, let last = page.lastID else { break }
            afterID = last
        }
        return models
    }

    public struct ModelPage: Sendable {
        public var models: [AIModelInfo]
        public var hasMore: Bool
        public var lastID: String?
    }

    public static func parseModelPage(_ data: Data) throws -> ModelPage {
        guard let object = ClientSupport.jsonObject(from: data) else {
            throw AIError.invalidResponse("the model list is not JSON")
        }
        let entries = object["data"] as? [[String: Any]] ?? []
        let models = entries.compactMap { entry -> AIModelInfo? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            var vision: Bool?
            if let capabilities = entry["capabilities"] as? [String: Any],
               let imageInput = capabilities["image_input"] as? [String: Any] {
                vision = imageInput["supported"] as? Bool
            }
            return AIModelInfo(
                id: id,
                displayName: entry["display_name"] as? String,
                contextLength: ClientSupport.int(entry["max_input_tokens"]),
                maxOutputTokens: ClientSupport.int(entry["max_tokens"]),
                supportsVision: vision ?? true,
                createdAt: (entry["created_at"] as? String).flatMap { FlexibleDateParser.parseTimestamp($0) }
            )
        }
        return ModelPage(
            models: models,
            hasMore: object["has_more"] as? Bool ?? false,
            lastID: object["last_id"] as? String
        )
    }

    // MARK: - Helpers

    static func usage(from value: Any?) -> AITokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        var input = ClientSupport.int(usage["input_tokens"])
        // Cached prompt tokens are reported separately from `input_tokens`.
        let cacheRead = ClientSupport.int(usage["cache_read_input_tokens"]) ?? 0
        let cacheWrite = ClientSupport.int(usage["cache_creation_input_tokens"]) ?? 0
        if let base = input { input = base + cacheRead + cacheWrite }
        let output = ClientSupport.int(usage["output_tokens"])
        guard input != nil || output != nil else { return nil }
        return AITokenUsage(inputTokens: input, outputTokens: output)
    }

    static func refusalMessage(_ details: Any?) -> String {
        if let details = details as? [String: Any],
           let explanation = details["explanation"] as? String, !explanation.isEmpty {
            return "Claude declined this request: \(explanation)"
        }
        return "Claude declined this request."
    }

    static func errorEvent(_ object: [String: Any]) -> AIError {
        let error = object["error"] as? [String: Any]
        let message = (error?["message"] as? String).map(AIError.sanitized) ?? "Unknown error"
        let status: Int
        switch error?["type"] as? String {
        case "invalid_request_error": status = 400
        case "authentication_error": status = 401
        case "billing_error": status = 402
        case "permission_error": status = 403
        case "not_found_error": status = 404
        case "request_too_large": status = 413
        case "rate_limit_error": status = 429
        case "overloaded_error": status = 529
        default: status = 500
        }
        return .http(status: status, message: message, provider: .anthropic)
    }
}

// MARK: - Wire types

struct AnthropicMessage: Encodable {
    var role: String
    var content: [AnthropicBlock]
}

enum AnthropicBlock: Encodable {
    case text(String)
    case image(mediaType: String, base64: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, source
    }

    private struct Source: Encodable {
        var type = "base64"
        var mediaType: String
        var data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let base64):
            try container.encode("image", forKey: .type)
            try container.encode(Source(mediaType: mediaType, data: base64), forKey: .source)
        }
    }
}

private struct MessagesBody: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicMessage]
    var temperature: Double?
    var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}
