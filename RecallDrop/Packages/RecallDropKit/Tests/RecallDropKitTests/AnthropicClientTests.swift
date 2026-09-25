//
//  AnthropicClientTests.swift
//  RecallDropKitTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RecallDropKit

final class AnthropicClientTests: XCTestCase {
    private func client(_ transport: MockTransport = MockTransport()) -> AnthropicClient {
        AnthropicClient(configuration: AIProviderConfiguration(kind: .anthropic, apiKey: "sk-ant-test-1234567"), transport: transport)
    }

    func testRequestShapeHeadersAndDefaults() throws {
        let request = AIRequest(
            model: "claude-sonnet-5",
            systemPrompt: "Persona",
            messages: [.user("What is this?", images: [Fixtures.sampleImage])],
            temperature: 0.7
        )
        let urlRequest = try client().makeURLRequest(for: request, stream: false)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-1234567")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))

        let body = urlRequest.jsonBody
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicClient.defaultMaxTokens)
        XCTAssertEqual(body["system"] as? String, "Persona")
        XCTAssertNil(body["temperature"], "current models reject sampling parameters")

        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "image", "images come before text")
        let source = content?.first?["source"] as? [String: Any]
        XCTAssertEqual(source?["type"] as? String, "base64")
        XCTAssertEqual(source?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(content?.last?["text"] as? String, "What is this?")
    }

    func testOlderModelsKeepClampedTemperature() throws {
        let request = AIRequest(model: "claude-haiku-4-5", messages: [.user("x")], temperature: 1.6, maxOutputTokens: 2048)
        let body = try client().makeURLRequest(for: request, stream: true).jsonBody
        XCTAssertEqual(body["temperature"] as? Double, 1.0)
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testMessagesAreNormalized() throws {
        let request = AIRequest(model: "claude-opus-5", messages: [
            .assistant("Leading assistant turns are dropped"),
            .user("First"),
            .user("Second"),
            .assistant("Answer"),
            .user("Follow-up"),
            .assistant("Trailing assistant turns would be a prefill")
        ])
        let messages = try client().makeURLRequest(for: request, stream: false).jsonBody["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual((messages?.first?["content"] as? [[String: Any]])?.count, 2, "consecutive user turns are merged")
    }

    func testParseMessageSkipsThinkingBlocks() throws {
        let response = try AnthropicClient.parseMessage(Data("""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5",
         "content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"{\\"title\\":\\"A\\"}"}],
         "stop_reason":"end_turn","usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":40}}
        """.utf8))
        XCTAssertEqual(response.text, #"{"title":"A"}"#)
        XCTAssertEqual(response.usage, AITokenUsage(inputTokens: 120, outputTokens: 40))
        XCTAssertEqual(response.model, "claude-sonnet-5")
    }

    func testRefusalAndTruncation() {
        XCTAssertThrowsError(try AnthropicClient.parseMessage(Data("""
        {"type":"message","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Policy"}}
        """.utf8))) { error in
            guard case .refused(let message)? = error as? AIError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Policy"))
        }
        XCTAssertThrowsError(try AnthropicClient.parseMessage(Data("""
        {"type":"message","content":[{"type":"thinking","thinking":""}],"stop_reason":"max_tokens"}
        """.utf8))) { XCTAssertEqual($0 as? AIError, .outputTruncated) }
    }

    func testStreamingEvents() async throws {
        let transport = MockTransport(streams: [.init(status: 200, lines: [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg","usage":{"input_tokens":25,"output_tokens":1}}}"#,
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            "event: ping",
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#
        ])])
        var text = ""
        var usage = AITokenUsage()
        var reason: String?
        for try await event in client(transport).stream(AIRequest(model: "claude-sonnet-5", messages: [.user("Hi")])) {
            switch event {
            case .textDelta(let delta): text += delta
            case .usage(let reported): usage = usage.merged(with: reported)
            case .finished(let stop): reason = stop
            }
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(usage, AITokenUsage(inputTokens: 25, outputTokens: 12))
        XCTAssertEqual(reason, "end_turn")
    }

    func testStreamingErrorEvent() async {
        let transport = MockTransport(streams: [.init(status: 200, lines: [
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        ])])
        do {
            for try await _ in client(transport).stream(AIRequest(model: "claude-sonnet-5", messages: [.user("Hi")])) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .http(status: 529, message: "Overloaded", provider: .anthropic))
            XCTAssertEqual((error as? AIError)?.isTransient, true)
        }
    }

    func testModelPagination() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"data":[{"type":"model","id":"claude-sonnet-5","display_name":"Claude Sonnet 5","created_at":"2026-02-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"image_input":{"supported":true}}}],"has_more":true,"last_id":"claude-sonnet-5"}"#),
            .json(#"{"data":[{"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","created_at":"2025-10-01T00:00:00Z"}],"has_more":false,"last_id":"claude-haiku-4-5"}"#)
        ])
        let models = try await client(transport).listModels()
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5", "claude-haiku-4-5"])
        XCTAssertEqual(models.first?.maxOutputTokens, 128_000)
        XCTAssertEqual(models.first?.displayName, "Claude Sonnet 5")
        XCTAssertNotNil(models.first?.createdAt)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.url?.query?.contains("after_id=claude-sonnet-5"), true)
    }
}
