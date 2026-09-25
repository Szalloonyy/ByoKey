//
//  OpenAICompatibleClient.swift
//  RecallDropKit
//
//  Chat Completions client used for OpenRouter, OpenAI and every
//  OpenAI-compatible server (Ollama, LM Studio, vLLM, Jan, …).
//
//  Provider differences handled here:
//    • OpenAI wants `max_completion_tokens`; its reasoning models (o-series,
//      GPT-5) reject a custom temperature.
//    • OpenAI supports `response_format: json_object`; local servers vary,
//      so JSON mode is only requested from OpenAI.
//    • Text-only messages are sent as plain strings – the widest-compatible
//      form. Parts arrays are used only when an image is attached.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAICompatibleClient: AIClient {
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

        let kind = configuration.kind
        let isOpenAI = kind == .openAI
        let isReasoningModel = isOpenAI && ModelCapabilities.isOpenAIReasoningModel(model)

        var messages: [WireMessage] = []
        if let system = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(WireMessage(role: "system", content: .text(system)))
        }
        for message in request.messages {
            let images = message.images
            let text = message.text
            if images.isEmpty {
                messages.append(WireMessage(role: message.role.rawValue, content: .text(text)))
            } else {
                var parts: [WirePart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                parts.append(contentsOf: images.map { WirePart.imageURL($0.dataURL) })
                messages.append(WireMessage(role: message.role.rawValue, content: .parts(parts)))
            }
        }

        var body = ChatCompletionBody(model: model, messages: messages)
        if let temperature = request.temperature, !isReasoningModel {
            body.temperature = min(max(temperature, kind.temperatureRange.lowerBound), kind.temperatureRange.upperBound)
        }
        if let maxTokens = request.maxOutputTokens {
            if isOpenAI {
                body.maxCompletionTokens = maxTokens
            } else {
                body.maxTokens = maxTokens
            }
        }
        if request.responseFormat == .jsonObject, isOpenAI {
            body.responseFormat = .init(type: "json_object")
        }
        if stream {
            body.stream = true
            if kind == .openAI || kind == .openRouter {
                body.streamOptions = .init(includeUsage: true)
            }
        }

        var urlRequest = URLRequest(url: configuration.endpoint("/chat/completions"))
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
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if configuration.kind == .openRouter {
            request.setValue(configuration.appTitle, forHTTPHeaderField: "X-Title")
        }
    }

    // MARK: - Completion

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let urlRequest = try makeURLRequest(for: request, stream: false)
        let response = try await transport.send(urlRequest)
        guard response.isSuccess else {
            throw ClientSupport.httpError(response, provider: configuration.kind)
        }
        return try Self.parseCompletion(response.body, provider: configuration.kind)
    }

    public static func parseCompletion(_ data: Data, provider: AIProviderKind) throws -> AIResponse {
        guard let object = ClientSupport.jsonObject(from: data) else {
            throw AIError.invalidResponse("the body is not JSON")
        }
        let choices = object["choices"] as? [[String: Any]] ?? []
        // OpenRouter reports some upstream failures with HTTP 200 and an error object.
        if choices.isEmpty, let error = object["error"] {
            throw streamOrBodyError(error, provider: provider)
        }
        guard let choice = choices.first else { throw AIError.emptyResponse }

        let message = choice["message"] as? [String: Any]
        var text = textContent(message?["content"]) ?? ""
        if text.isEmpty, let legacy = choice["text"] as? String { text = legacy }
        let finishReason = choice["finish_reason"] as? String

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
                throw AIError.refused(refusal)
            }
            switch finishReason {
            case "content_filter": throw AIError.refused("The provider's content filter blocked the answer.")
            case "length": throw AIError.outputTruncated
            default: throw AIError.emptyResponse
            }
        }
        return AIResponse(
            text: text,
            model: object["model"] as? String,
            usage: usage(from: object["usage"]),
            finishReason: finishReason
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
        let provider = configuration.kind

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
                            provider: provider
                        )
                    }

                    var parser = SSELineParser()
                    var sawText = false
                    var finishReason: String?
                    var plainBody: [String] = []

                    streamLoop: while let event = try await iterator.next() {
                        guard case .line(let line) = event else { continue }
                        guard Self.isSSEFieldLine(line) else {
                            plainBody.append(line)
                            continue
                        }
                        guard let sse = parser.consume(line) else { continue }
                        if sse.isDoneMarker { break streamLoop }
                        guard let json = ClientSupport.jsonObject(from: Data(sse.data.utf8)) else { continue }
                        if let error = json["error"] {
                            throw Self.streamOrBodyError(error, provider: provider)
                        }
                        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
                            if let delta = choice["delta"] as? [String: Any],
                               let content = Self.textContent(delta["content"]), !content.isEmpty {
                                sawText = true
                                continuation.yield(.textDelta(content))
                            }
                            if let reason = choice["finish_reason"] as? String {
                                finishReason = reason
                            }
                        }
                        if let usage = Self.usage(from: json["usage"]) {
                            continuation.yield(.usage(usage))
                        }
                    }

                    if !sawText {
                        // Some servers ignore `stream: true` and answer with a regular JSON body.
                        if !plainBody.isEmpty {
                            let response = try Self.parseCompletion(Data(plainBody.joined(separator: "\n").utf8), provider: provider)
                            continuation.yield(.textDelta(response.text))
                            if let usage = response.usage { continuation.yield(.usage(usage)) }
                            finishReason = response.finishReason
                        } else if finishReason == "length" {
                            throw AIError.outputTruncated
                        } else if finishReason == "content_filter" {
                            throw AIError.refused("The provider's content filter blocked the answer.")
                        } else {
                            throw AIError.emptyResponse
                        }
                    }
                    continuation.yield(.finished(reason: finishReason))
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
        var urlRequest = URLRequest(url: configuration.endpoint("/models"))
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = min(configuration.requestTimeout, 30)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        applyCommonHeaders(to: &urlRequest)
        let response = try await transport.send(urlRequest)
        guard response.isSuccess else {
            throw ClientSupport.httpError(response, provider: configuration.kind)
        }
        return try Self.parseModelList(response.body, provider: configuration.kind)
    }

    public static func parseModelList(_ data: Data, provider: AIProviderKind) throws -> [AIModelInfo] {
        let json = try? JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]
        if let object = json as? [String: Any] {
            entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        } else if let array = json as? [[String: Any]] {
            entries = array
        } else {
            throw AIError.invalidResponse("the model list is not JSON")
        }

        var seen = Set<String>()
        var models: [AIModelInfo] = []
        for entry in entries {
            guard let id = (entry["id"] as? String) ?? (entry["model"] as? String) ?? (entry["name"] as? String),
                  !id.isEmpty, seen.insert(id).inserted else { continue }
            if provider == .openAI, !ModelCapabilities.isOpenAIChatModel(id) { continue }

            let topProvider = entry["top_provider"] as? [String: Any]
            let contextLength = ClientSupport.int(entry["context_length"])
                ?? ClientSupport.int(entry["context_window"])
                ?? ClientSupport.int(topProvider?["context_length"])
            let maxOutput = ClientSupport.int(topProvider?["max_completion_tokens"])
                ?? ClientSupport.int(entry["max_completion_tokens"])

            var supportsVision: Bool?
            if let architecture = entry["architecture"] as? [String: Any] {
                if let inputs = architecture["input_modalities"] as? [String] {
                    supportsVision = inputs.contains("image")
                } else if let modality = architecture["modality"] as? String,
                          let inputSide = modality.components(separatedBy: "->").first {
                    supportsVision = inputSide.contains("image")
                }
            }

            var promptPrice: Double?
            var completionPrice: Double?
            if let pricing = entry["pricing"] as? [String: Any] {
                promptPrice = ClientSupport.double(pricing["prompt"]).flatMap { $0 >= 0 ? $0 * 1_000_000 : nil }
                completionPrice = ClientSupport.double(pricing["completion"]).flatMap { $0 >= 0 ? $0 * 1_000_000 : nil }
            }

            let name = (entry["name"] as? String).flatMap { $0.isEmpty || $0 == id ? nil : $0 }
            let created = ClientSupport.double(entry["created"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }

            models.append(AIModelInfo(
                id: id,
                displayName: name,
                contextLength: contextLength,
                maxOutputTokens: maxOutput,
                supportsVision: supportsVision,
                promptPricePerMillion: promptPrice,
                completionPricePerMillion: completionPrice,
                createdAt: created
            ))
        }
        return models
    }

    // MARK: - Parsing helpers

    static func isSSEFieldLine(_ line: String) -> Bool {
        line.hasPrefix("data:") || line.hasPrefix("event:") || line.hasPrefix(":")
            || line.hasPrefix("id:") || line.hasPrefix("retry:")
    }

    /// `content` is usually a string, but some servers send an array of parts.
    static func textContent(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                if let type = part["type"] as? String, type != "text", type != "output_text" { return nil }
                return part["text"] as? String
            }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }

    static func usage(from value: Any?) -> AITokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = ClientSupport.int(usage["prompt_tokens"]) ?? ClientSupport.int(usage["input_tokens"])
        let output = ClientSupport.int(usage["completion_tokens"]) ?? ClientSupport.int(usage["output_tokens"])
        guard input != nil || output != nil else { return nil }
        return AITokenUsage(inputTokens: input, outputTokens: output)
    }

    static func streamOrBodyError(_ error: Any, provider: AIProviderKind) -> AIError {
        if let object = error as? [String: Any] {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": object])) ?? Data()
            let message = AIError.extractMessage(from: data) ?? "Unknown error"
            var status = ClientSupport.int(object["code"]) ?? 502
            if !(400...599).contains(status) { status = 502 }
            return .http(status: status, message: message, provider: provider)
        }
        if let message = error as? String {
            return .http(status: 502, message: AIError.sanitized(message), provider: provider)
        }
        return .invalidResponse("error without details")
    }
}

// MARK: - Wire types

private struct ChatCompletionBody: Encodable {
    var model: String
    var messages: [WireMessage]
    var temperature: Double?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var stream: Bool?
    var streamOptions: StreamOptions?
    var responseFormat: ResponseFormat?

    struct StreamOptions: Encodable {
        var includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    struct ResponseFormat: Encodable {
        var type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
    }
}

private struct WireMessage: Encodable {
    var role: String
    var content: WireContent
}

private enum WireContent: Encodable {
    case text(String)
    case parts([WirePart])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

private enum WirePart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURL: Encodable {
        var url: String
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
}
