import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class ToolsReleaseTests: XCTestCase, @unchecked Sendable {
    private let repository = try! ToolsReleaseRepository(owner: "fixture", name: "ios")

    private func client(hooks: ToolsReleaseTransferHooks = .init()) -> ToolsReleaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolsReleaseFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "must-not-be-forwarded"]
        return ToolsReleaseClient(repository: repository, configuration: configuration, transferHooks: hooks)
    }

    private func response(asset: Data = Data([0x50, 0x4b, 3, 4, 5, 6]), digest: String? = nil, prerelease: Bool = false) throws -> Data {
        let object: [[String: Any]] = [["id": 1, "tag_name": "v13.1.1+100", "name": "Fixture release", "body": "Offline fixture only", "draft": false,
                                        "prerelease": prerelease, "assets": [["name": "fixture-arm64.ipa", "size": asset.count,
                                        "browser_download_url": "https://github.com/fixture/ios/releases/download/v13.1.1%2B100/fixture-arm64.ipa",
                                        "digest": "sha256:" + (digest ?? ToolsSHA256.hex(asset))]]]]
        return try JSONSerialization.data(withJSONObject: object)
    }

    override func tearDown() { ToolsReleaseFixtureProtocol.reset(); super.tearDown() }

    func testNumericVersionsBuildNumbersAndUnknownComparison() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ToolsBuildNumber("100")), try XCTUnwrap(ToolsBuildNumber("99")))
        XCTAssertEqual(ToolsBuildNumber("1.0"), ToolsBuildNumber("1"))
        XCTAssertNil(ToolsBuildNumber("18446744073709551616"))
        XCTAssertNil(ToolsBuildNumber("1..2"))
        XCTAssertEqual(try XCTUnwrap(ToolsReleaseVersion(tag: "v13.10.1+2")).compared(to: XCTUnwrap(ToolsReleaseVersion(tag: "13.9.1", buildNumber: "999"))), .newer)
        XCTAssertEqual(try XCTUnwrap(ToolsReleaseVersion(tag: "v13.1.1+100")).compared(to: XCTUnwrap(ToolsReleaseVersion(tag: "13.1.1", buildNumber: "99"))), .newer)
        XCTAssertEqual(try XCTUnwrap(ToolsReleaseVersion(tag: "v13.1.1")).compared(to: XCTUnwrap(ToolsReleaseVersion(tag: "13.1.1", buildNumber: "99"))), .unknown)
        XCTAssertEqual(try XCTUnwrap(ToolsReleaseVersion(tag: "v13.1.1-beta10+1")).compared(to: XCTUnwrap(ToolsReleaseVersion(tag: "13.1.1-beta2", buildNumber: "99"))), .newer)
    }

    func testReleaseSelectionFiltersPrereleaseDraftAndroidAndUntrustedHosts() throws {
        XCTAssertNil(try ToolsReleaseClient.decodeReleases(response(prerelease: true), repository: repository, includePrereleases: false))
        var items = try XCTUnwrap(JSONSerialization.jsonObject(with: response()) as? [[String: Any]])
        items[0]["draft"] = true
        XCTAssertNil(try ToolsReleaseClient.decodeReleases(JSONSerialization.data(withJSONObject: items), repository: repository, includePrereleases: true))
        XCTAssertFalse(repository.acceptsAssetURL(URL(string: "https://github.com.evil.invalid/fixture/ios/releases/download/v1/x.ipa")!))
        XCTAssertFalse(repository.acceptsAssetURL(URL(string: "https://fixture:password@github.com/fixture/ios/releases/download/v1/x.ipa")!))
        XCTAssertFalse(repository.acceptsAssetURL(URL(string: "https://github.com/other/ios/releases/download/v1/x.ipa")!))
    }

    func testPublicAPIRequestCarriesNoCredentials() async throws {
        ToolsReleaseFixtureProtocol.set(repository.apiURL, fixture: .init(data: try response()))
        let release = try await client().latest(includePrereleases: false)
        XCTAssertEqual(release?.tag, "v13.1.1+100")
        let request = try XCTUnwrap(ToolsReleaseFixtureProtocol.requests().last)
        XCTAssertEqual(request.url, repository.apiURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testRateLimitErrorIsReadableAndDoesNotEchoResponseBody() async throws {
        ToolsReleaseFixtureProtocol.set(repository.apiURL, fixture: .init(status: 403, headers: ["X-RateLimit-Remaining": "0"], data: Data("fixture-private-body".utf8)))
        do { _ = try await client().latest(includePrereleases: false); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? ToolsError, .rateLimited); XCTAssertFalse(error.localizedDescription.contains("fixture-private-body")) }
    }

    func testSmallDownloadStreamsChecksHashAndReportsRealProgress() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4] + Array(repeating: UInt8(42), count: 128))
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tools-release-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = ToolsReleaseProgress()
        let downloaded = try await client().download(release, directory: directory) { progress.append($0, $1) }
        XCTAssertEqual(try Data(contentsOf: downloaded.url), bytes)
        XCTAssertEqual(downloaded.sha256, ToolsSHA256.hex(bytes))
        XCTAssertEqual(progress.last()?.0, Int64(bytes.count))
        XCTAssertEqual(progress.last()?.1, Int64(bytes.count))
        XCTAssertEqual(downloaded.url.pathExtension, "ipa")
    }

    func testChecksumFailureRemovesAllPartialDownloadFiles() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4, 5, 6])
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes, digest: String(repeating: "0", count: 64)), repository: repository, includePrereleases: false))
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tools-release-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await client().download(release, directory: directory) { _, _ in }; XCTFail("Expected checksum error") }
        catch { XCTAssertEqual(error as? ToolsError, .checksumMismatch) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationWhileWaitingForBodyCancelsURLSessionTask() async throws {
        let began = expectation(description: "request began")
        let stopped = expectation(description: "request cancelled")
        ToolsReleaseFixtureProtocol.set(repository.apiURL, fixture: .init(data: Data(), stall: true, began: { began.fulfill() }, stopped: { stopped.fulfill() }))
        let client = client()
        let task = Task { try await client.latest(includePrereleases: false) }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testAutomaticChecksAreOptInAndSixHourBounded() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(ToolsUpdateSchedule.shouldCheck(channel: 0, lastAttempt: nil, now: now))
        XCTAssertFalse(ToolsUpdateSchedule.shouldCheck(channel: 1, lastAttempt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ToolsUpdateSchedule.shouldCheck(channel: 2, lastAttempt: now.addingTimeInterval(-21_600), now: now))
    }

    func testTB05CancellationDrainsAcceptedHeadersBeforeCallerReturns() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4, 5, 6])
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        let root = try releaseDirectory()
        let accepted = expectation(description: "actual response delegate entered")
        let cleaned = expectation(description: "serial file owner drained")
        let gate = DispatchSemaphore(value: 0)
        let progress = ToolsReleaseProgress()
        let hooks = ToolsReleaseTransferHooks(afterResponseValidation: {
            accepted.fulfill()
            _ = gate.wait(timeout: .now() + 2)
        }, afterCleanup: { cleaned.fulfill() })
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes, chunks: [Data(bytes.prefix(4)), Data(bytes.suffix(2))]))
        let client = client(hooks: hooks)
        let task = Task { try await client.download(release, directory: root) { progress.append($0, $1) } }
        await fulfillment(of: [accepted], timeout: 2)
        task.cancel()
        gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cleaned], timeout: 2)
        XCTAssertNil(progress.last())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testTB05CancellationAfterFirstWriteClosesAndUnlinksBeforeReturn() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4] + Array(repeating: UInt8(7), count: 128))
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        let root = try releaseDirectory(), cancel = ToolsReleaseCancellation()
        let wrote = expectation(description: "actual first partial-file write")
        let cleaned = expectation(description: "open partial closed and unlinked")
        let progress = ToolsReleaseProgress()
        let hooks = ToolsReleaseTransferHooks(afterChunkWrite: { wrote.fulfill(); cancel.cancel() }, afterCleanup: { cleaned.fulfill() })
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes, chunks: [Data(bytes.prefix(4)), Data(bytes.dropFirst(4))]))
        let client = client(hooks: hooks)
        let task = Task { try await client.download(release, directory: root) { progress.append($0, $1) } }
        cancel.install { task.cancel() }
        await fulfillment(of: [wrote], timeout: 2)
        task.cancel() // Also bounds a regression that never reaches the write hook.
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cleaned], timeout: 2)
        XCTAssertNil(progress.last(), "No progress may be delivered after cancellation admission closes")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    #if canImport(Darwin)
    func testTB05ProviderCallbacksQueuedAfterStopCannotRecreateOutput() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4, 5, 6])
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        let root = try releaseDirectory()
        let began = expectation(description: "provider waiting before headers")
        let late = expectation(description: "provider enqueued late headers/body after stopLoading")
        let cleaned = expectation(description: "file owner drained")
        let progress = ToolsReleaseProgress()
        let hooks = ToolsReleaseTransferHooks(afterCleanup: { cleaned.fulfill() })
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: Data(), began: { began.fulfill() },
            afterStopData: bytes, afterStopDelivery: { late.fulfill() }, stallBeforeHeaders: true))
        let client = client(hooks: hooks)
        let task = Task { try await client.download(release, directory: root) { progress.append($0, $1) } }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [late, cleaned], timeout: 2)
        XCTAssertNil(progress.last())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    #endif

    func testTBF04VerifiedBytesCannotBeReplacedBeforeFinalPublication() async throws {
        for atomic in [true, false] {
            let bytes = Data([0x50, 0x4b, 3, 4, 5, 6]), other = Data([0x50, 0x4b, 3, 4, 9, 9])
            let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
            let root = try releaseDirectory(), changed = expectation(description: "Replace verified A with B")
            let hooks = ToolsReleaseTransferHooks(afterCleanup: {
                do {
                    let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("update-") })
                    try other.write(to: folder.appendingPathComponent("fixture-arm64.ipa.partial"), options: atomic ? .atomic : [])
                } catch { XCTFail("Fixture replacement failed: \(error)") }
                changed.fulfill()
            })
            ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes))
            do { _ = try await boundedDownload(client(hooks: hooks), release: release, directory: root); XCTFail("A receipt for A must not publish B") }
            catch { XCTAssertTrue((error as? ToolsError) == .unsafePath || (error as? ToolsError) == .checksumMismatch) }
            await fulfillment(of: [changed], timeout: 2)
            let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("update-") })
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("fixture-arm64.ipa.partial")), other)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fixture-arm64.ipa").path))
        }
    }

    func testTBF04ForeignFolderIsNotRecursivelyCleanedOnSuccessHandoffOrError() async throws {
        for status in [200, 500] {
            let bytes = Data([0x50, 0x4b, 3, 4, 5, 6])
            let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
            let root = try releaseDirectory(), moved = root.appendingPathComponent("moved-owned")
            let changed = expectation(description: "Replace owned update directory")
            let hooks = ToolsReleaseTransferHooks(afterCleanup: {
                do {
                    let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("update-") })
                    try FileManager.default.moveItem(at: folder, to: moved)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    try Data([9]).write(to: folder.appendingPathComponent("foreign.bin"))
                } catch { XCTFail("Fixture folder replacement failed: \(error)") }
                changed.fulfill()
            })
            ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(status: status, data: bytes))
            do { _ = try await boundedDownload(client(hooks: hooks), release: release, directory: root); XCTFail("Expected rejection") }
            catch { }
            await fulfillment(of: [changed], timeout: 2)
            let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("update-") })
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("foreign.bin")), Data([9]))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, "The held owner still cleans its own partial")
        }
    }

    func testTBF04ReadyNameCollisionPreservesForeignBytesAndRemovesOurPartial() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4, 5, 6]), other = Data([9, 8, 7, 6, 5, 4])
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        let root = try releaseDirectory(), collided = expectation(description: "Foreign ready-name collision")
        let hooks = ToolsReleaseTransferHooks(afterCleanup: {
            do {
                let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
                try other.write(to: folder.appendingPathComponent("fixture-arm64.ipa"))
            } catch { XCTFail("Fixture collision failed: \(error)") }
            collided.fulfill()
        })
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes))
        do { _ = try await boundedDownload(client(hooks: hooks), release: release, directory: root); XCTFail("Expected exclusive publication failure") }
        catch { XCTAssertEqual(error as? ToolsError, .unavailable("The destination already exists.")) }
        await fulfillment(of: [collided], timeout: 2)
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["fixture-arm64.ipa"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("fixture-arm64.ipa")), other)
    }

    func testTBF04CancellationAtSuccessHandoffStillRemovesOwnedOutput() async throws {
        let bytes = Data([0x50, 0x4b, 3, 4, 5, 6])
        let release = try XCTUnwrap(ToolsReleaseClient.decodeReleases(response(asset: bytes), repository: repository, includePrereleases: false))
        let root = try releaseDirectory(), cancellation = ToolsReleaseCancellation()
        let handedOff = expectation(description: "Verified output handed to caller")
        let hooks = ToolsReleaseTransferHooks(afterCleanup: { cancellation.cancel(); handedOff.fulfill() })
        ToolsReleaseFixtureProtocol.set(release.asset.url, fixture: .init(data: bytes))
        do {
            _ = try await boundedDownload(client(hooks: hooks), release: release, directory: root, cancellation: cancellation)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [handedOff], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func boundedDownload(_ client: ToolsReleaseClient, release: ToolsGitHubRelease, directory: URL,
                                 cancellation: ToolsReleaseCancellation? = nil) async throws -> ToolsDownloadedUpdate {
        let completed = expectation(description: "Offline transfer completes within 3 seconds")
        let outcome = ToolsReleaseOutcome()
        let task = Task {
            do { outcome.store(.success(try await client.download(release, directory: directory) { _, _ in })) }
            catch { outcome.store(.failure(error)) }
            completed.fulfill()
        }
        cancellation?.install { task.cancel() }
        await fulfillment(of: [completed], timeout: 3)
        guard let result = outcome.read() else {
            task.cancel()
            throw ToolsError.unavailable("Offline transfer fixture exceeded its deadline.")
        }
        return try result.get()
    }

    private func releaseDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-release-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private final class ToolsReleaseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); self.action = action; let requested = requested; lock.unlock()
        if requested { action() }
    }
    func cancel() {
        lock.lock(); requested = true; let action = action; lock.unlock()
        action?()
    }
}

private final class ToolsReleaseProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int64, Int64)?
    func append(_ done: Int64, _ total: Int64) { lock.lock(); value = (done, total); lock.unlock() }
    func last() -> (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class ToolsReleaseOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<ToolsDownloadedUpdate, Error>?
    func store(_ value: Result<ToolsDownloadedUpdate, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> Result<ToolsDownloadedUpdate, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

/// URLProtocol itself explicitly disallows Sendable on FoundationNetworking.
/// Capture immutable callback inputs on its owning entry instead of reading its
/// mutable request/client properties from the intentional late-delivery queue.
private final class ToolsReleaseLateDelivery: @unchecked Sendable {
    private let source: URLProtocol
    private let client: (any URLProtocolClient)?
    private let response: HTTPURLResponse?
    private let data: Data
    private let completed: (@Sendable () -> Void)?

    init(source: URLProtocol, client: (any URLProtocolClient)?, url: URL?, data: Data,
         completed: (@Sendable () -> Void)?) {
        self.source = source
        self.client = client
        self.response = url.flatMap { HTTPURLResponse(url: $0, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"]) }
        self.data = data
        self.completed = completed
    }

    func deliver() {
        if let response { client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(source, didLoad: data)
        client?.urlProtocolDidFinishLoading(source)
        completed?()
    }
}

private final class ToolsReleaseFixtureProtocol: URLProtocol {
    struct Fixture: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var data: Data
        var stall = false
        var began: (@Sendable () -> Void)?
        var stopped: (@Sendable () -> Void)?
        var chunks: [Data]?
        var afterStopData: Data?
        var afterStopDelivery: (@Sendable () -> Void)?
        var stallBeforeHeaders = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: Fixture] = [:]
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    private var stopCallback: (@Sendable () -> Void)?
    private let instanceLock = NSLock()
    private var lateData: Data?
    private var lateDelivery: (@Sendable () -> Void)?

    static func set(_ url: URL, fixture: Fixture) { lock.lock(); fixtures[url] = fixture; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); fixtures = [:]; captured = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = request.url.flatMap { Self.fixtures[$0] }
        Self.captured.append(request)
        Self.lock.unlock()
        guard let fixture, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        instanceLock.lock()
        stopCallback = fixture.stopped
        lateData = fixture.afterStopData
        lateDelivery = fixture.afterStopDelivery
        instanceLock.unlock()
        fixture.began?()
        if fixture.stallBeforeHeaders { return }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.stall { return }
        for chunk in fixture.chunks ?? [fixture.data] { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        instanceLock.lock()
        let stopped = stopCallback, data = lateData, delivered = lateDelivery
        stopCallback = nil; lateData = nil; lateDelivery = nil
        instanceLock.unlock()
        let late = data.map { ToolsReleaseLateDelivery(source: self, client: client, url: request.url, data: $0, completed: delivered) }
        stopped?()
        if let late {
            DispatchQueue.global().async { late.deliver() }
        }
    }
}
