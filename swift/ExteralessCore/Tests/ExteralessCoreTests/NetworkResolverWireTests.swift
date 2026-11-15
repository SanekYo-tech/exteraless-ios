import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ExteralessCore

final class NetworkResolverWireTests: XCTestCase {
    func testIndependentAAndAAAAWireFixtures() throws {
        let a = try NetworkDNSQuestion(name: "EXAMPLE.com.", type: .a)
        let packet = networkMapHex("123481800001000100000000076578616d706c6503636f6d0000010001c00c000100010000003c0004cb007107")
        let answer = try NetworkDNSWire.response(packet, question: a, id: 0x1234)
        XCTAssertEqual(answer.addresses.map(\.string), ["203.0.113.7"])
        XCTAssertEqual(answer.ttl, 60)
        let aaaa = try NetworkDNSQuestion(name: "example.com", type: .aaaa)
        let v6 = networkMapHex("123481800001000100000000076578616d706c6503636f6d00001c0001c00c001c000100000078001020010db8000000000000000000000007")
        XCTAssertEqual(try NetworkDNSWire.response(v6, question: aaaa, id: 0x1234).addresses, [NetworkIPAddress("2001:db8::7")!])
        XCTAssertThrowsError(try NetworkDNSWire.response(packet, question: aaaa, id: 0x1234))
        XCTAssertThrowsError(try NetworkDNSWire.response(packet, question: a, id: 0x1235))
    }

    func testCNAMEChainUsesMinimumTTLAndRejectsLoop() throws {
        let question = try NetworkDNSQuestion(name: "alias.example.com", type: .a)
        let chain = networkMapHex("12348180000100020000000005616c696173076578616d706c6503636f6d0000010001c00c000500010000000a0002c012c012000100010000003c0004cb007107")
        let answer = try NetworkDNSWire.response(chain, question: question, id: 0x1234)
        XCTAssertEqual(answer.ttl, 10)
        XCTAssertEqual(answer.canonicalName, "example.com")
        let loop = networkMapHex("123481800001000100000000076578616d706c6503636f6d0000010001c00c000500010000003c0002c00c")
        XCTAssertThrowsError(try NetworkDNSWire.response(loop, question: .init(name: "example.com", type: .a), id: 0x1234)) { XCTAssertEqual($0 as? NetworkResolverError, .cnameLoop) }
    }

    func testDNSNegativeSOATTLAndAdditionalPoisoning() throws {
        let question = try NetworkDNSQuestion(name: "example.com", type: .a)
        let nxdomain = networkMapHex("123481830001000000010000076578616d706c6503636f6d0000010001c00c000600010000003c0018c00cc00c0000000100000002000000030000000400000005")
        let answer = try NetworkDNSWire.response(nxdomain, question: question, id: 0x1234)
        XCTAssertEqual(answer.negative, .nameNotFound); XCTAssertEqual(answer.ttl, 5)
        let additional = networkMapHex("123481800001000000000001076578616d706c6503636f6d0000010001c00c000100010000003c0004cb007107")
        let ignored = try NetworkDNSWire.response(additional, question: question, id: 0x1234)
        XCTAssertTrue(ignored.addresses.isEmpty); XCTAssertEqual(ignored.ttl, 0)
    }

    func testCompressionEDNSAndHeaderBounds() throws {
        let question = try NetworkDNSQuestion(name: "example.com", type: .a)
        let good = networkMapHex("123481800001000100000000076578616d706c6503636f6d0000010001c00c000100010000003c0004cb007107")
        for length in 0..<good.count { XCTAssertThrowsError(try NetworkDNSWire.response(good.prefix(length), question: question, id: 0x1234)) }
        for byte: UInt8 in [0x01, 0x83, 0x89] { // no QR, TC, non-query opcode
            var value = good; value[2] = byte
            XCTAssertThrowsError(try NetworkDNSWire.response(value, question: question, id: 0x1234))
        }
        var selfPointer = good; selfPointer[30] = 29
        XCTAssertThrowsError(try NetworkDNSWire.response(selfPointer, question: question, id: 0x1234))
        var edns = good; edns[11] = 1
        edns.append(networkMapHex("00002904d0000000000003000000"))
        XCTAssertThrowsError(try NetworkDNSWire.response(edns, question: question, id: 0x1234))
        var badVersion = good; badVersion[11] = 1; badVersion.append(networkMapHex("00002904d0000100000000"))
        XCTAssertThrowsError(try NetworkDNSWire.response(badVersion, question: question, id: 0x1234))
        XCTAssertThrowsError(try NetworkDNSWire.response(Data(repeating: 0, count: 65536), question: question, id: 0))
        let query = NetworkDNSWire.query(question, id: 0xbeef)
        XCTAssertEqual(Array(query.prefix(4)), [0xbe, 0xef, 1, 0])
        XCTAssertEqual(query.suffix(11), networkMapHex("00002904d0000000000000"))
    }

    func testJSONSchemaTXTAndHTTPAge() throws {
        let question = try NetworkDNSQuestion(name: "example.com", type: .txt)
        let data = Data(#"{"Status":0,"TC":false,"Question":[{"name":"example.com.","type":16}],"Answer":[{"name":"example.com.","type":16,"TTL":60,"data":"\"ab\\034c\" \"def\""}]}"#.utf8)
        let answer = try NetworkDNSJSON.response(data, question: question)
        XCTAssertEqual(answer.texts, [Data("ab\"cdef".utf8)])
        XCTAssertThrowsError(try NetworkDNSJSON.response(data, question: .init(name: "other.example", type: .txt)))
        let endpoint = try NetworkDoHEndpoint("https://dns.google/resolve?token=private")
        let aged = try NetworkDoHRequest.decode(.init(data: data, age: 10, maximumTTL: 25), endpoint: endpoint, question: question, id: 42)
        XCTAssertEqual(aged.ttl, 15)
        XCTAssertThrowsError(try NetworkDNSJSON.textParts("\"unterminated"))
        XCTAssertThrowsError(try NetworkDNSJSON.textParts("\"\\999\""))
    }

    func testDoHMethodsSchemesTemplatesAndQueryPreservation() throws {
        let question = try NetworkDNSQuestion(name: "example.com", type: .a)
        let post = try NetworkDoHRequest.make(endpoint: NetworkDoHEndpoint("https://resolver.invalid/custom/path?token=secret"), question: question, id: 123, timeout: 3)
        XCTAssertEqual(post.httpMethod, "POST"); XCTAssertNotNil(post.httpBody)
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/dns-message")
        XCTAssertNil(post.value(forHTTPHeaderField: "Host"))
        let get = try NetworkDoHRequest.make(endpoint: NetworkDoHEndpoint("https://resolver.invalid/custom/path?token=secret{&dns}"), question: question, id: 123, timeout: 3)
        XCTAssertEqual(get.httpMethod, "GET"); XCTAssertNil(get.httpBody)
        let items = URLComponents(url: get.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "token" })?.value, "secret")
        XCTAssertFalse(items.first(where: { $0.name == "dns" })!.value!.contains("="))
        let signed = try NetworkDoHRequest.make(endpoint: NetworkDoHEndpoint("https://resolver.invalid/query?token=a%2Bb%2Fc{&dns}"), question: question, id: 123, timeout: 3)
        XCTAssertTrue(signed.url!.absoluteString.contains("token=a%2Bb%2Fc&dns="))
        let json = try NetworkDoHRequest.make(endpoint: NetworkDoHEndpoint("https://dns.google/resolve"), question: question, id: 123, timeout: 3)
        XCTAssertEqual(json.value(forHTTPHeaderField: "Accept"), "application/dns-json")
        XCTAssertEqual(json.httpMethod, "GET")
        for url in ["http://resolver.invalid/dns-query", "tls://resolver.invalid", "https://u:p@resolver.invalid/dns-query", "https://resolver.invalid/q#fragment", "https://resolver.invalid/q?dns=stale", "https://resolver.invalid:0/q", "https://resolver.invalid/{bogus}"] {
            XCTAssertThrowsError(try NetworkDoHEndpoint(url), url)
        }
        XCTAssertEqual(try NetworkResolverConfiguration(mode: .customDoH).endpoints.count, 6)
        XCTAssertTrue(try NetworkResolverConfiguration(mode: .customDoH).emptyCustomUsesDefaults)
        XCTAssertThrowsError(try NetworkResolverConfiguration.customEndpoints("https://resolver.invalid/q, broken"))
    }

    func testIPv6ParserAndNativeRoutePreference() throws {
        XCTAssertEqual(NetworkIPAddress("[2001:db8::7]")?.family, .ipv6)
        XCTAssertEqual(NetworkIPAddress("::ffff:192.0.2.4")?.bytes.suffix(4), [192, 0, 2, 4])
        XCTAssertEqual(NetworkIPAddress("fe80::1%en0")?.scope, "en0")
        for text in ["1.2.3.256", "01.2.3.4", "2001::db8::1", "::ffff:999.0.0.1", "example.com", "fe80::1%a/b"] { XCTAssertNil(NetworkIPAddress(text), text) }
        let v4 = NetworkIPAddress("192.0.2.1")!, v6 = NetworkIPAddress("2001:db8::1")!
        XCTAssertEqual(NetworkResolverRoute.unknown.ordered([v4, v6, v4], preferIPv6: true), [v6, v4])
        XCTAssertEqual(NetworkResolverRoute(supportsIPv4: false, supportsIPv6: true).ordered([v4, v6], preferIPv6: false), [v6, v4])
        XCTAssertTrue(try NetworkDNSQuestion(name: "printer.local", type: .a).isLocalName)
        XCTAssertFalse(try NetworkDNSQuestion(name: "example.com", type: .a).isLocalName)
    }
}

func networkMapHex(_ text: String) -> Data {
    let bytes = Array(text.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(bytes: bytes[$0..<($0 + 2)], encoding: .ascii)!, radix: 16)! })
}
