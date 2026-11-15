import Foundation
import XCTest
@testable import ExteralessCore

final class MapPolicyTests: XCTestCase {
    func testKnownCoordinatesAndExactlyOnceGoogleTransform() throws {
        let beijing = try XCTUnwrap(MapCoordinate(latitude: 39.908823, longitude: 116.397470))
        let corrected = MapCoordinatePolicy.googleDisplay(beijing)
        XCTAssertEqual(corrected.latitude, 39.91022649807321, accuracy: 0.00000001)
        XCTAssertEqual(corrected.longitude, 116.4037135824225, accuracy: 0.00000001)
        XCTAssertEqual(MapCoordinatePolicy.googleDisplay(corrected), corrected)
        let shanghai = MapCoordinatePolicy.googleDisplay(try XCTUnwrap(MapCoordinate(latitude: 31.2304, longitude: 121.4737)))
        XCTAssertEqual(shanghai.latitude, 31.22845773757727, accuracy: 0.00000001)
        XCTAssertEqual(shanghai.longitude, 121.47822305927693, accuracy: 0.00000001)
        let london = try XCTUnwrap(MapCoordinate(latitude: 51.5074, longitude: -0.1278))
        XCTAssertEqual(MapCoordinatePolicy.googleDisplay(london), london)
        XCTAssertEqual(MapPolicy(correctGoogleCoordinates: false).googleCoordinate(beijing), beijing)
        XCTAssertEqual(MapPolicy(useOpenStreetMap: true).googleCoordinate(beijing), beijing)
        XCTAssertNil(MapCoordinate(latitude: .nan, longitude: 0))
        XCTAssertNil(MapCoordinate(latitude: 0, longitude: .infinity))
        XCTAssertNil(MapCoordinate(latitude: 91, longitude: 0))
    }

    func testPreviewIDsDoNotOptSecretChatsOrProfilesIntoYandex() {
        let policy = MapPolicy(preview: .yandex, useOpenStreetMap: true)
        XCTAssertEqual(policy.preview(for: .cloudMessage), .yandex)
        XCTAssertEqual(policy.preview(for: .instantPage), .yandex)
        XCTAssertEqual(policy.preview(for: .secretChat), .native)
        XCTAssertEqual(policy.preview(for: .other), .native)
        XCTAssertEqual(MapPolicy(preview: .disabled).preview(for: .cloudMessage), .disabled)
        XCTAssertEqual(MapPolicy.Preview.native.rawValue, 0)
        XCTAssertEqual(MapPolicy.Preview.yandex.rawValue, 1)
        XCTAssertEqual(MapPolicy.Preview.disabled.rawValue, 2)
    }

    func testProviderURLCoordinatesBoundsAndCredentialEncoding() throws {
        let coordinate = try XCTUnwrap(MapCoordinate(latitude: 55.751244, longitude: 37.618423))
        let url = try XCTUnwrap(MapProviderURL.yandexPreview(coordinate: coordinate, width: 320, height: 180, language: "ru", apiKey: "a&key=b"))
        XCTAssertEqual(url.host, "static-maps.yandex.ru")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "ll" })?.value, "37.618423,55.751244")
        XCTAssertEqual(items.first(where: { $0.name == "apikey" })?.value, "a&key=b")
        XCTAssertEqual(items.first(where: { $0.name == "lang" })?.value, "ru_RU")
        XCTAssertNil(MapProviderURL.yandexPreview(coordinate: coordinate, width: 651, height: 180))
        XCTAssertNil(MapProviderURL.openStreetMapTile(x: -1, y: 0, zoom: 1))
        XCTAssertNil(MapProviderURL.openStreetMapTile(x: 0, y: 2, zoom: 1))
        XCTAssertNil(MapProviderURL.openStreetMapTile(x: 0, y: 0, zoom: 64))
        XCTAssertEqual(MapProviderURL.openStreetMapTile(x: 1, y: 0, zoom: 1)?.absoluteString, "https://tile.openstreetmap.org/1/1/0.png")
        XCTAssertEqual(MapProviderURL.openStreetMap(coordinate: coordinate)?.host, "www.openstreetmap.org")
    }

    func testCacheCoalescesWithinAccountAndCancelsStaleEpoch() {
        let cache = MapResourceCache()
        let callbacks = NetworkMapTestBox<[MapResourceCache.Completion]>([])
        let started = DispatchSemaphore(value: 0)
        let cancelled = NetworkMapTestBox(0)
        let start: @Sendable (@escaping MapResourceCache.Completion) -> NetworkResolverCancellation = { callback in
            callbacks.update { $0.append(callback) }; started.signal()
            return NetworkResolverCancellation { cancelled.update { $0 += 1 } }
        }
        let key = MapResourceCache.Key(namespace: "account:1", resource: "same-point")
        let retired = expectation(description: "cache retired")
        let a = cache.load(key: key, start: start) { _ in XCTFail("Cancelled subscriber called") }
        let b = cache.load(key: key, start: start) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .configurationChanged) } else { XCTFail("Retired snapshot delivered") }
            retired.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        a.cancel()
        cache.clear(namespace: "account:1")
        wait(for: [retired], timeout: 1)
        let fresh = expectation(description: "new account")
        let c = cache.load(key: .init(namespace: "account:2", resource: "same-point"), start: start) { result in
            XCTAssertEqual(try? result.get().data, Data([2])); fresh.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        callbacks.read()[0](.success(.init(data: Data([1]), ttl: 300)))
        callbacks.read()[1](.success(.init(data: Data([2]), ttl: 300)))
        wait(for: [fresh], timeout: 1)
        XCTAssertEqual(callbacks.read().count, 2)
        XCTAssertGreaterThanOrEqual(cancelled.read(), 1)
        b.cancel(); c.cancel(); cache.clear()
    }

    func testCacheExpiresAndCancelledLastWaiterCannotSeedCache() {
        let now = NetworkMapTestBox(0.0), starts = NetworkMapTestBox(0)
        let cache = MapResourceCache(now: { now.read() })
        let key = MapResourceCache.Key(namespace: "view:fixture", resource: "tile")
        let start: @Sendable (@escaping MapResourceCache.Completion) -> NetworkResolverCancellation = { callback in
            starts.update { $0 += 1 }; callback(.success(.init(data: Data([9]), ttl: 2))); return NetworkResolverCancellation()
        }
        for index in 0..<3 {
            if index == 2 { now.update { $0 = 3 } }
            let done = expectation(description: "value \(index)")
            let token = cache.load(key: key, start: start) { _ in done.fulfill() }
            wait(for: [done], timeout: 1); token.cancel()
        }
        XCTAssertEqual(starts.read(), 2)
        cache.clear()
    }
}
