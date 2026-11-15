import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class AIClientTests: XCTestCase, @unchecked Sendable {
    private let service = AIService(id: "fixture", url: "https://ai.fixture.test/v1", model: "fixture-text-model")

    func testImageAttachmentUsesActualDataURLAndRejectsUnsupportedMime() throws {
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let request = try AIRequestBuilder.generation(service: service, apiKey: "fixture-only-key", request: .init(messages: [.init(role: .user, content: "", image: bytes, imageMIMEType: "image/jpeg")]))
        let body = try json(request)
        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.last)
        let parts = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual((parts[0]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64," + bytes.base64EncodedString())
        XCTAssertThrowsError(try AIRequestBuilder.generation(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "", image: bytes, imageMIMEType: "application/octet-stream")])))
    }

    func testOriginalAssistantPresetsAndParameterUnits() throws {
        XCTAssertEqual(AIProviderPreset.assistant.map(\.defaultModel), ["gemini-3.5-flash", "gpt-5-mini", "openai/gpt-5-mini", "deepseek-chat"])
        for preset in AIProviderPreset.assistant {
            let service = AIService(preset: preset)
            let request = try AIRequestBuilder.generation(service: service, apiKey: "fixture-key", request: .init(messages: [.init(role: .user, content: "hello")], systemPrompt: "fixture role", temperature: 1))
            XCTAssertEqual(request.url?.absoluteString, preset.baseURL + "/chat/completions")
            let body = try json(request)
            XCTAssertEqual(body["temperature"] as? Double, 1)
            XCTAssertEqual(body["model"] as? String, preset.defaultModel)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        }
    }

    func testRejectsCredentialAndEndpointInjectionBeforeTransport() throws {
        for key in ["abc\rInjected: yes", "abc\nInjected: yes", "abc\u{0}"] {
            XCTAssertThrowsError(try AIRequestBuilder.generation(service: service, apiKey: key, request: .init(messages: []))) { XCTAssertEqual($0 as? AIError, .invalidKey) }
        }
        for url in ["https://user:password@example.com/v1", "https://example.com/v1?key=fixture", "https://example.com/v1#x", "ftp://example.com/v1", "http://example.com/v1"] {
            XCTAssertThrowsError(try AIRequestBuilder.normalizedBaseURL(url))
        }
        XCTAssertEqual(try AIRequestBuilder.normalizedBaseURL(" example.com/v1/chat/completions/// ").absoluteString, "https://example.com/v1")
        XCTAssertThrowsError(try AIRequestBuilder.validateModel("../admin"))
        XCTAssertThrowsError(try AIRequestBuilder.validateModel("model?api_key=fixture"))
    }

    func testVertexWireSchemaUsesSystemPartsMergedUserTurnsAndSkipsThoughts() throws {
        let vertex = AIService(url: AILLMPreset.vertex.baseURL, model: "google/gemini-3.5-flash-lite", wireProtocol: .vertex)
        let request = try AIRequestBuilder.generation(service: vertex, apiKey: "fixture-key", request: .init(messages: [.init(role: .user, content: "context"), .init(role: .user, content: "translate")], systemPrompt: "system", parameters: .translation))
        XCTAssertEqual(request.url?.path, "/v1/publishers/google/models/gemini-3.5-flash-lite:generateContent")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        let body = try json(request)
        XCTAssertNil(body["messages"])
        XCTAssertEqual((body["contents"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.count, 2)
        let response = try AIResponseParser.single(Data(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"fixture thought"},{"text":"Привет"},{"text":"!"}]},"finishReason":"STOP"}]}"#.utf8), wireProtocol: .vertex)
        XCTAssertEqual(response.text, "Привет!")
        XCTAssertEqual(response.reasoning, "fixture thought")
    }

    func testSSEByteBoundariesCRLFMultilineAndBOM() throws {
        let fixture = "\u{feff}: comment\r\ndata: {\"choices\":\r\ndata: [{\"delta\":{\"content\":\"Привет 👋\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        for stride in [1, 2, 3, 7, 19] {
            var parser = AISSEDecoder()
            var frames: [String] = []
            let bytes = Array(fixture.utf8)
            for start in Swift.stride(from: 0, to: bytes.count, by: stride) { frames += try parser.append(Data(bytes[start ..< min(start + stride, bytes.count)])) }
            frames += try parser.finish()
            XCTAssertEqual(frames.count, 2)
            var response = AIStreamAccumulator()
            for frame in frames { _ = try response.consume(frame) }
            XCTAssertEqual(try response.finish().1.text, "Привет 👋")
        }
    }

    func testReasoningTagsSplitAtEveryCharacterAndMixedReasoningDelta() throws {
        var filter = AIReasoningFilter()
        var text = ""
        var thought = ""
        for character in "Hello <think>local fixture 🤔</think>world" {
            let output = filter.append(String(character))
            text += output.text
            thought += output.reasoning
        }
        let tail = filter.finish()
        XCTAssertEqual(text + tail.text, "Hello world")
        XCTAssertEqual(thought + tail.reasoning, "local fixture 🤔")
        var stream = AIStreamAccumulator()
        _ = try stream.consume(#"{"choices":[{"delta":{"content":"answer","reasoning_content":"reason"}}]}"#)
        _ = try stream.consume("[DONE]")
        let result = try stream.finish().1
        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(result.reasoning, "reason")
    }

    func testTruncatedOrMalformedStreamNeverReportsSuccess() throws {
        var stream = AIStreamAccumulator()
        _ = try stream.consume(#"{"choices":[{"delta":{"content":"partial"}}]}"#)
        XCTAssertThrowsError(try stream.finish()) { XCTAssertEqual($0 as? AIError, .incompleteStream) }
        XCTAssertThrowsError(try stream.consume("not json")) { XCTAssertEqual($0 as? AIError, .invalidResponse) }
        XCTAssertThrowsError(try stream.consume(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)) { XCTAssertEqual($0 as? AIError, .responseTooLarge) }
        var parser = AISSEDecoder()
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: AILimits.eventBytes + 1)))
        XCTAssertThrowsError(try AIResponseParser.single(Data(#"{"error":{"message":"fixture-private-body-key"}}"#.utf8))) { XCTAssertFalse(String(describing: $0).contains("fixture-private")) }
    }

    func testModelListVariantsAndCatalog() throws {
        XCTAssertEqual(try AIResponseParser.models(Data(#"{"data":[{"id":"models/one"},"models/two",{"id":"models/one"}]}"#.utf8), stripModelsPrefix: true), ["one", "two"])
        XCTAssertEqual(try AIResponseParser.models(Data(#"{"models":["one"]}"#.utf8)), ["one"])
        XCTAssertThrowsError(try AIResponseParser.models(Data(#"{"data":[]}"#.utf8)))
        let catalog = try AIResponseParser.catalog(Data(#"{"fixture":{"models":{"one":{"name":"One","reasoning":true,"limit":{"context":8192}}}}}"#.utf8))
        XCTAssertEqual(catalog["one"]?.context, 8192)
        XCTAssertEqual(catalog["one"]?.reasoning, true)
    }

    func testURLProtocolStreamsThroughActualURLSessionDelegate() async throws {
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).fixture.test/v1")!
        let plan = AIMockURLProtocol.Plan(status: 200, type: "text/event-stream", pieces: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n".utf8), Data("data: {\"choices\":[{\"delta\":{\"content\":\" 👋\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)])
        AIMockURLProtocol.registry.install(host: url.host!, plan: plan)
        defer { AIMockURLProtocol.registry.remove(host: url.host!) }
        let client = AIClient(transport: mockTransport())
        let events = AIEventFixture()
        let response = try await client.generate(service: AIService(url: url.absoluteString, model: "fixture"), apiKey: "fixture-key", request: .init(messages: [.init(role: .user, content: "fixture")]), onEvent: { await events.append($0) })
        XCTAssertEqual(response.text, "Hello 👋")
        let updates = await events.events
        XCTAssertTrue(updates.contains(.text("Hello")))
    }

    func testCancellationClosesURLProtocolAndReturnsOnlyCancellation() async throws {
        let host = UUID().uuidString.lowercased() + ".fixture.test"
        let started = AIExpectationFixture(expectation(description: "started"))
        let stopped = AIExpectationFixture(expectation(description: "stopped"))
        AIMockURLProtocol.registry.install(host: host, plan: .init(status: 200, type: "text/event-stream", pieces: [], stall: true, started: { started.fulfill() }, stopped: { stopped.fulfill() }))
        defer { AIMockURLProtocol.registry.remove(host: host) }
        let client = AIClient(transport: mockTransport())
        let task = Task { try await client.generate(service: AIService(url: "https://\(host)/v1", model: "fixture"), apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "fixture")])) }
        await fulfillment(of: [started.expectation], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was treated as success") }
        catch { XCTAssertEqual(error as? AIError, .cancelled) }
        await fulfillment(of: [stopped.expectation], timeout: 2)
    }

    func testResourceTimeoutIsBoundedAndDoesNotEchoPrivateBody() async throws {
        let host = UUID().uuidString.lowercased() + ".fixture.test"
        AIMockURLProtocol.registry.install(host: host, plan: .init(status: 200, type: "application/json", pieces: [], stall: true))
        defer { AIMockURLProtocol.registry.remove(host: host) }
        var request = URLRequest(url: URL(string: "https://\(host)/fixture")!)
        request.httpBody = Data("fixture-private-body".utf8)
        do { _ = try await mockTransport().data(for: request, timeout: 0.1); XCTFail("Timeout was treated as success") }
        catch { XCTAssertEqual(error as? AIError, .timeout); XCTAssertFalse(String(describing: error).contains("fixture-private")) }
    }

    func testOptionalParameterRejectionRetriesOnceWithoutThem() async throws {
        let transport = AIScriptedTransport([
            .init(status: 400, body: #"{"error":{"message":"fixture"}}"#),
            .init(body: #"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#)
        ])
        let response = try await AIClient(transport: transport).generate(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "fixture")], streaming: false))
        XCTAssertEqual(response.text, "OK")
        let requests = transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(try json(requests[0])["temperature"])
        XCTAssertNil(try json(requests[1])["temperature"])
        XCTAssertEqual(try json(requests[1])["stream"] as? Bool, false)
    }

    func testToolsCallAllowlistedCallbackAndReturnToolMessage() async throws {
        let transport = AIScriptedTransport([
            .init(body: #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"fixture-call","type":"function","function":{"name":"fixture_sum","arguments":"{\"a\":2,\"b\":3}"}}]}}]}"#),
            .init(body: #"{"choices":[{"message":{"content":"5"},"finish_reason":"stop"}]}"#)
        ])
        let tools = AIToolHandler(definitions: [.init(name: "fixture_sum", description: "Local arithmetic fixture", parameters: .object(["type": .string("object")]))]) { name, arguments in
            guard name == "fixture_sum", case let .object(values) = arguments, let first = values["a"], let second = values["b"], case let .integer(a) = first, case let .integer(b) = second else { throw AIError.toolFailed }
            return String(a + b)
        }
        let response = try await AIClient(transport: transport).generate(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "fixture")]), tools: tools)
        XCTAssertEqual(response.text, "5")
        let messages = try XCTUnwrap(try json(transport.requests[1])["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "fixture-call")
        XCTAssertEqual(messages.last?["content"] as? String, "5")
    }

    func testPartialStreamingGenerationNeverGetsOptionalParameterRetry() async throws {
        let transport = AIScriptedTransport([
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", type: "text/event-stream", failure: .http(400)),
            .init(body: #"{"choices":[{"message":{"content":"replayed"}}]}"#)
        ])
        let events = AIEventFixture()
        do {
            _ = try await AIClient(transport: transport).generate(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "fixture")]), onEvent: { await events.append($0) })
            XCTFail("Partial generation was replayed")
        } catch { XCTAssertEqual(error as? AIError, .http(400)) }
        let updates = await events.events
        XCTAssertEqual(updates, [.text("partial")])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDeepSeekReasoningContinuationIsReplayedOnlyInAssistantToolRound() async throws {
        let transport = AIScriptedTransport([
            .init(body: #"{"choices":[{"message":{"content":null,"reasoning_content":"fixture-deepseek-continuation","private_unknown":"must-not-replay","tool_calls":[{"id":"read-1","type":"function","function":{"name":"fixture_read","arguments":"{}"}}]}}]}"#),
            .init(body: #"{"choices":[{"message":{"content":"Review complete"},"finish_reason":"stop"}]}"#)
        ])
        let tools = AIToolHandler(definitions: [.init(name: "fixture_read", description: "Fixture read", parameters: .object([:]))]) { _, _ in "fixture source" }
        let events = AIEventFixture()
        let result = try await AIClient(transport: transport).generate(service: AIService(url: "https://deepseek.fixture.test/v1", model: "deepseek-reasoner", reasoningEffort: 2), apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "Review fixture")]), tools: tools, onEvent: { await events.append($0) })
        XCTAssertEqual(result.text, "Review complete")
        XCTAssertEqual(result.reasoning, "fixture-deepseek-continuation")
        let messages = try XCTUnwrap(try json(transport.requests[1])["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual(assistant["reasoning_content"] as? String, "fixture-deepseek-continuation")
        XCTAssertNil(assistant["private_unknown"])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertNil(messages.last?["reasoning_content"])
        let updates = await events.events
        XCTAssertFalse(updates.contains(.text("fixture-deepseek-continuation")))
        XCTAssertTrue(updates.contains(.reasoning("fixture-deepseek-continuation")))
    }

    func testStructuredContinuationKeepsOpaqueStateAndDropsUnknownFields() async throws {
        let transport = AIScriptedTransport([
            .init(body: #"{"choices":[{"message":{"content":null,"reasoning":{"content":"display fixture","signature":"object-signature","unknown":"omit"},"reasoning_details":[{"type":"reasoning.text","text":"detail fixture","signature":"signature-sentinel","id":"r1","format":"fixture-v1","index":0,"untrusted":"omit"},{"type":"reasoning.encrypted","data":"encrypted-sentinel","id":"r2","index":1}],"tool_calls":[{"id":"read-1","type":"function","function":{"name":"fixture_read","arguments":"{}"}}]}}]}"#),
            .init(body: #"{"choices":[{"message":{"content":"Done"}}]}"#)
        ])
        let tools = AIToolHandler(definitions: [.init(name: "fixture_read", description: "Fixture read", parameters: .object([:]))]) { _, _ in "source" }
        let result = try await AIClient(transport: transport).generate(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "Review fixture")]), tools: tools)
        XCTAssertEqual(result.reasoning, "display fixture")
        XCTAssertFalse(result.reasoning.contains("encrypted-sentinel"))
        let messages = try XCTUnwrap(try json(transport.requests[1])["messages"] as? [[String: Any]])
        let object = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" }?["reasoning"] as? [String: String])
        XCTAssertEqual(object["signature"], "object-signature")
        XCTAssertNil(object["unknown"])
        let details = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" }?["reasoning_details"] as? [[String: Any]])
        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(details[0]["signature"] as? String, "signature-sentinel")
        XCTAssertEqual(details[0]["format"] as? String, "fixture-v1")
        XCTAssertEqual(details[1]["data"] as? String, "encrypted-sentinel")
        XCTAssertEqual(details[1]["index"] as? Int, 1)
        XCTAssertNil(details[0]["untrusted"])
    }

    func testContinuationBudgetRejectsBeforeExecutingTools() async throws {
        let call: [String: Any] = ["id": "read-1", "type": "function", "function": ["name": "fixture_read", "arguments": "{}"]]
        let message: [String: Any] = ["content": NSNull(), "reasoning_details": [["type": "reasoning.encrypted", "data": String(repeating: "x", count: AILimits.eventBytes + 1)]], "tool_calls": [call]]
        let body: [String: Any] = ["choices": [["message": message]]]
        let transport = AIScriptedTransport([.init(body: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))])
        let tools = AIToolHandler(definitions: [.init(name: "fixture_read", description: "Fixture read", parameters: .object([:]))]) { _, _ in XCTFail("Oversized continuation reached a tool"); return "" }
        do {
            _ = try await AIClient(transport: transport).generate(service: service, apiKey: "fixture", request: .init(messages: [.init(role: .user, content: "fixture")]), tools: tools)
            XCTFail("Oversized continuation was accepted")
        } catch { XCTAssertEqual(error as? AIError, .responseTooLarge) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    private func mockTransport() -> AIURLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIMockURLProtocol.self]
        return AIURLSessionTransport(configuration: config, resourceTimeout: 2)
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

actor AIEventFixture {
    var events: [AIGenerationEvent] = []
    func append(_ value: AIGenerationEvent) { events.append(value) }
}

final class AIExpectationFixture: @unchecked Sendable {
    let expectation: XCTestExpectation
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func fulfill() { expectation.fulfill() }
}

final class AIScriptedTransport: AIHTTPTransport, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        let type: String
        let failure: AIError?
        init(status: Int = 200, body: String = "", type: String = "application/json", failure: AIError? = nil) {
            self.status = status; self.body = body; self.type = type; self.failure = failure
        }
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var captured: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        lock.lock()
        captured.append(request)
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard let reply else { continuation.finish(throwing: AIError.network); return }
            continuation.yield(.response(status: reply.status, headers: ["content-type": reply.type]))
            continuation.yield(.data(Data(reply.body.utf8)))
            continuation.finish(throwing: reply.failure)
        }
    }
}

final class AIMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable {
        var status: Int
        var type: String
        var pieces: [Data]
        var stall = false
        var started: (@Sendable () -> Void)? = nil
        var stopped: (@Sendable () -> Void)? = nil
    }
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [String: Plan] = [:]
        func install(host: String, plan: Plan) { lock.lock(); plans[host] = plan; lock.unlock() }
        func remove(host: String) { lock.lock(); plans.removeValue(forKey: host); lock.unlock() }
        func plan(host: String) -> Plan? { lock.lock(); defer { lock.unlock() }; return plans[host] }
    }
    static let registry = Registry()
    // Always intercept: even a broken fixture cannot reach a real provider.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let plan = Self.registry.plan(host: url.host ?? ""), let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": plan.type]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in plan.pieces { client?.urlProtocol(self, didLoad: piece) }
        plan.started?()
        if !plan.stall { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.registry.plan(host: request.url?.host ?? "")?.stopped?() }
}
