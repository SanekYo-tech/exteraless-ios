import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class EmojiFontHTTPTests: XCTestCase, @unchecked Sendable {
    private func client() -> EmojiFontHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmojiFontURLProtocol.self]
        return EmojiFontHTTPClient(configuration: configuration)
    }

    func testLocalURLProtocolStreamsValidatedFontAndReportsActualSHA() async throws {
        let url = URL(string: "https://\(UUID().uuidString).invalid/emoji.ttf")!
        EmojiFontURLProtocol.plans.set(url, .init(headers: ["Content-Type": "font/ttf"], chunks: [Data(EmojiFontFixture.data.prefix(300)), Data(EmojiFontFixture.data.dropFirst(300))]))
        defer { EmojiFontURLProtocol.plans.remove(url) }
        let result = try await client().download(url: url, expectedSHA256: EmojiFontFixture.sha256)
        XCTAssertEqual(result.data, EmojiFontFixture.data)
        XCTAssertEqual(result.inspection.sha256, EmojiFontFixture.sha256)
        XCTAssertEqual(result.url, url)
    }

    func testMIMEDeclaredSizeHTTPAndChecksumFailuresNeverProduceCandidate() async throws {
        let plans: [(EmojiFontURLProtocol.Plan, EmojiPackError)] = [
            (.init(headers: ["Content-Type": "text/html"], chunks: []), .invalidFont("HTTP content type")),
            (.init(headers: ["Content-Type": "font/ttf", "Content-Length": "\(EmojiPackLimits.fontBytes + 1)"], chunks: []), .tooLarge),
            (.init(status: 403, headers: ["Content-Type": "font/ttf"], chunks: []), .http(403)),
            (.init(headers: ["Content-Type": "font/ttf"], chunks: [EmojiFontFixture.data]), .checksumMismatch)
        ]
        for (plan, expected) in plans {
            let url = URL(string: "https://\(UUID().uuidString).invalid/font.ttf")!
            EmojiFontURLProtocol.plans.set(url, plan)
            defer { EmojiFontURLProtocol.plans.remove(url) }
            do { _ = try await client().download(url: url, expectedSHA256: String(repeating: "0", count: 64)); XCTFail("Failed download returned a font") }
            catch { XCTAssertEqual(error as? EmojiPackError, expected) }
        }
    }

    func testCancelStopsStalledURLProtocolAndReleasesCompletion() async throws {
        let url = URL(string: "https://\(UUID().uuidString).invalid/font.ttf")!
        let started = EmojiFontExpectation(expectation(description: "started"))
        let stopped = EmojiFontExpectation(expectation(description: "stopped"))
        EmojiFontURLProtocol.plans.set(url, .init(headers: ["Content-Type": "font/ttf"], chunks: [], stall: true, started: { started.value.fulfill() }, stopped: { stopped.value.fulfill() }))
        defer { EmojiFontURLProtocol.plans.remove(url) }
        let client = client()
        let request = Task { try await client.download(url: url) }
        await fulfillment(of: [started.value], timeout: 2)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertEqual(error as? EmojiPackError, .cancelled) }
        await fulfillment(of: [stopped.value], timeout: 2)
    }

    func testNonHTTPSCredentialURLsArchivesAndRedirectDowngradeAreRejected() {
        for text in ["http://fixture.invalid/font.ttf", "https://user:pass@fixture.invalid/font.ttf", "https://fixture.invalid/font.ttf#x", "https://fixture.invalid/font.zip", "file:///font.ttf"] {
            XCTAssertThrowsError(try EmojiFontHTTPClient.validatedURL(text))
        }
        XCTAssertNoThrow(try EmojiFontHTTPClient.validatedURL("https://fixture.invalid/font.otf?version=1"))
    }
}

private final class EmojiFontExpectation: @unchecked Sendable {
    let value: XCTestExpectation
    init(_ value: XCTestExpectation) { self.value = value }
}

private final class EmojiFontURLProtocol: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable {
        var status = 200
        var headers: [String: String]
        var chunks: [Data]
        var stall = false
        var started: (@Sendable () -> Void)?
        var stopped: (@Sendable () -> Void)?
    }
    final class Plans: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL: Plan] = [:]
        func set(_ url: URL, _ plan: Plan) { lock.lock(); values[url] = plan; lock.unlock() }
        func get(_ url: URL) -> Plan? { lock.lock(); defer { lock.unlock() }; return values[url] }
        func remove(_ url: URL) { lock.lock(); values.removeValue(forKey: url); lock.unlock() }
    }
    static let plans = Plans()
    private let lock = NSLock()
    private var didStop = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host?.hasSuffix(".invalid") == true, let plan = Self.plans.get(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        plan.started?()
        let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in plan.chunks { client?.urlProtocol(self, didLoad: data) }
        if !plan.stall { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        lock.lock()
        let notify = !didStop
        didStop = true
        lock.unlock()
        if notify, let url = request.url { Self.plans.get(url)?.stopped?() }
    }
}
