import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

/// Canned HTTP envelopes matching the pinned original provider schemas. These
/// fixtures use synthetic track metadata; no live song query/account is used.
final class PlayerLyricsClientTests: XCTestCase, @unchecked Sendable {
    private func query() -> PlayerLyricsQuery { .init(artist: "Fixture Band", title: "Fixture " + UUID().uuidString, album: "Fixture Album", duration: 180) }
    private func track(_ query: PlayerLyricsQuery, resource: String = "fixture-file", duration: Double = 180, account: Int64 = 1) -> PlayerLyricsTrack {
        .init(account: account, resource: resource, duration: duration, query: query)
    }
    private func transport() -> PlayerLyricsURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayerLyricsFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "must-not-leave-test", "Cookie": "must-not-leave-test"]
        return PlayerLyricsURLSessionTransport(configuration: configuration)
    }
    private func client(cacheURL: URL? = nil, timeout: Double = 2) -> PlayerLyricsClient { .init(transport: transport(), cacheURL: cacheURL, timeout: timeout, retryDelays: [0, 0]) }
    private func lrclib(_ query: PlayerLyricsQuery, synced: String? = "[00:01.00]Hello world\n[00:05.00]Again", plain: String? = nil, duration: Double = 180, artist: String? = nil, id: Int = 1) throws -> Data {
        var object: [String: Any] = ["id": id, "trackName": query.title, "artistName": artist ?? query.artist, "albumName": query.album, "duration": duration, "instrumental": false]
        object["syncedLyrics"] = synced.map { $0 as Any } ?? NSNull()
        object["plainLyrics"] = plain.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testPinnedURLsQueryEncodingAndTitleCleanup() throws {
        let query = PlayerLyricsQuery(artist: nil, title: "Artist - A+B & Song (Official Audio).mp3", album: "Album/#1", duration: 120.6)
        XCTAssertEqual(query.artist, "Artist")
        XCTAssertEqual(query.title, "A+B & Song")
        let exact = try PlayerLyricsRequest.make(query: query, endpoint: .exact)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(exact.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "lrclib.net")
        XCTAssertEqual(components.path, "/api/get")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "track_name" })?.value, "A+B & Song")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "duration" })?.value, "121")
        XCTAssertTrue(exact.url!.absoluteString.contains("%2B"))
        let fallback = try PlayerLyricsRequest.make(query: query, endpoint: .fallback)
        XCTAssertEqual(fallback.url?.host, "api.lrcmux.dev")
        XCTAssertEqual(fallback.url?.path, "/get")
        XCTAssertTrue(fallback.url!.absoluteString.contains("level=line&format=json"))
    }

    func testExactSyncedResultStopsBeforeSearchAndFallbackAndStripsCredentials() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(data: try lrclib(query))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let result = try await client().lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(result.lyrics?.provider, "LRCLIB")
        XCTAssertEqual(result.lyrics?.lines.first?.time, 1)
        let requests = PlayerLyricsFixtureProtocol.registry.requests(query: query.title)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
    }

    func testSearchRejectsWrongRecordingAndChoosesDurationMatchedSyncedLyrics() async throws {
        let query = query()
        let bad = try JSONSerialization.jsonObject(with: lrclib(query, duration: 400, id: 1))
        let good = try JSONSerialization.jsonObject(with: lrclib(query, duration: 182, id: 2))
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(status: 404)])
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/search", plans: [.init(data: try JSONSerialization.data(withJSONObject: [bad, good]))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let result = try await client().lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(result.state, .lyrics)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(PlayerLyricsMatching.best(result.candidates, query: query)?.id, "lrclib:2")
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 2)
    }

    func testFallbackUsesMillisecondsAndAlignsPunctuationFromPrimaryPlainLyrics() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(data: try lrclib(query, synced: nil, plain: "Hello, world! Again."))])
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "api.lrcmux.dev/get", plans: [.init(data: Data(#"{"track":{"duration":183},"meta":{"level":"line","source":{"name":"Fixture"}},"lines":[{"start":1250,"text":"hello world"},{"start":4000,"text":"again"}]}"#.utf8))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let result = try await client().lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(result.lyrics?.lines.map(\.time), [1.25, 4])
        XCTAssertEqual(result.lyrics?.lines.map(\.text), ["hello, world!", "again."])
        XCTAssertEqual(result.lyrics?.provider, "lrcmux · Fixture + LRCLIB")
    }

    func testFallbackRejectsOverFiveSecondMismatchAndKeepsEmbeddedText() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "api.lrcmux.dev/get", plans: [.init(data: Data(#"{"track":{"duration":186},"meta":{"level":"line"},"lines":[{"start":1000,"text":"wrong recording"}]}"#.utf8))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let embedded = try XCTUnwrap(PlayerLyricsDocument.parse("Embedded text"))
        let result = try await client().lookup(track: track(query), onlineAllowed: true, embedded: embedded)
        XCTAssertEqual(result.lyrics, embedded)
        XCTAssertFalse(result.lyrics?.synced ?? true)
    }

    func testConsentOffNeverContactsEitherProviderAndEmbeddedSyncWins() async throws {
        let query = query()
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let client = client()
        let result = try await client.lookup(track: track(query), onlineAllowed: false)
        XCTAssertEqual(result.state, .offerOnline)
        let embedded = try XCTUnwrap(PlayerLyricsDocument.parse("[00:01]Local"))
        let local = try await client.lookup(track: track(query), onlineAllowed: true, embedded: embedded)
        XCTAssertEqual(local.lyrics, embedded)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 0)
    }

    func testUserSelectionOffsetPersistsOfflineAndSurvivesAlbumMetadataArrival() async throws {
        let query = query()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lyrics.json")
        let client = client(cacheURL: url)
        let selected = try XCTUnwrap(PlayerLyricsDocument.parse("[00:02]Selected", source: .user, provider: "Your lyrics"))
        try await client.setOverride(.init(lyrics: selected, offset: 0.7), for: track(query))
        let enriched = PlayerLyricsQuery(artist: query.artist, title: query.title, album: "Late embedded album", duration: 180)
        let restored = try await self.client(cacheURL: url).lookup(track: track(enriched), onlineAllowed: false)
        XCTAssertEqual(restored.lyrics, selected)
        XCTAssertEqual(restored.userOffset, 0.7)
        XCTAssertTrue(restored.isUserSelection)
        let otherDuration = try await client.lookup(track: track(query, duration: 181), onlineAllowed: false)
        XCTAssertEqual(otherDuration.state, .offerOnline)
        let otherAccount = try await client.lookup(track: track(query, account: 2), onlineAllowed: false)
        XCTAssertEqual(otherAccount.state, .offerOnline)
    }

    func testCacheIsTwentyFourEntriesAndNotSharedByDistinctResources() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(data: try lrclib(query))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let client = client()
        for index in 0..<26 { _ = try await client.lookup(track: track(query, resource: "file-\(index)"), onlineAllowed: true) }
        let counts = await client.cacheCounts()
        XCTAssertEqual(counts.lyrics, 24)
        _ = try await client.lookup(track: track(query, resource: "file-25"), onlineAllowed: true)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 26)
        _ = try await client.lookup(track: track(query, resource: "file-0"), onlineAllowed: true)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 27)
    }

    func testKnownMissingIsCachedButTransientFailureIsNot() async throws {
        let query = query()
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let client = client()
        let missing = try await client.lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(missing.state, .notFound)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 3)
        _ = try await client.lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 3)
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(status: 503)])
        do { _ = try await client.lookup(track: track(query, resource: "transient"), onlineAllowed: true); XCTFail("503 must remain a failure") }
        catch { XCTAssertEqual(error as? PlayerLyricsError, .http(503)) }
        let counts = await client.cacheCounts()
        XCTAssertEqual(counts.missing, 1)
    }

    func testTransientRetryIsBoundedAndLaterSuccessIsUsed() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(status: 503), .init(status: 429), .init(data: try lrclib(query))])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let result = try await client().lookup(track: track(query), onlineAllowed: true)
        XCTAssertEqual(result.state, .lyrics)
        XCTAssertEqual(PlayerLyricsFixtureProtocol.registry.requests(query: query.title).count, 3)
    }

    func testCancellationClosesActualURLSessionProtocol() async throws {
        let query = query()
        let began = PlayerLyricsExpectation(expectation(description: "request began"))
        let stopped = PlayerLyricsExpectation(expectation(description: "request cancelled"))
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(stall: true, began: { began.fulfill() }, stopped: { stopped.fulfill() })])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let client = client()
        let track = track(query)
        let task = Task { try await client.lookup(track: track, onlineAllowed: true) }
        await fulfillment(of: [began.value], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not return lyrics") }
        catch { XCTAssertTrue(error is CancellationError || error as? PlayerLyricsError == .cancelled) }
        await fulfillment(of: [stopped.value], timeout: 1)
        let counts = await client.cacheCounts()
        XCTAssertEqual(counts.lyrics, 0)
        XCTAssertEqual(counts.missing, 0)
    }

    func testHeaderAndStreamingBodyLimitsAbortBeforeUnboundedBuffering() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(headers: ["Content-Length": String(PlayerLyricsLimits.responseBytes + 1)])])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let request = try PlayerLyricsRequest.make(query: query, endpoint: .exact)
        do { _ = try await transport().send(request, timeout: 1); XCTFail("Expected size limit") }
        catch { XCTAssertEqual(error as? PlayerLyricsError, .responseTooLarge) }
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(data: Data(repeating: 65, count: PlayerLyricsLimits.responseBytes + 1))])
        do { _ = try await transport().send(request, timeout: 1); XCTFail("Expected streaming size limit") }
        catch { XCTAssertEqual(error as? PlayerLyricsError, .responseTooLarge) }
    }

    func testWholeLookupTimeoutDoesNotRetryForeverOrLeakResponseText() async throws {
        let query = query()
        PlayerLyricsFixtureProtocol.registry.install(query: query.title, path: "lrclib.net/api/get", plans: [.init(stall: true)])
        defer { PlayerLyricsFixtureProtocol.registry.remove(query: query.title) }
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await client(timeout: 0.08).lookup(track: track(query), onlineAllowed: true); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? PlayerLyricsError, .timeout); XCTAssertFalse(error.localizedDescription.contains(query.title)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }
}

private final class PlayerLyricsExpectation: @unchecked Sendable {
    let value: XCTestExpectation
    init(_ value: XCTestExpectation) { self.value = value }
    func fulfill() { value.fulfill() }
}

private final class PlayerLyricsFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        var stall = false
        var began: (@Sendable () -> Void)?
        var stopped: (@Sendable () -> Void)?
    }
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [String: [Plan]] = [:]
        private var captured: [String: [URLRequest]] = [:]
        func install(query: String, path: String, plans: [Plan]) { lock.lock(); self.plans[query + "|" + path] = plans; lock.unlock() }
        func remove(query: String) { lock.lock(); plans = plans.filter { !$0.key.hasPrefix(query + "|") }; captured.removeValue(forKey: query); lock.unlock() }
        func requests(query: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured[query] ?? [] }
        func take(_ request: URLRequest) -> Plan {
            lock.lock()
            defer { lock.unlock() }
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let query = components?.queryItems?.first(where: { $0.name == "track_name" || $0.name == "title" })?.value ?? ""
            captured[query, default: []].append(request)
            let key = query + "|" + (request.url?.host ?? "") + (request.url?.path ?? "")
            guard var values = plans[key], let first = values.first else { return Plan(status: 404) }
            if values.count > 1 { values.removeFirst(); plans[key] = values }
            return first
        }
    }
    static let registry = Registry()
    private var plan: Plan?
    // Intercept everything, including a broken test URL: never escape to DNS/HTTP.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan = Self.registry.take(request)
        self.plan = plan
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers.merging(["Content-Type": "application/json"], uniquingKeysWith: { first, _ in first })) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !plan.data.isEmpty { client?.urlProtocol(self, didLoad: plan.data) }
        plan.began?()
        if !plan.stall { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { plan?.stopped?() }
}
