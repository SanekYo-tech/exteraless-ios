import XCTest
@testable import ExteralessCore

final class ToolsArchiveIDCodecTests: XCTestCase {
    func testArchiveIDsUseTheExistingNativeSettingsComponent() throws {
        XCTAssertEqual(try ToolsPluginSchemaCache.settingsFileName(pluginId: "12"), "12-3132.json")
        XCTAssertEqual(try ToolsPluginSchemaCache.settingsFileName(pluginId: "_p"), "_p-5f70.json")
        XCTAssertEqual(try ToolsPluginSchemaCache.settingsFileName(pluginId: "__"), "__-5f5f.json")
        XCTAssertNoThrow(try ToolsPluginSchemaCache.settingsFileName(pluginId: "a-b"))
        XCTAssertNotEqual(try ToolsPluginSchemaCache.settingsFileName(pluginId: "Case").lowercased(),
                          try ToolsPluginSchemaCache.settingsFileName(pluginId: "case").lowercased())
        for id in ["a", "1-b", "_a-b", "../ab", "a.b", "exteralessMetadataInspector"] {
            XCTAssertThrowsError(try ToolsPluginSchemaCache.settingsFileName(pluginId: id))
        }
    }
}
