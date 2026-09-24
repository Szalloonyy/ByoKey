//
//  OpenAICompatibleClientTests.swift
//  RecallDropKitTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RecallDropKit

final class OpenAICompatibleClientTests: XCTestCase {
    private func client(_ kind: AIProviderKind, transport: MockTransport = MockTransport(), key: String? = "sk-test-123456789") -> OpenAICompatibleClient {
        OpenAICompatibleClient(configuration: AIProviderConfiguration(kind: kind, apiKey: key), transport: transport)
    }

    func testOpenRouterRequestUsesMaxTokensTemperatureAndTitleHeader() throws {
        let request = AIRequest(
            model: "anthropic/claude-sonnet-5",
            systemPrompt: "You are helpful.",
            messages: [.user("Hello")],
            temperature: 0.7,
            maxOutputTokens: 4096,
            responseFormat: .jsonObject
        )
        let urlRequest = try client(.openRouter).makeURLRequest(for: request, stream: false)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123456789")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Title"), "RecallDrop")

        let body = urlRequest.jsonBody
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-sonnet-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertNil(body["response_format"], "JSON mode is only requested from OpenAI")
        XCTAssertNil(body["stream"])

        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["content"] as? String, "Hello", "text-only content is a plain string")
    }

    func testOpenAIReasoningModelOmitsTemperatureAndUsesMaxCompletionTokens() throws {
        let request = AIRequest(model: "gpt-5-mini", messages: [.user("Hi")], temperature: 0.2,
                                maxOutputTokens: 8192, responseFormat: .jsonObject)
        let body = try client(.openAI).makeURLRequest(for: request, stream: true).jsonBody

        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 8192)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
    }

    func testOpenAIRegularModelKeepsTemperature() throws {
        let request = AIRequest(model: "gpt-4o", messages: [.user("Hi")], temperature: 2.6)
        let body = try client(.openAI).makeURLRequest(for: request, stream: false).jsonBody
        XCTAssertEqual(body["temperature"] as? Double, 2.0, "clamped to the provider range")
    }

    func testImagesAreSentAsPartsAfterText() throws {
        let request = AIRequest(model: "llava", messages: [.user("Describe", images: [Fixtures.sampleImage])])
        let body = try client(.custom, key: nil).makeURLRequest(for: request, stream: false).jsonBody
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertEqual(content?.last?["type"] as? String, "image_url")
        let url = (content?.last?["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertEqual(url?.hasPrefix("data:image/jpeg;base64,"), true)
    }

    func testCustomServerWithoutKeySendsNoAuthorization() throws {
        let request = AIRequest(model: "llama3.2-vision", messages: [.user("Hi")])
        let urlRequest = try client(.custom, key: nil).makeURLRequest(for: request, stream: false)
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMissingModelThrows() {
        XCTAssertThrowsError(try client(.openAI).makeURLRequest(for: AIRequest(model: " ", messages: [.user("x")]), stream: false)) {
            XCTAssertEqual($0 as? AIError, .missingModel)
        }
    }

    func testParseCompletionVariants() throws {
        let plain = try OpenAICompatibleClient.parseCompletion(Data("""
        {"model":"gpt-4o","choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":12,"completion_tokens":3}}
        """.utf8), provider: .openAI)
        XCTAssertEqual(plain.text, "Hello")
        XCTAssertEqual(plain.usage, AITokenUsage(inputTokens: 12, outputTokens: 3))
        XCTAssertEqual(plain.finishReason, "stop")

        let parts = try OpenAICompatibleClient.parseCompletion(Data("""
        {"choices":[{"message":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}]}
        """.utf8), provider: .custom)
        XCTAssertEqual(parts.text, "AB")

        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(Data("""
        {"choices":[{"message":{"content":null,"refusal":"I can't help with that."}}]}
        """.utf8), provider: .openAI)) { XCTAssertEqual($0 as? AIError, .refused("I can't help with that.")) }

        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(Data("""
        {"choices":[{"message":{"content":""},"finish_reason":"length"}]}
        """.utf8), provider: .openAI)) { XCTAssertEqual($0 as? AIError, .outputTruncated) }

        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(Data("""
        {"error":{"message":"Provider returned error","code":502,"metadata":{"raw":"{\\"error\\":{\\"message\\":\\"upstream overloaded\\"}}"}}}
        """.utf8), provider: .openRouter)) { error in
            guard case .http(let status, let message, _)? = error as? AIError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 502)
            XCTAssertTrue(message.contains("upstream overloaded"), message)
        }
    }

    func testCompleteMapsHTTPErrors() async {
        let transport = MockTransport(responses: [.json(#"{"error":{"message":"Incorrect API key provided: sk-abcdefghijkl"}}"#, status: 401)])
        do {
            _ = try await client(.openAI, transport: transport).complete(AIRequest(model: "gpt-4o", messages: [.user("x")]))
            XCTFail("expected an error")
        } catch {
            guard case .http(let status, let message, let provider)? = error as? AIError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(provider, .openAI)
            XCTAssertFalse(message.contains("sk-abcdefghijkl"), "keys are redacted: \(message)")
        }
    }

    func testStreamingYieldsDeltasUsageAndFinish() async throws {
        let transport = MockTransport(streams: [.init(status: 200, lines: [
            ": OPENROUTER PROCESSING",
            #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#,
            "data: [DONE]"
        ])])
        var text = ""
        var usage: AITokenUsage?
        var finished = false
        for try await event in client(.openRouter, transport: transport).stream(AIRequest(model: "m", messages: [.user("x")])) {
            switch event {
            case .textDelta(let delta): text += delta
            case .usage(let reported): usage = reported
            case .finished(let reason):
                finished = true
                XCTAssertEqual(reason, "stop")
            }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(usage, AITokenUsage(inputTokens: 5, outputTokens: 2))
        XCTAssertTrue(finished)
    }

    func testStreamingErrorStatusCarriesProviderMessage() async {
        let transport = MockTransport(streams: [.init(status: 404, lines: [#"{"error":{"message":"No endpoints found that support image input"}}"#])])
        do {
            for try await _ in client(.openRouter, transport: transport).stream(AIRequest(model: "m", messages: [.user("x")])) {}
            XCTFail("expected an error")
        } catch {
            let aiError = error as? AIError
            XCTAssertEqual(aiError?.indicatesImageUnsupported, true)
        }
    }

    func testStreamingFallsBackToPlainJSONBody() async throws {
        let transport = MockTransport(streams: [.init(status: 200, lines: [
            #"{"choices":[{"message":{"content":"Not streamed"},"finish_reason":"stop"}]}"#
        ])])
        var text = ""
        for try await event in client(.custom, transport: transport, key: nil).stream(AIRequest(model: "m", messages: [.user("x")])) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "Not streamed")
    }

    func testParseOpenRouterModelList() throws {
        let data = Data("""
        {"data":[
          {"id":"anthropic/claude-sonnet-5","name":"Anthropic: Claude Sonnet 5","context_length":1000000,
           "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
           "pricing":{"prompt":"0.000002","completion":"0.00001"},"top_provider":{"max_completion_tokens":128000},"created":1760000000},
          {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"},
           "architecture":{"modality":"text->text"}},
          {"id":"anthropic/claude-sonnet-5"}
        ]}
        """.utf8)
        let models = try OpenAICompatibleClient.parseModelList(data, provider: .openRouter)
        XCTAssertEqual(models.count, 2, "duplicates are dropped")
        let sonnet = models[0]
        XCTAssertEqual(sonnet.displayName, "Anthropic: Claude Sonnet 5")
        XCTAssertEqual(sonnet.supportsVision, true)
        XCTAssertEqual(sonnet.contextLength, 1_000_000)
        XCTAssertEqual(sonnet.maxOutputTokens, 128_000)
        XCTAssertEqual(sonnet.promptPricePerMillion ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(sonnet.completionPricePerMillion ?? 0, 10.0, accuracy: 0.0001)
        XCTAssertNotNil(sonnet.createdAt)
        XCTAssertEqual(models[1].supportsVision, false)
        XCTAssertNil(models[1].promptPricePerMillion, "variable pricing is not shown as a price")
    }

    func testOpenAIModelListIsFilteredToChatModels() throws {
        let data = Data("""
        {"object":"list","data":[{"id":"gpt-4o"},{"id":"text-embedding-3-large"},{"id":"whisper-1"},
        {"id":"gpt-4o-realtime-preview"},{"id":"o3"},{"id":"dall-e-3"},{"id":"gpt-5-mini"}]}
        """.utf8)
        let ids = try OpenAICompatibleClient.parseModelList(data, provider: .openAI).map(\.id)
        XCTAssertEqual(ids, ["gpt-4o", "o3", "gpt-5-mini"])
    }

    func testListModelsHitsModelsEndpoint() async throws {
        let transport = MockTransport(responses: [.json(#"{"data":[{"id":"llama3.2-vision:latest"}]}"#)])
        let models = try await client(.custom, transport: transport, key: nil).listModels()
        XCTAssertEqual(models.map(\.id), ["llama3.2-vision:latest"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertEqual(models.first?.effectiveVisionSupport, true)
    }
}
