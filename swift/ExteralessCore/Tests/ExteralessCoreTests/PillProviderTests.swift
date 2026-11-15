import Foundation
import XCTest
@testable import ExteralessCore

final class PillTestTransport: PillHTTPTransport, @unchecked Sendable {
    struct Request { let url: URL; let callback: @Sendable (Result<PillHTTPResponse, PillError>) -> Void }
    let requests = PillTestBox<[Request]>([])
    let cancellations = PillTestBox(0)
    let started = DispatchSemaphore(value: 0)
    func get(_ url: URL, completion: @escaping @Sendable (Result<PillHTTPResponse, PillError>) -> Void) -> PillCancellation {
        requests.update { $0.append(Request(url: url, callback: completion)) }
        started.signal()
        return PillCancellation { [cancellations] in cancellations.update { $0 += 1 } }
    }
    func finish(_ index: Int, _ result: Result<PillHTTPResponse, PillError>) { requests.read()[index].callback(result) }
}

final class PillProviderTests: XCTestCase {
    func testPoolCoalescesWaitersButNotAccountsDomainsOrSelections() {
        let pool = PillRequestPool<Int>()
        let scope = PillAccountScope(accountId: 1)
        let key = PillRequestKey(scope: scope, domain: "rates", selection: "USD")
        let callbacks = PillTestBox<[PillRequestPool<Int>.Completion]>([])
        let cancelled = PillTestBox(0)
        let values = PillTestBox<[Int]>([])
        let start: @Sendable (@escaping PillRequestPool<Int>.Completion) -> PillCancellation = { callback in
            callbacks.update { $0.append(callback) }
            return PillCancellation { cancelled.update { $0 += 1 } }
        }
        let a = pool.request(key: key, start: start) { result in if case let .success(value) = result { values.update { $0.append(value) } } }
        let b = pool.request(key: key, start: start) { result in if case let .success(value) = result { values.update { $0.append(value) } } }
        XCTAssertEqual(callbacks.read().count, 1)
        a.cancel(); XCTAssertEqual(cancelled.read(), 0)
        callbacks.read()[0](.success(7))
        XCTAssertEqual(values.read(), [7])
        let c = pool.request(key: .init(scope: scope, domain: "gold", selection: "USD"), start: start) { _ in }
        let d = pool.request(key: .init(scope: PillAccountScope(accountId: 1), domain: "rates", selection: "USD"), start: start) { _ in }
        let e = pool.request(key: .init(scope: scope, domain: "rates", selection: "EUR"), start: start) { _ in }
        XCTAssertEqual(callbacks.read().count, 4)
        b.cancel(); c.cancel(); d.cancel(); e.cancel()
    }

    func testPoolCancellationCannotCompleteReplacementFlight() {
        let pool = PillRequestPool<Int>()
        let key = PillRequestKey(scope: .init(accountId: 3), domain: "weather", selection: "telegram:1,2")
        let callbacks = PillTestBox<[PillRequestPool<Int>.Completion]>([])
        let values = PillTestBox<[Int]>([])
        let start: @Sendable (@escaping PillRequestPool<Int>.Completion) -> PillCancellation = { callback in callbacks.update { $0.append(callback) }; return PillCancellation() }
        let a = pool.request(key: key, start: start) { _ in XCTFail("Cancelled waiter received a callback") }
        a.cancel()
        let b = pool.request(key: key, start: start) { result in if case let .success(value) = result { values.update { $0.append(value) } } }
        callbacks.read()[0](.success(1)); callbacks.read()[1](.success(2))
        XCTAssertEqual(values.read(), [2])
        b.cancel()
        let synchronous = pool.request(key: key, start: { callback in callback(.success(3)); return PillCancellation() }) { result in if case let .success(value) = result { values.update { $0.append(value) } } }
        XCTAssertEqual(values.read(), [2, 3]); synchronous.cancel()
    }

    func testTwoPairsShareOneRequestAndCacheCommitsTimestampAtomically() throws {
        let settings = try pillSettings()
        let transport = PillTestTransport()
        let date = Date(timeIntervalSince1970: 10_000)
        let http = PillHTTPClient(transport: transport, now: { date })
        let lease = PillAccountLease(scope: .init(accountId: 9))
        let provider = PillRateProvider(lease: lease, settings: settings, http: http, now: { date })
        let ready = expectation(description: "two ready values"); ready.expectedFulfillmentCount = 2
        let output = PillTestBox<[String: PillRateQuote]>([:])
        let first = provider.read(pair: .init(base: "BTC", target: "USD"), phoneCountry: nil) { value in
            if !value.isLoading { if let quote = value.quote { output.update { $0["USD"] = quote } }; ready.fulfill() }
        }
        let second = provider.read(pair: .init(base: "BTC", target: "EUR"), phoneCountry: nil) { value in
            if !value.isLoading { if let quote = value.quote { output.update { $0["EUR"] = quote } }; ready.fulfill() }
        }
        defer { first.cancel(); second.cancel(); lease.invalidate(); provider.cancel() }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)
        let snapshots = PillTestBox<[[String: ClientSettingValue]]>([])
        let observation = settings.observe { keys in if keys.contains("chats.ratesCache") { snapshots.update { $0.append(settings.snapshot()) } } }
        defer { observation.cancel() }
        transport.finish(0, .success(.init(status: 200, data: Data(#"{"data":{"currency":"USD","rates":{"BTC":"0.00002","EUR":"0.8"}}}"#.utf8))))
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(transport.requests.read().count, 1)
        XCTAssertEqual(output.read()["USD"]?.value, 50_000)
        XCTAssertEqual(output.read()["EUR"]?.value, 40_000)
        XCTAssertEqual(snapshots.read().count, 1)
        XCTAssertEqual(snapshots.read().first?["chats.ratesCacheTime"], .integer(10_000_000))
        XCTAssertEqual(http.statistics(domain: "rates").requests, 1)
        XCTAssertNil(http.statistics(domain: "rates").remaining)
    }

    func testNetworkFailureKeepsStaleValueAndOriginalObservationTime() throws {
        let settings = try pillSettings()
        let old = Date(timeIntervalSince1970: 10_000)
        let table = try PillRateTable(usdPerUnit: ["USD": 1, "BTC": 50_000], updatedAt: old)
        try settings.applyPublic(["chats.ratesCache": .string(table.serialized), "chats.ratesCacheTime": .integer(10_000_000)])
        let transport = PillTestTransport()
        let provider = PillRateProvider(lease: .init(scope: .init(accountId: 1)), settings: settings, http: PillHTTPClient(transport: transport), now: { old.addingTimeInterval(1000) })
        let finished = expectation(description: "stale fallback")
        let observed = PillTestBox<PillRateUpdate?>(nil)
        let token = provider.read(pair: .init(base: "BTC", target: "USD"), phoneCountry: nil) { value in if !value.isLoading { observed.update { $0 = value }; finished.fulfill() } }
        defer { token.cancel(); provider.cancel() }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)
        transport.finish(0, .failure(.network))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(observed.read()?.quote?.value, 50_000)
        XCTAssertEqual(observed.read()?.quote?.updatedAt, old)
        XCTAssertEqual(observed.read()?.error, .network)
        XCTAssertEqual(settings.integer("chats.ratesCacheTime"), 10_000_000)
    }

    func testAccountGenerationInvalidationBlocksLateCacheWrites() throws {
        let settings = try pillSettings()
        let transport = PillTestTransport()
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let provider = PillRateProvider(lease: lease, settings: settings, http: PillHTTPClient(transport: transport))
        let late = expectation(description: "no late final update"); late.isInverted = true
        let token = provider.read(pair: .init(base: "BTC", target: "USD"), phoneCountry: nil) { value in if !value.isLoading { late.fulfill() } }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)
        lease.invalidate(); provider.cancel(); token.cancel()
        transport.finish(0, .success(.init(status: 200, data: Data(#"{"data":{"currency":"USD","rates":{"BTC":"0.00002"}}}"#.utf8))))
        wait(for: [late], timeout: 0.05)
        XCTAssertEqual(settings.string("chats.ratesCache"), "")
        XCTAssertThrowsError(try lease.withCurrent { XCTFail("Retired generation admitted a write") })
    }

    func testGoldConversionUsesTroyOunceAndOlderOfBothTimestamps() throws {
        let settings = try pillSettings()
        let old = Date(timeIntervalSince1970: 1000)
        let table = try PillRateTable(usdPerUnit: ["USD": 1, "EUR": 1.25], updatedAt: old)
        try settings.applyPublic(["chats.ratesCache": .string(table.serialized), "chats.ratesCacheTime": .integer(1_000_000), "chats.goldPriceCache": .string("2500"), "chats.goldPriceCacheTime": .integer(1_010_000)])
        let transport = PillTestTransport()
        let provider = PillRateProvider(lease: .init(scope: .init(accountId: 4)), settings: settings, http: PillHTTPClient(transport: transport), now: { old.addingTimeInterval(20) })
        let done = expectation(description: "cached gold")
        let token = provider.read(pair: .init(base: "GOLD", target: "EUR"), phoneCountry: nil) { value in
            if !value.isLoading {
                XCTAssertEqual(value.quote?.value, 2000); XCTAssertEqual(value.quote?.updatedAt, old)
                XCTAssertTrue(value.quote?.source.contains("troy oz") == true); done.fulfill()
            }
        }
        wait(for: [done], timeout: 1); token.cancel()
        XCTAssertTrue(transport.requests.read().isEmpty)
    }

    func testHTTPQuotaIsObservedAndRepeatedRefreshIsBounded() {
        let transport = PillTestTransport()
        let now = Date(timeIntervalSince1970: 1000)
        let http = PillHTTPClient(transport: transport, now: { now })
        let first = http.get(PillEndpoints.coinbase, domain: "rates") { result in
            XCTAssertThrowsError(try result.get().validate(now: now))
        }
        transport.finish(0, .success(.init(status: 429, headers: ["Retry-After": "30", "X-RateLimit-Remaining": "0"], data: Data())))
        let second = http.get(PillEndpoints.coinbase, domain: "rates") { result in
            XCTAssertNil(try? result.get())
            if case let .failure(error) = result { XCTAssertEqual(error, .rateLimited(retryAt: now.addingTimeInterval(30))) }
        }
        XCTAssertEqual(http.statistics(domain: "rates").remaining, 0)
        XCTAssertEqual(http.statistics(domain: "rates").requests, 1)
        XCTAssertEqual(transport.requests.read().count, 1)
        first.cancel(); second.cancel()
        let localFirst = http.get(PillEndpoints.gold, domain: "gold") { _ in }
        let localSecond = http.get(PillEndpoints.gold, domain: "gold") { result in
            guard case let .failure(error) = result else { XCTFail("Repeated manual request escaped the local bound"); return }
            XCTAssertEqual(error, .throttled(retryAt: now.addingTimeInterval(5)))
        }
        XCTAssertNil(http.statistics(domain: "gold").remaining, "Local throttling is not an invented source quota")
        XCTAssertEqual(http.statistics(domain: "gold").requests, 1)
        localFirst.cancel(); localSecond.cancel()
    }
}
