import Foundation
import XCTest
@testable import PluginHost

final class BridgeAccountArgumentTests: XCTestCase {
    private final class Messages: PluginMessagesService {
        let receivedAccounts = Recorder<Int32>()
        func selectedAccount() -> Int32 { 0 }
        func instanceHandle(fqcn: String, account: Int32) -> Int64 {
            receivedAccounts.append(account)
            return Int64(account) + 1000
        }
    }

    private func call(account: Int64, messages: Messages = Messages()) throws -> [String: Any] {
        let service = BridgeServices(messages: messages)
        let json = """
        {"op":"call","fqcn":"org.telegram.messenger.MessagesController","member":"getInstance","args":[\(account)]}
        """
        return try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(service.dispatchJSON(json, pluginId: "account_test").utf8)) as? [String: Any])
    }

    func testAccountIsPassedAsInt32() throws {
        let messages = Messages()
        let result = try call(account: 7, messages: messages)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(messages.receivedAccounts.values, [7])
        let tag = try XCTUnwrap(result["value"] as? [String: Any])
        XCTAssertLessThan(try XCTUnwrap(tag["__handle__"] as? NSNumber).int64Value, 0)
        XCTAssertEqual(tag["__fqcn__"] as? String, "org.telegram.messenger.MessagesController")
    }

    func testOutOfRangeAccountIsRejectedInsteadOfTrappingOrWrapping() throws {
        for account in [Int64(Int32.max) + 1, Int64(Int32.min) - 1] {
            let result = try call(account: account)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["kind"] as? String, "MalformedRequest")
        }
    }
}
