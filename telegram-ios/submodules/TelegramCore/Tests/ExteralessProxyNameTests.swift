import Foundation
import XCTest
@testable import TelegramCore

final class ExteralessProxyNameTests: XCTestCase {
    func testProxyNameRoundTripsWithoutChangingConnectionCredentials() throws {
        let server = ProxyServerSettings(host: "proxy.example", port: 1080, connection: .socks5(username: "fixture", password: "fixture"))
        let named = server.withUpdatedDisplayName(" Home\nrelay ")
        XCTAssertEqual(named.displayName, "Home relay")
        let decoded = try JSONDecoder().decode(ProxyServerSettings.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(decoded, named)
        XCTAssertEqual(decoded.connection, server.connection)
        XCTAssertNil(decoded.withUpdatedDisplayName(" ").displayName)
    }

    func testLegacyProxyDocumentWithoutNameDecodes() throws {
        let data = Data(#"{"host":"proxy.example","port":443,"connection":{"_t":0}}"#.utf8)
        let decoded = try JSONDecoder().decode(ProxyServerSettings.self, from: data)
        XCTAssertNil(decoded.displayName)
        XCTAssertEqual(decoded.port, 443)
    }
}
