import Foundation
import XCTest
@testable import ExteralessCore

final class PillWeatherProviderTests: XCTestCase {
    func testWeatherSourceAndCoordinatesAreCapturedAndNativeRequestsCoalesce() throws {
        let transport = PillTestTransport()
        let lease = PillAccountLease(scope: .init(accountId: 12))
        let coordinates = PillTestBox<[PillCoordinate]>([])
        let replies = PillTestBox<[@Sendable (Result<PillWeatherReading, PillError>) -> Void]>([])
        let started = DispatchSemaphore(value: 0)
        let provider = PillWeatherProvider(lease: lease, http: PillHTTPClient(transport: transport), nativeFetch: { coordinate, reply in
            coordinates.update { $0.append(coordinate) }; replies.update { $0.append(reply) }; started.signal()
            return PillCancellation()
        })
        let point = try PillCoordinate(latitude: 12, longitude: -34)
        let ready = expectation(description: "native readers"); ready.expectedFulfillmentCount = 2
        let a = provider.read(coordinate: point, source: .telegram) { value in
            if !value.isLoading { XCTAssertEqual(value.reading?.source, .telegram); XCTAssertEqual(value.reading?.coordinate, point); ready.fulfill() }
        }
        let b = provider.read(coordinate: point, source: .telegram) { value in
            if !value.isLoading { XCTAssertEqual(value.reading?.temperatureCelsius, 18); ready.fulfill() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        replies.read()[0](.success(try .init(coordinate: point, celsius: 18, emoji: "☀", updatedAt: Date(), source: .telegram)))
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(coordinates.read(), [point])
        let httpReady = expectation(description: "independent HTTP source")
        let c = provider.read(coordinate: point, source: .openMeteo) { value in
            if !value.isLoading { XCTAssertEqual(value.reading?.source, .openMeteo); XCTAssertEqual(value.reading?.temperatureCelsius, 21); httpReady.fulfill() }
        }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)
        let url = transport.requests.read()[0].url
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "latitude" }?.value, "12.0")
        transport.finish(0, .success(.init(status: 200, data: Data(#"{"current_weather":{"temperature":21,"weathercode":0},"current_weather_units":{"temperature":"°C"}}"#.utf8))))
        wait(for: [httpReady], timeout: 2)
        a.cancel(); b.cancel(); c.cancel(); lease.invalidate(); provider.cancel()
    }

    func testWeatherFailureRetainsItsOriginalTimestampAndDoesNotCrossCoordinates() throws {
        let lease = PillAccountLease(scope: .init(accountId: 13))
        let clock = PillTestBox(Date(timeIntervalSince1970: 1000))
        let fail = PillTestBox(false)
        let provider = PillWeatherProvider(lease: lease, http: PillHTTPClient(transport: PillTestTransport()), nativeFetch: { point, callback in
            if fail.read() { callback(.failure(.network)) }
            else { callback(.success(try! .init(coordinate: point, celsius: 18, emoji: "☀", updatedAt: clock.read(), source: .telegram))) }
            return PillCancellation()
        }, now: { clock.read() })
        let point = try PillCoordinate(latitude: 12, longitude: 34)
        let first = expectation(description: "cache populated")
        let a = provider.read(coordinate: point, source: .telegram) { value in if !value.isLoading { first.fulfill() } }
        wait(for: [first], timeout: 1)
        fail.update { $0 = true }; clock.update { $0 = $0.addingTimeInterval(901) }
        let second = expectation(description: "stale retained")
        let b = provider.read(coordinate: point, source: .telegram) { value in
            if !value.isLoading { XCTAssertEqual(value.reading?.updatedAt, Date(timeIntervalSince1970: 1000)); XCTAssertEqual(value.error, .network); second.fulfill() }
        }
        wait(for: [second], timeout: 1)
        let third = expectation(description: "new location has no old reading")
        let c = provider.read(coordinate: try PillCoordinate(latitude: 56, longitude: 78), source: .telegram) { value in
            XCTAssertNil(value.reading)
            if !value.isLoading { third.fulfill() }
        }
        wait(for: [third], timeout: 1)
        a.cancel(); b.cancel(); c.cancel(); lease.invalidate(); provider.cancel()
    }
}
