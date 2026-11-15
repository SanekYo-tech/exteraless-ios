import ExteralessCore
import Foundation
import MtProtoKit
import XCTest
@testable import TelegramCore

@available(iOS 15.0, macOS 14.0, *)
final class ExteralessResolverConnectionTests: XCTestCase {
    private final class SystemFixture: NetworkResolverSystemLookup, @unchecked Sendable {
        func lookup(_ question: NetworkDNSQuestion, completion: @escaping @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
            let address = NetworkIPAddress(question.type == .a ? "192.0.2.7" : "2001:db8::7")!
            completion(.success(.init(records: [.init(name: question.name, ttl: 60, value: .address(address))], canonicalName: question.name, ttl: 60)))
            return NetworkResolverCancellation()
        }
    }
    private final class HTTPFixture: NetworkResolverHTTPTransport, @unchecked Sendable {
        func send(_ request: URLRequest, completion: @escaping @Sendable (Result<NetworkResolverHTTPResponse, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
            XCTFail("System fixture must not use HTTP"); completion(.failure(.transport)); return NetworkResolverCancellation()
        }
    }
    private final class Delegate: NSObject, MTTcpConnectionInterfaceDelegate {
        let connected: XCTestExpectation
        let written: XCTestExpectation
        init(connected: XCTestExpectation, written: XCTestExpectation) { self.connected = connected; self.written = written }
        func connectionInterfaceDidConnect() { connected.fulfill() }
        func connectionInterfaceDidDisconnectWithError(_ error: Error?) {}
        func connectionInterfaceDidReadPartialData(ofLength length: UInt, tag: Int) {}
        func connectionInterfaceDidRead(_ data: Data, withTag tag: Int, networkType: Int32) {}
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var hosts: [String] = []
        var written: [String: Data] = [:]
        var closed = Set<String>()
    }
    private final class Socket: NSObject, MTTcpConnectionInterface {
        weak var delegate: MTTcpConnectionInterfaceDelegate?
        let queue: DispatchQueue, state: State, writeExpectation: XCTestExpectation
        var host = ""
        init(delegate: MTTcpConnectionInterfaceDelegate, queue: DispatchQueue, state: State, writeExpectation: XCTestExpectation) {
            self.delegate = delegate; self.queue = queue; self.state = state; self.writeExpectation = writeExpectation
        }
        func setGetLogPrefix(_ prefix: (() -> String)?) {}
        func setUsageCalculationInfo(_ info: MTNetworkUsageCalculationInfo?) {}
        func connect(toHost host: String, onPort port: UInt16, viaInterface interface: String?, withTimeout timeout: TimeInterval, error: NSErrorPointer) -> Bool {
            self.host = host
            state.lock.lock(); state.hosts.append(host); state.lock.unlock()
            // First (IPv6) socket intentionally stays pending. IPv4 wins the
            // staggered race without a real DNS query, socket or account.
            if host == "192.0.2.7" { queue.async { [weak self] in self?.delegate?.connectionInterfaceDidConnect() } }
            return true
        }
        func write(_ data: Data) {
            state.lock.lock(); state.written[host, default: Data()].append(data); state.lock.unlock()
            writeExpectation.fulfill()
        }
        func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {}
        func disconnect() { state.lock.lock(); state.closed.insert(host); state.lock.unlock() }
        func resetDelegate() { delegate = nil }
    }

    func testIPv4WinsAfterIPv6StallWithoutReopeningOrWritingToLoser() throws {
        let resolver = NetworkResolver(configuration: try .init(mode: .system, preferIPv6: true), http: HTTPFixture(), system: SystemFixture())
        let connected = expectation(description: "winner connected"), written = expectation(description: "queued data sent once")
        let delegate = Delegate(connected: connected, written: written), state = State()
        defer { withExtendedLifetime(delegate) {} }
        let socket = ExteralessResolverTcpConnectionInterface(delegate: delegate, delegateQueue: .main, resolver: resolver, factory: { delegate, queue in
            Socket(delegate: delegate, queue: queue, state: state, writeExpectation: written)
        })
        var error: NSError?
        XCTAssertTrue(socket.connect(toHost: "fixture.example", onPort: 443, viaInterface: nil, withTimeout: 1, error: &error))
        socket.write(Data([1, 2, 3]))
        wait(for: [connected, written], timeout: 2)
        state.lock.lock()
        let hosts = state.hosts, writes = state.written, closed = state.closed
        state.lock.unlock()
        XCTAssertEqual(hosts, ["2001:db8:0:0:0:0:0:7", "192.0.2.7"])
        XCTAssertEqual(writes, ["192.0.2.7": Data([1, 2, 3])])
        XCTAssertTrue(closed.contains("2001:db8:0:0:0:0:0:7"))
        socket.resetDelegate(); socket.disconnect(); resolver.invalidate()
    }
}
