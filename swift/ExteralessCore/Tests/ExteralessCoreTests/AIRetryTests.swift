import Foundation
import XCTest
@testable import ExteralessCore

final class AIRetryTests: XCTestCase, @unchecked Sendable {
    func testRecoverableServerFailureRetriesThenSucceedsWithRotatedKey() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let transport = AIScriptedTransport([.init(status: 503), .init(body: #"{"choices":[{"message":{"content":"Bonjour"}}]}"#)])
        let delays = AIRetryAttempts()
        let translator = AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { await delays.append($0) })
        let result = try await translator.translate(.init(text: "Hello"), to: "fr", configuration: configuration(fixture.settings))
        XCTAssertEqual(result.text.text, "Bonjour")
        XCTAssertEqual(result.provider, .llm)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer fixture-one", "Bearer fixture-two"])
        let attempts = await delays.values
        XCTAssertEqual(attempts, [0])
    }

    func testThreeServerFailuresFallBackToGoogleExactlyOnce() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let transport = AIScriptedTransport([.init(status: 502), .init(status: 502), .init(status: 502), .init(body: #"{"sentences":[{"trans":"Bonjour"}]}"#)])
        let delays = AIRetryAttempts()
        let result = try await AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { await delays.append($0) }).translate(.init(text: "Hello"), to: "fr", configuration: configuration(fixture.settings))
        XCTAssertEqual(result.text.text, "Bonjour")
        XCTAssertEqual(result.provider, .google)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["llm.fixture.test", "llm.fixture.test", "llm.fixture.test", "translate.google.com"])
        XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Authorization"))
        let attempts = await delays.values
        XCTAssertEqual(attempts, [0, 1])
    }

    func testAICF01CloudFallbackKeepsHTMLIntentSpansAndSeparateCredentials() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let formatted = AIFormattedText(text: "Hi 👋 docs", spans: [
            .init(id: 0, offset: 0, length: 2, tag: .bold),
            .init(id: 1, offset: 3, length: 2, tag: .protected, preserveText: true),
            .init(id: 2, offset: 6, length: 4, tag: .link)
        ])
        let encoded = #"<b data-e="0">Hi</b> <tg-emoji data-e="1">👋</tg-emoji> <a data-e="2">docs</a>"#
        let translated = #"<b data-e="0">Bonjour</b> <tg-emoji data-e="1">👋</tg-emoji> <a data-e="2">documentation</a>"#
        let restored = AIFormattedText(text: "Bonjour 👋 documentation", spans: [
            .init(id: 0, offset: 0, length: 7, tag: .bold),
            .init(id: 1, offset: 8, length: 2, tag: .protected, preserveText: true),
            .init(id: 2, offset: 11, length: 13, tag: .link)
        ])
        let cases: [(input: AIFormattedText, preserve: Bool, query: String, response: String, expected: AIFormattedText?)] = [
            (formatted, true, encoded, translated, restored),
            (.init(text: formatted.text), true, formatted.text, restored.text, .init(text: restored.text)),
            (formatted, false, formatted.text, restored.text, .init(text: restored.text)),
            (formatted, true, encoded, translated.replacingOccurrences(of: "👋", with: "🙃"), nil)
        ]
        for item in cases {
            var config = configuration(fixture.settings)
            config.preserveFormatting = item.preserve
            config.googleExperimental = false
            config.googleCloudKey = "fixture-google-cloud-key"
            let response = try JSONSerialization.data(withJSONObject: ["data": ["translations": [["translatedText": item.response]]]])
            let transport = AIScriptedTransport([.init(status: 502), .init(status: 502), .init(status: 502), .init(body: String(decoding: response, as: UTF8.self))])
            let translator = AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { _ in })
            do {
                let result = try await translator.translate(item.input, to: "fr", configuration: config)
                if let expected = item.expected { XCTAssertEqual(result.text, expected) }
                else { XCTFail("AICF-01: changed protected text passed validation") }
                XCTAssertEqual(result.provider, .google)
                XCTAssertTrue(result.usedFallback)
            } catch {
                if item.expected == nil { XCTAssertEqual(error as? AIError, .formattingLost) }
                else { throw error }
            }
            let requests = transport.requests
            XCTAssertEqual(requests.map { $0.url?.host }, ["llm.fixture.test", "llm.fixture.test", "llm.fixture.test", "translation.googleapis.com"])
            let cloud = try XCTUnwrap(requests.last)
            XCTAssertNil(cloud.value(forHTTPHeaderField: "Authorization"))
            let body = String(decoding: try XCTUnwrap(cloud.httpBody), as: UTF8.self)
            let fields = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems)
            XCTAssertEqual(fields.first { $0.name == "q" }?.value, item.query)
            XCTAssertEqual(fields.first { $0.name == "format" }?.value, item.preserve && !item.input.spans.isEmpty ? "html" : "text")
            XCTAssertEqual(fields.first { $0.name == "key" }?.value, "fixture-google-cloud-key")
            XCTAssertFalse(body.contains("fixture-one"))
            XCTAssertFalse(body.contains("fixture-two"))
            let first = try XCTUnwrap(requests.first)
            let llmBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(first.httpBody)) as? [String: Any])
            let prompt = try XCTUnwrap((llmBody["messages"] as? [[String: Any]])?.last?["content"] as? String)
            XCTAssertTrue(prompt.contains(item.query))
        }
    }

    func testEmptyAndMalformedSuccessfulResponsesUseSameBoundedFallback() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let transport = AIScriptedTransport([
            .init(body: #"{"choices":[{"message":{"content":" "}}]}"#),
            .init(body: "invalid fixture JSON"), .init(body: #"{"choices":[]}"#),
            .init(body: #"{"sentences":[{"trans":"Salut"}]}"#)
        ])
        let result = try await AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { _ in }).translate(.init(text: "Hi"), to: "fr", configuration: configuration(fixture.settings))
        XCTAssertEqual(result.text.text, "Salut")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testCredentialCancellationAndPartialResponseFailuresDoNotRetryOrFallback() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        for failure in [AIError.http(401), .http(403), .cancelled, .incompleteStream, .responseTooLarge, .blocked] {
            let transport = AIScriptedTransport([.init(failure: failure), .init(body: #"{"sentences":[{"trans":"must not run"}]}"#)])
            let translator = AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { _ in XCTFail("Non-recoverable error reached backoff") })
            do {
                _ = try await translator.translate(.init(text: "Hi"), to: "fr", configuration: configuration(fixture.settings))
                XCTFail("Non-recoverable failure was swallowed")
            } catch { XCTAssertEqual(error as? AIError, failure) }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testCancellationDuringBackoffCannotStartAnotherRequest() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let entered = AIExpectationFixture(expectation(description: "backoff entered"))
        let transport = AIScriptedTransport([.init(status: 503)])
        let translator = AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { _ in
            entered.fulfill()
            try await Task.sleep(nanoseconds: 2_000_000_000)
        })
        let config = configuration(fixture.settings)
        let task = Task { try await translator.translate(.init(text: "Hi"), to: "fr", configuration: config) }
        await fulfillment(of: [entered.expectation], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled backoff continued") }
        catch { XCTAssertEqual(error as? AIError, .cancelled) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testLengthLimitedPartialProviderResultIsNotRetried() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let transport = AIScriptedTransport([.init(body: #"{"choices":[{"message":{"content":"partial generation"},"finish_reason":"length"}]}"#)])
        let translator = AITranslationClient(transport: transport, settings: fixture.settings, retryDelay: { _ in XCTFail("Partial result reached backoff") })
        do {
            _ = try await translator.translate(.init(text: "Hi"), to: "fr", configuration: configuration(fixture.settings))
            XCTFail("Partial result was accepted")
        } catch { XCTAssertEqual(error as? AIError, .responseTooLarge) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    private func configuration(_ settings: AISettings) -> AITranslationConfiguration {
        var config = AITranslationConfiguration(settings: settings)
        config.provider = .llm
        config.llmService = AIService(url: "https://llm.fixture.test/v1", model: "fixture")
        config.llmKeys = ["fixture-one", "fixture-two"]
        return config
    }
}

private actor AIRetryAttempts {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
