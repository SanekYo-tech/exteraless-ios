import Foundation
import XCTest
@testable import ExteralessCore

final class AIBingCacheTests: XCTestCase, @unchecked Sendable {
    func testPersistedSessionExpiresAndRefreshUsesServerTTL() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let clock = AIBingFixtureClock(1001)
        let first = #"IG:"fixture-ig";data-iid="fixture-iid";params_AbusePreventionHelper=[1000,"fixture-token",100];"#
        let second = #"IG:"new-ig";data-iid="new-iid";params_AbusePreventionHelper=[1200,"new-token",100];"#
        let transport = AIScriptedTransport([.init(body: first), .init(body: second)])
        let cache = AIBingSessionCache(transport: transport, store: fixture.settings.store, now: { clock.now })
        let a = try await cache.lease()
        let b = try await cache.lease()
        XCTAssertEqual(a.session, b.session)
        XCTAssertEqual(b.sequence, 2)
        XCTAssertEqual(transport.requests.count, 1)
        let recreated = AIBingSessionCache(transport: transport, store: fixture.settings.store, now: { clock.now })
        let persisted = try await recreated.lease()
        XCTAssertEqual(persisted.session.tokenTs, 1000)
        XCTAssertEqual(transport.requests.count, 1)
        clock.now = 1201
        let refreshed = try await recreated.lease()
        XCTAssertEqual(refreshed.session.tokenTs, 1200)
        XCTAssertEqual(transport.requests.count, 2)
        let export = String(decoding: try fixture.settings.store.exportJSON(), as: UTF8.self)
        XCTAssertFalse(export.contains("fixture-token"))
        XCTAssertFalse(export.contains("new-token"))
        XCTAssertFalse(try String(contentsOf: fixture.url, encoding: .utf8).contains("fixture-token"))
    }

    func testCancelledWaiterDoesNotCancelOtherWaiterAndLastWaiterClosesTransport() async throws {
        let fixture = try AISettingsFixture()
        defer { fixture.remove() }
        let transport = AIBingSuspendedTransport()
        let cache = AIBingSessionCache(transport: transport, store: fixture.settings.store, now: { 1001 })
        let one = Task { try await cache.lease() }
        let two = Task { try await cache.lease() }
        try await Task.sleep(nanoseconds: 20_000_000)
        one.cancel()
        do { _ = try await one.value; XCTFail("Cancelled waiter returned success") } catch { XCTAssertEqual(AIError.sanitized(error), .cancelled) }
        transport.complete(#"IG:"ig";data-iid="iid";params_AbusePreventionHelper=[1000,"fixture-token",100];"#)
        let result = try await two.value
        XCTAssertEqual(result.session.tokenTs, 1000)
        let otherTransport = AIBingSuspendedTransport()
        let other = AIBingSessionCache(transport: otherTransport, store: fixture.settings.store, now: { 5000 })
        let last = Task { try await other.lease() }
        try await Task.sleep(nanoseconds: 20_000_000)
        last.cancel()
        do { _ = try await last.value; XCTFail("Cancellation returned success") } catch { XCTAssertEqual(AIError.sanitized(error), .cancelled) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(otherTransport.cancelled)
    }
}

private final class AIBingFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class AIBingSuspendedTransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AIHTTPEvent, Error>.Continuation?
    private var terminated = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return terminated }
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.terminated = true; self.lock.unlock()
            }
            // A fixture failure cannot leave the suite waiting for a network timeout.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continuation.finish(throwing: AIError.timeout)
            }
        }
    }
    func complete(_ body: String) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.yield(.response(status: 200, headers: [:]))
        continuation?.yield(.data(Data(body.utf8)))
        continuation?.finish()
    }
}
