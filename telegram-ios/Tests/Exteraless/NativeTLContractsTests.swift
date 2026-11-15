import Foundation
import XCTest

final class NativeTLContractsTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        let value = Array(hex.utf8)
        return Data(stride(from: 0, to: value.count, by: 2).map {
            UInt8(String(decoding: value[$0 ..< $0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    private func object(_ name: String, _ fields: [String: ExteralessTLValue] = [:]) -> ExteralessTLValue {
        var result = fields
        result["_"] = .string(name)
        return .object(result)
    }

    func testIndependentWireGoldenAndEveryTruncation() throws {
        let codec = ExteralessTLCodec.shared
        let value = object("inputDocument", ["id": .integer(42), "access_hash": .integer(-3),
                                             "file_reference": .bytes(Data([0, 255, 16]))])
        // Pre-engine TelegramApi fixture, not regenerated from this codec.
        let golden = bytes("75b5bf1a2a00000000000000fdffffffffffffff0300ff10")
        XCTAssertEqual(try codec.encode(value, as: "InputDocument"), golden)
        XCTAssertEqual(try codec.encode(codec.decode(golden, as: "InputDocument"), as: "InputDocument"), golden)
        for length in 0 ..< golden.count {
            XCTAssertThrowsError(try codec.decode(golden.prefix(length), as: "InputDocument"))
        }
    }

    func testRequestResultTypeAndLosslessLongResponse() throws {
        let codec = ExteralessTLCodec.shared
        let request = object("users.getUsers", ["id": .array([object("inputUserSelf")])])
        let packed = try codec.encodeRequest(request)
        XCTAssertEqual(packed.body, bytes("48a5910d15c4b51c010000003fb1c1f7"))
        XCTAssertEqual(packed.resultType, "Vector<User>")
        XCTAssertEqual(try codec.decodeRequest(packed.body), request)
        let response = bytes("15c4b51c010000007a4bbcd3ffffffffffffff7f")
        XCTAssertEqual(try codec.decodeMethodResponse(response, methodName: "users.getUsers"),
                       .array([object("userEmpty", ["id": .integer(Int64.max)])]))
        XCTAssertThrowsError(try codec.encode(.integer(Int64(Int32.max) + 1), as: "int"))
        XCTAssertThrowsError(try codec.encode(.bool(true), as: "int"))
    }

    func testCallbackTicketIsBoundToPluginOwnerAndCompletesOnce() throws {
        let registry = ExteralessTLRequestRegistry<Int>(maximumPerPlugin: 2, maximumTotal: 3)
        let ticket = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 7,
                                          accountRecordId: Int64.max, timeoutMs: 1000) { _ in }
        XCTAssertEqual(ticket.accountRecordId, Int64.max)
        XCTAssertNil(registry.take(id: ticket.id, pluginId: "two", owner: 11))
        XCTAssertNil(registry.take(id: ticket.id, pluginId: "one", owner: 12))
        XCTAssertThrowsError(try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 7,
                                                  accountRecordId: 1, timeoutMs: 1000) { _ in })
        XCTAssertNotNil(registry.take(ticket))
        XCTAssertNil(registry.take(ticket))
        XCTAssertEqual(registry.count, 0)
    }
}
