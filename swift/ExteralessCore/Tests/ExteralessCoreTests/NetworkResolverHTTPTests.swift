import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

/// Every URL is intercepted. No real provider, account, loopback listener or DNS
/// request is contacted. The mock belongs only to each fixture URLSession.
private final class NetworkMapURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case http(status: Int, mime: String, body: Data, length: Int?)
        case failure(URLError.Code)
        case pending
    }
    static let response = NetworkMapTestBox<Response>(.pending)
    static let starts = DispatchSemaphore(value: 0)
    static let stops = NetworkMapTestBox(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.signal()
        switch Self.response.read() {
        case let .http(status, mime, body, length):
            var headers = ["Content-Type": mime]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending: break
        }
    }
    override func stopLoading() { Self.stops.update { $0 += 1 } }
}

final class NetworkResolverHTTPTests: XCTestCase {
    func testHTTPStatusMimeAndUntrustedCertificateAreFailures() throws {
        let transport = NetworkResolverURLSessionTransport(protocolClasses: [NetworkMapURLProtocol.self])
        defer { transport.invalidate() }
        let request = try NetworkDoHRequest.make(endpoint: .init("https://resolver.invalid/query"), question: .init(name: "example.com", type: .a), id: 1, timeout: 1)
        let fixtures: [(NetworkMapURLProtocol.Response, NetworkResolverError)] = [
            (.http(status: 404, mime: "application/dns-message", body: Data(), length: nil), .httpStatus),
            (.http(status: 200, mime: "text/html", body: Data("not DNS".utf8), length: nil), .contentType),
            (.http(status: 200, mime: "application/dns-message", body: Data(), length: 65536), .responseTooLarge),
            (.failure(.serverCertificateUntrusted), .transport)
        ]
        for (fixture, error) in fixtures {
            NetworkMapURLProtocol.response.update { $0 = fixture }
            let done = expectation(description: error.rawValue)
            let token = transport.send(request) { result in
                if case let .failure(value) = result { XCTAssertEqual(value, error) } else { XCTFail("Invalid DoH HTTP response accepted") }
                done.fulfill()
            }
            wait(for: [done], timeout: 1); token.cancel()
        }
    }

    func testStreamingBoundWithoutContentLengthAndCancellation() throws {
        let transport = NetworkResolverURLSessionTransport(protocolClasses: [NetworkMapURLProtocol.self])
        defer { transport.invalidate() }
        let request = try NetworkDoHRequest.make(endpoint: .init("https://resolver.invalid/query"), question: .init(name: "example.com", type: .a), id: 1, timeout: 1)
        NetworkMapURLProtocol.response.update { $0 = .http(status: 200, mime: "application/dns-message", body: Data(repeating: 0, count: 65536), length: nil) }
        let bounded = expectation(description: "stream bound")
        let first = transport.send(request) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .responseTooLarge) } else { XCTFail("Oversized stream accepted") }
            bounded.fulfill()
        }
        wait(for: [bounded], timeout: 1); first.cancel()
        NetworkMapURLProtocol.response.update { $0 = .pending }
        let cancelled = expectation(description: "cancelled task")
        let second = transport.send(request) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) } else { XCTFail("Cancelled task succeeded") }
            cancelled.fulfill()
        }
        second.cancel(); wait(for: [cancelled], timeout: 1)
    }

    func testMapHTTPRejectsErrorPagesAndOversizedImages() throws {
        let transport = MapProviderHTTP(protocolClasses: [NetworkMapURLProtocol.self])
        defer { transport.invalidate() }
        for fixture in [NetworkMapURLProtocol.Response.http(status: 403, mime: "image/png", body: Data(), length: nil), .http(status: 200, mime: "text/html", body: Data("error".utf8), length: nil), .http(status: 200, mime: "image/png", body: Data(), length: 4 * 1024 * 1024 + 1)] {
            NetworkMapURLProtocol.response.update { $0 = fixture }
            let done = expectation(description: "map HTTP rejected")
            let token = transport.fetch(url: MapProviderURL.openStreetMapTile(x: 0, y: 0, zoom: 0)!) { result in
                if case .success = result { XCTFail("Invalid map HTTP body accepted") }
                done.fulfill()
            }
            wait(for: [done], timeout: 1); token.cancel()
        }
    }
}
