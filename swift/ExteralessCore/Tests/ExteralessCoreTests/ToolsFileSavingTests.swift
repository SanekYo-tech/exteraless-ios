import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsFileSavingTests: XCTestCase {
    func testConfiguredFoldersAreBoundedAndChatIdentityIsStable() throws {
        XCTAssertEqual(try ToolsSavePathPolicy.components(customFolder: " My files ", perChat: true, accountId: 1, chatId: -99), ["My files", "account-1", "chat--99"])
        for bad in ["..", "/outside", "a/b", "a\\b", "\u{0}bad"] { XCTAssertThrowsError(try ToolsSavePathPolicy.customFolder(bad)) }
    }

    func testFileSavePreservesExistingFilesAndUsesRealCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-save-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let first = try ToolsLocalFileSaver.copy(source: source, destination: root, components: ["My files"], name: "document.bin", maximumBytes: 100)
        let second = try ToolsLocalFileSaver.copy(source: source, destination: root, components: ["My files"], name: "document.bin", maximumBytes: 100)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([1, 2, 3]))
        XCTAssertThrowsError(try ToolsLocalFileSaver.copy(source: source, destination: root, components: [], name: "../escape", maximumBytes: 100))
    }
}
