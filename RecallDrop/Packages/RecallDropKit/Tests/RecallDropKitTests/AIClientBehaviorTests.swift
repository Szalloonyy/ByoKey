//
//  AIClientBehaviorTests.swift
//  RecallDropKitTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RecallDropKit

final class AIClientBehaviorTests: XCTestCase {
    // MARK: Adaptive retry

    func testTemperatureRejectionIsRetriedWithoutTemperature() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"error":{"message":"temperature is not supported for this model"}}"#, status: 400),
            .json(#"{"choices":[{"message":{"content":"ok"}}]}"#)
        ])
        let client = OpenAICompatibleClient(configuration: AIProviderConfiguration(kind: .openRouter, apiKey: "sk-or-v1-x"), transport: transport)
        let result = try await client.completeAdaptively(AIRequest(model: "m", messages: [.user("x")], temperature: 0.5))
        XCTAssertEqual(result.response.text, "ok")
        XCTAssertTrue(result.adjustments.contains(.droppedTemperature))
        XCTAssertNil(result.finalRequest.temperature)
        XCTAssertNil(transport.requests.last?.jsonBody["temperature"])
    }

    func testImageRejectionIsRetriedTextOnly() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"error":{"message":"No endpoints found that support image input"}}"#, status: 404),
            .json(#"{"choices":[{"message":{"content":"text only"}}]}"#)
        ])
        let client = OpenAICompatibleClient(configuration: AIProviderConfiguration(kind: .openRouter, apiKey: "sk-or-v1-x"), transport: transport)
        let request = AIRequest(model: "m", messages: [.user("Describe", images: [Fixtures.sampleImage])])
        let result = try await client.completeAdaptively(request)
        XCTAssertTrue(result.adjustments.contains(.droppedImages))
        XCTAssertFalse(result.finalRequest.containsImages)
        let lastContent = (transport.requests.last?.jsonBody["messages"] as? [[String: Any]])?.last?["content"]
        XCTAssertEqual(lastContent as? String, "Describe")
    }

    func testCreditLimitReducesMaxTokens() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"error":{"message":"This request requires more credits, or fewer max_tokens. You requested up to 4096 tokens, but can only afford 1500."}}"#, status: 402),
            .json(#"{"choices":[{"message":{"content":"ok"}}]}"#)
        ])
        let client = OpenAICompatibleClient(configuration: AIProviderConfiguration(kind: .openRouter, apiKey: "sk-or-v1-x"), transport: transport)
        let result = try await client.completeAdaptively(AIRequest(model: "m", messages: [.user("x")], maxOutputTokens: 4096))
        XCTAssertEqual(result.finalRequest.maxOutputTokens, 2048)
        XCTAssertTrue(result.adjustments.contains(.reducedMaxTokens))
    }

    func testAuthenticationErrorsAreNotRetried() async {
        let transport = MockTransport(responses: [
            .json(#"{"error":{"message":"invalid x-api-key"}}"#, status: 401),
            .json(#"{"choices":[{"message":{"content":"should not be reached"}}]}"#)
        ])
        let client = OpenAICompatibleClient(configuration: AIProviderConfiguration(kind: .openAI, apiKey: "sk-x"), transport: transport)
        do {
            _ = try await client.completeAdaptively(AIRequest(model: "gpt-4o", messages: [.user("x")], temperature: 0.3))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testStreamAdaptivelyRetriesBeforeFirstToken() async throws {
        let transport = MockTransport(streams: [
            .init(status: 400, lines: [#"{"type":"error","error":{"type":"invalid_request_error","message":"temperature: not supported"}}"#]),
            .init(status: 200, lines: [
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fine"}}"#,
                #"data: {"type":"message_stop"}"#
            ])
        ])
        let client = AnthropicClient(configuration: AIProviderConfiguration(kind: .anthropic, apiKey: "sk-ant-x"), transport: transport)
        var text = ""
        for try await event in client.streamAdaptively(AIRequest(model: "claude-haiku-4-5", messages: [.user("x")], temperature: 0.4)) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "fine")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertNotNil(transport.requests.first?.jsonBody["temperature"])
        XCTAssertNil(transport.requests.last?.jsonBody["temperature"])
    }

    func testFactoryRequiresKeysExceptForCustomServers() throws {
        XCTAssertThrowsError(try AIClientFactory.makeClient(configuration: AIProviderConfiguration(kind: .openAI, apiKey: "  "))) {
            XCTAssertEqual($0 as? AIError, .missingAPIKey(.openAI))
        }
        let custom = try AIClientFactory.makeClient(configuration: AIProviderConfiguration(kind: .custom, apiKey: nil))
        XCTAssertTrue(custom is OpenAICompatibleClient)
        let anthropic = try AIClientFactory.makeClient(configuration: AIProviderConfiguration(kind: .anthropic, apiKey: "sk-ant-x"))
        XCTAssertTrue(anthropic is AnthropicClient)
    }

    // MARK: Errors

    func testExtractMessageFromVariousProviders() {
        XCTAssertEqual(AIError.extractMessage(from: Data(#"{"error":{"message":"OpenAI style"}}"#.utf8)), "OpenAI style")
        XCTAssertEqual(AIError.extractMessage(from: Data(#"{"type":"error","error":{"type":"x","message":"Anthropic style"}}"#.utf8)), "Anthropic style")
        XCTAssertEqual(AIError.extractMessage(from: Data(#"{"error":"model 'llava' not found"}"#.utf8)), "model 'llava' not found")
        XCTAssertEqual(AIError.extractMessage(from: Data(#"{"detail":[{"msg":"field required"}]}"#.utf8)), "field required")
        XCTAssertEqual(AIError.extractMessage(from: Data("Bad Gateway".utf8)), "Bad Gateway")
        XCTAssertNil(AIError.extractMessage(from: Data("<html><body>502</body></html>".utf8)))
        XCTAssertNil(AIError.extractMessage(from: Data()))
    }

    func testSanitizedRedactsKeysButNotWords() {
        let message = AIError.sanitized("Incorrect API key provided: sk-proj-abcdef123456. Use a task-specific key.")
        XCTAssertFalse(message.contains("abcdef123456"))
        XCTAssertTrue(message.contains("task-specific"))
    }

    func testErrorClassification() {
        XCTAssertTrue(AIError.http(status: 429, message: "", provider: .openAI).isTransient)
        XCTAssertTrue(AIError.http(status: 503, message: "", provider: .openAI).isTransient)
        XCTAssertFalse(AIError.http(status: 400, message: "", provider: .openAI).isTransient)
        XCTAssertTrue(AIError.http(status: 400, message: "Unsupported parameter: 'temperature'", provider: .openAI).indicatesTemperatureUnsupported)
        XCTAssertTrue(AIError.http(status: 400, message: "max_tokens: 16000 > 8192", provider: .anthropic).indicatesMaxTokensProblem)
        XCTAssertFalse(AIError.http(status: 500, message: "image processing failed", provider: .openAI).indicatesImageUnsupported)
        XCTAssertEqual(AIError.from(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(AIError.from(CancellationError()), .cancelled)
        XCTAssertNotNil(AIError.missingAPIKey(.anthropic).errorDescription)
        XCTAssertNotNil(AIError.http(status: 402, message: "", provider: .openRouter).recoverySuggestion)
    }

    // MARK: Provider configuration

    func testNormalizedBaseURL() {
        XCTAssertEqual(AIProviderKind.custom.normalizedBaseURL(from: "localhost:11434")?.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(AIProviderKind.custom.normalizedBaseURL(from: "http://192.168.1.20:1234/v1/")?.absoluteString, "http://192.168.1.20:1234/v1")
        XCTAssertEqual(AIProviderKind.custom.normalizedBaseURL(from: " http://localhost:8000/v1/chat/completions ")?.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(AIProviderKind.openAI.normalizedBaseURL(from: "api.openai.com/v1")?.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(AIProviderKind.anthropic.normalizedBaseURL(from: "https://api.anthropic.com/v1/messages")?.absoluteString, "https://api.anthropic.com/v1")
        XCTAssertEqual(AIProviderKind.custom.normalizedBaseURL(from: "http://studio.local:1234")?.absoluteString, "http://studio.local:1234/v1")
        XCTAssertNil(AIProviderKind.custom.normalizedBaseURL(from: ""))
        XCTAssertNil(AIProviderKind.custom.normalizedBaseURL(from: "ftp://example.com"))
    }

    func testProviderDefaults() {
        XCTAssertEqual(AIProviderKind.anthropic.wireFormat, .anthropicMessages)
        XCTAssertEqual(AIProviderKind.openRouter.wireFormat, .openAIChatCompletions)
        XCTAssertFalse(AIProviderKind.custom.requiresAPIKey)
        XCTAssertEqual(AIProviderKind.anthropic.temperatureRange, 0...1)
        for kind in AIProviderKind.allCases {
            XCTAssertFalse(kind.defaultModel.isEmpty)
            XCTAssertGreaterThan(kind.defaultMaxOutputTokens, 0)
        }
    }

    // MARK: Model capabilities

    func testModelCapabilities() {
        XCTAssertTrue(ModelCapabilities.likelySupportsVision("gpt-4o-mini"))
        XCTAssertTrue(ModelCapabilities.likelySupportsVision("llama3.2-vision:11b"))
        XCTAssertTrue(ModelCapabilities.likelySupportsVision("qwen2.5vl:7b"))
        XCTAssertTrue(ModelCapabilities.likelySupportsVision("claude-sonnet-5"))
        XCTAssertFalse(ModelCapabilities.likelySupportsVision("llama3.1:8b"))
        XCTAssertFalse(ModelCapabilities.likelySupportsVision("o3-mini"))

        XCTAssertTrue(ModelCapabilities.isOpenAIReasoningModel("gpt-5"))
        XCTAssertTrue(ModelCapabilities.isOpenAIReasoningModel("o4-mini"))
        XCTAssertFalse(ModelCapabilities.isOpenAIReasoningModel("gpt-5-chat-latest"))
        XCTAssertFalse(ModelCapabilities.isOpenAIReasoningModel("gpt-4o"))

        XCTAssertTrue(ModelCapabilities.anthropicRejectsSamplingParameters("claude-sonnet-5"))
        XCTAssertTrue(ModelCapabilities.anthropicRejectsSamplingParameters("claude-opus-5-5"))
        XCTAssertTrue(ModelCapabilities.anthropicRejectsSamplingParameters("anthropic/claude-fable-5-1"))
        XCTAssertFalse(ModelCapabilities.anthropicRejectsSamplingParameters("claude-haiku-4-5"))
        XCTAssertFalse(ModelCapabilities.anthropicRejectsSamplingParameters("claude-sonnet-4-6"))

        XCTAssertEqual(ModelCapabilities.vendor(of: "anthropic/claude-sonnet-5"), "anthropic")
        XCTAssertEqual(ModelCapabilities.vendor(of: "gpt-4o"), "openai")
        XCTAssertEqual(ModelCapabilities.vendor(of: "qwen2.5vl:7b"), "qwen")
    }

    func testSuggestedDefaultPrefersNewestMatchingVisionModel() {
        let models = [
            AIModelInfo(id: "anthropic/claude-sonnet-4.5", supportsVision: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            AIModelInfo(id: "anthropic/claude-sonnet-4.6", supportsVision: true, createdAt: Date(timeIntervalSince1970: 1_750_000_000)),
            AIModelInfo(id: "meta/llama-text", supportsVision: false)
        ]
        XCTAssertEqual(ModelCapabilities.suggestedDefault(from: models, provider: .openRouter)?.id, "anthropic/claude-sonnet-4.6")
        let local = [AIModelInfo(id: "llama3.1:8b"), AIModelInfo(id: "llava:13b")]
        XCTAssertEqual(ModelCapabilities.suggestedDefault(from: local, provider: .custom)?.id, "llava:13b")
        XCTAssertNil(ModelCapabilities.suggestedDefault(from: [], provider: .openAI))
    }

    // MARK: SSE

    func testSSELineParser() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(": keep-alive"))
        XCTAssertNil(parser.consume("event: content_block_delta"))
        XCTAssertEqual(parser.consume("data: {\"a\":1}\r"), SSEEvent(name: "content_block_delta", data: "{\"a\":1}"))
        XCTAssertEqual(parser.consume("data:[DONE]")?.isDoneMarker, true)
        XCTAssertNil(parser.consume("id: 42"))
        XCTAssertNil(parser.consume(""))
    }
}
