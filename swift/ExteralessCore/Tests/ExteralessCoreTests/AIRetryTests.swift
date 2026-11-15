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
