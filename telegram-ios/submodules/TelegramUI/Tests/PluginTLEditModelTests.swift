import Foundation
import TelegramCore
import XCTest
@testable import TelegramUI

final class PluginTLEditModelTests: XCTestCase {
    private var model: [String: Any] {
        ["schemaVersion": 1, "account": 0, "peer": ["type": "user", "id": 1], "message": ["id": 7], "kind": "text",
         "entities": [["_": "messageEntityBold", "offset": 0, "length": 1]]]
    }
    func testEntitiesOnlyDefersCaptionRangeUntilCachedText() throws {
        let value = try PluginTLEditMediaModel(model)
        XCTAssertNil(value.caption)
        XCTAssertEqual(value.entities?.count, 1)
        try exteralessTLValidateMediaEntities(try XCTUnwrap(value.entities), caption: "ab")
        XCTAssertThrowsError(try exteralessTLValidateMediaEntities(try XCTUnwrap(value.entities), caption: ""))
    }
    func testExplicitEmptyCaptionIsValidatedAtDTOBoundary() {
        var value = model
        value["caption"] = ""
        XCTAssertThrowsError(try PluginTLEditMediaModel(value))
        value["entities"] = [] as [Any]
        XCTAssertEqual(try PluginTLEditMediaModel(value).caption, "")
    }
    func testSuppliedCaptionAndOmittedEntitiesRemainDistinct() throws {
        var value = model
        value["caption"] = "changed"
        value.removeValue(forKey: "entities")
        let parsed = try PluginTLEditMediaModel(value)
        XCTAssertEqual(parsed.caption, "changed")
        XCTAssertNil(parsed.entities)
    }
}
