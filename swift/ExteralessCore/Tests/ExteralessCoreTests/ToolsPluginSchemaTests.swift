import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsPluginSchemaTests: XCTestCase {
    func testUnknownAndUnclassifiedInputsAreNeverExported() throws {
        let bytes = Data("[{\"type\":\"switch\",\"key\":\"enabled\"},{\"type\":\"input\",\"key\":\"title\"},{\"type\":\"custom\",\"key\":\"custom\"},{\"type\":\"input\",\"key\":\"color\",\"backup_exportable\":true},{\"type\":\"input\",\"key\":\"api_key\",\"backup_exportable\":true}]".utf8)
        let schema = try ToolsPluginSchemaCache.decode(bytes)
        XCTAssertEqual(Set(schema.publicFields.keys), ["enabled", "color"])
        XCTAssertThrowsError(try schema.validate(["unknown": .bool(true)]))
        XCTAssertThrowsError(try schema.validate(["enabled": .string("not a boolean")]))
    }

    func testOldOwnerAndInvalidSchemaInvalidateExportPermission() throws {
        let cache = ToolsPluginSchemaCache()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings")
        let bytes = Data("[{\"type\":\"switch\",\"key\":\"enabled\"}]".utf8)
        try cache.record(fileName: "fixture.json", owner: "generation-1", cachedNativeSettingsJSON: bytes)
        XCTAssertTrue(try cache.location(directory: root, activeOwners: ["fixture.json": "generation-2"]).exportableFields.isEmpty)
        XCTAssertTrue(try cache.location(directory: root, activeOwners: ["fixture.json": "generation-1"]).exportableFields.isEmpty,
                      "Epoch matching without native evidence/validity is not export permission")
        XCTAssertThrowsError(try cache.record(fileName: "fixture.json", owner: "generation-1", cachedNativeSettingsJSON: Data("[]not-json".utf8)))
        XCTAssertTrue(try cache.location(directory: root, activeOwners: ["fixture.json": "generation-1"]).exportableFields.isEmpty)
    }
}
