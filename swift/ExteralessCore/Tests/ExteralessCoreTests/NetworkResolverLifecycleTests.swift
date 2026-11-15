import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class NetworkMapTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

private final class NetworkSystemFixture: NetworkResolverSystemLookup, @unchecked Sendable {
    typealias Callback = @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void
    let calls = NetworkMapTestBox<[(NetworkDNSQuestion, Callback)]>([])
    let cancellations = NetworkMapTestBox(0)
    let started = DispatchSemaphore(value: 0)
    func lookup(_ question: NetworkDNSQuestion, completion: @escaping Callback) -> NetworkResolverCancellation {
        calls.update { $0.append((question, completion)) }; started.signal()
        return NetworkResolverCancellation { [cancellations] in cancellations.update { $0 += 1 } }
    }
    func finish(_ index: Int, ttl: TimeInterval = 60, value: String = "203.0.113.7") {
        let call = calls.read()[index]
        call.1(.success(.init(records: [.init(name: call.0.name, ttl: UInt32(ttl), value: .address(NetworkIPAddress(value)!))], canonicalName: call.0.name, ttl: ttl)))
    }
}

private final class NetworkHTTPFixture: NetworkResolverHTTPTransport, @unchecked Sendable {
    let calls = NetworkMapTestBox(0)
    var failImmediately = true
    func send(_ request: URLRequest, completion: @escaping @Sendable (Result<NetworkResolverHTTPResponse, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        calls.update { $0 += 1 }
        if failImmediately { completion(.failure(.httpStatus)) }
        return NetworkResolverCancellation()
    }
}

final class NetworkResolverLifecycleTests: XCTestCase {
    func testRejectedInitialCustomConfigurationDoesNotFallBackToPublicDNS() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture()
        let resolver = NetworkResolver(configuration: try .init(mode: .telegram), http: http, system: system)
        resolver.rejectConfiguration(.invalidEndpoint)
        let rejected = expectation(description: "configuration failure")
        let first = resolver.lookup(try .init(name: "startup.example", type: .a)) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .invalidEndpoint) } else { XCTFail("Invalid configuration resolved a name") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        XCTAssertEqual(resolver.state().blockedConfiguration, .invalidEndpoint)
        XCTAssertEqual(system.calls.read().count, 0)
        XCTAssertEqual(http.calls.read(), 0)
        resolver.update(configuration: try .init(mode: .system), route: .unknown)
        XCTAssertNil(resolver.state().blockedConfiguration)
        let recovered = expectation(description: "explicit valid configuration")
        let second = resolver.lookup(try .init(name: "startup.example", type: .a)) { _ in recovered.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(0); wait(for: [recovered], timeout: 1)
        first.cancel(); second.cancel(); resolver.invalidate()
    }

    func testFamilyJoinCannotReturnHalfOfAnOldConfiguration() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture()
        let delivery = DispatchQueue(label: "Fixture.DNSDelivery")
        let resolver = NetworkResolver(configuration: try .init(mode: .system), http: http, system: system, deliveryQueue: delivery)
        let done = expectation(description: "joined epoch rejected")
        let token = resolver.resolve(host: "family.example") { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .configurationChanged) } else { XCTFail("Old IPv4 data escaped through the new IPv6 epoch") }
            done.fulfill()
        }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(0)
        _ = resolver.state()
        delivery.sync {}
        // An uncached opposite family cannot inherit a positive family's TTL.
        XCTAssertEqual(resolver.remainingTTL(host: "family.example"), 0)
        resolver.update(configuration: try .init(mode: .system, preferIPv6: true), route: .unknown)
        system.finish(1, value: "2001:db8::7")
        wait(for: [done], timeout: 1)
        token.cancel(); resolver.invalidate()
    }

    func testCoalescingCancellationAndTTLActuallyControlLookup() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture(), clock = NetworkMapTestBox(10.0)
        let resolver = NetworkResolver(configuration: try .init(mode: .system), http: http, system: system, now: { clock.read() })
        let question = try NetworkDNSQuestion(name: "cache.example", type: .a)
        let completed = expectation(description: "remaining waiter")
        let cancelled = resolver.lookup(question) { _ in XCTFail("Cancelled subscriber was called") }
        let live = resolver.lookup(question) { result in XCTAssertEqual(try? result.get().addresses.first?.string, "203.0.113.7"); completed.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        cancelled.cancel()
        XCTAssertEqual(resolver.state().inFlightQuestions, 1)
        system.finish(0, ttl: 2)
        wait(for: [completed], timeout: 1)
        let cached = expectation(description: "cache hit")
        let second = resolver.lookup(question) { _ in cached.fulfill() }
        wait(for: [cached], timeout: 1)
        XCTAssertEqual(system.calls.read().count, 1)
        clock.update { $0 += 3 }
        let refreshed = expectation(description: "expired value")
        let third = resolver.lookup(question) { _ in refreshed.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(1)
        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(system.calls.read().count, 2)
        XCTAssertEqual(http.calls.read(), 0)
        live.cancel(); second.cancel(); third.cancel(); resolver.invalidate()
    }

    func testConfigurationEpochRejectsLateNativeAnswer() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture()
        let resolver = NetworkResolver(configuration: try .init(mode: .system), http: http, system: system)
        let question = try NetworkDNSQuestion(name: "epoch.example", type: .a)
        let retired = expectation(description: "retired epoch")
        let first = resolver.lookup(question) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .configurationChanged) } else { XCTFail("Retired answer accepted") }
            retired.fulfill()
        }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        resolver.update(configuration: try .init(mode: .system, preferIPv6: true), route: .unknown)
        system.finish(0)
        wait(for: [retired], timeout: 1)
        XCTAssertEqual(resolver.state().cachedQuestions, 0)
        let fresh = expectation(description: "new epoch")
        let second = resolver.lookup(question) { result in XCTAssertEqual(try? result.get().addresses.first?.string, "192.0.2.9"); fresh.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(0) // duplicate old callback cannot satisfy a replacement flight
        system.finish(1, value: "192.0.2.9")
        wait(for: [fresh], timeout: 1)
        first.cancel(); second.cancel(); resolver.invalidate()
    }

    func testDoHFailureFallsBackAndLocalNamesNeverLeaveNativeDNS() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture()
        let resolver = NetworkResolver(configuration: try .init(mode: .customDoH, customDoH: "https://resolver.invalid/query"), http: http, system: system, timeout: 0.5)
        let done = expectation(description: "native fallback")
        let request = resolver.lookup(try .init(name: "fallback.example", type: .a)) { _ in done.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(0); wait(for: [done], timeout: 1)
        XCTAssertEqual(http.calls.read(), 1)
        let local = expectation(description: "mDNS stays local")
        let localRequest = resolver.lookup(try .init(name: "printer.local", type: .a)) { _ in local.fulfill() }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        system.finish(1); wait(for: [local], timeout: 1)
        XCTAssertEqual(http.calls.read(), 1)
        request.cancel(); localRequest.cancel(); resolver.invalidate()
    }

    func testTimeoutErrorCacheAndLastWaiterCancellation() throws {
        let system = NetworkSystemFixture(), http = NetworkHTTPFixture(), clock = NetworkMapTestBox(0.0)
        let resolver = NetworkResolver(configuration: try .init(mode: .system), http: http, system: system, timeout: 0.08, now: { clock.read() })
        let question = try NetworkDNSQuestion(name: "timeout.example", type: .a)
        let timeout = expectation(description: "bounded timeout")
        let first = resolver.lookup(question) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .timeout) } else { XCTFail("Missing timeout") }
            timeout.fulfill()
        }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        wait(for: [timeout], timeout: 1)
        let cached = expectation(description: "cached failure")
        let second = resolver.lookup(question) { _ in cached.fulfill() }
        wait(for: [cached], timeout: 1)
        XCTAssertEqual(system.calls.read().count, 1)
        clock.update { $0 = 3 }
        let cancelled = resolver.lookup(question) { _ in XCTFail("Last cancelled waiter was completed") }
        XCTAssertEqual(system.started.wait(timeout: .now() + 1), .success)
        cancelled.cancel()
        XCTAssertEqual(resolver.state().inFlightQuestions, 0)
        system.finish(1)
        XCTAssertEqual(resolver.state().cachedQuestions, 0)
        first.cancel(); second.cancel(); resolver.invalidate()
    }
}
