import Foundation
import XCTest
@testable import PluginHost

final class BridgeAccountArgumentTests: XCTestCase {
    private final class Messages: PluginMessagesService {
        func selectedAccount() -> Int32 { 0 }
        func instanceHandle(fqcn: String, account: Int32) -> Int64 { Int64(account) + 1000 }
    }

    private func call(account: Int64) throws -> [String: Any] {
        let service = BridgeServices(messages: Messages())
        let json = """
        {"op":"call","fqcn":"org.telegram.messenger.MessagesController","member":"getInstance","args":[\(account)]}
        """
        return try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(service.dispatchJSON(json, pluginId: nil).utf8)) as? [String: Any])
    }

    func testAccountIsPassedAsInt32() throws {
        let result = try call(account: 7)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual((result["value"] as? NSNumber)?.int64Value, 1007)
    }

    func testOutOfRangeAccountIsRejectedInsteadOfTrappingOrWrapping() throws {
        for account in [Int64(Int32.max) + 1, Int64(Int32.min) - 1] {
            let result = try call(account: account)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["kind"] as? String, "MalformedRequest")
        }
    }
}
