import ExteralessCore
import Foundation
import XCTest
@testable import TextFormat

final class ExteralessComposerPolicyTests: XCTestCase {
    private func settings() throws -> ClientSettings {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try ClientSettings(storageURL: folder.appendingPathComponent("settings.json"))
        try store.register(ChatFeatures.definitions)
        return store
    }
    func testNekoAdjacentMarkersAndLinksDifferFromTelegramGrammar() throws {
        let store = try settings()
        let source = NSAttributedString(string: "x**bold**y [title](https://example.test/)")
        let parsed = exteralessComposerMarkdown(source, settings: store)
        XCTAssertEqual(parsed.string, "xboldy title")
        XCTAssertNotNil(parsed.attribute(ChatTextInputAttributes.bold, at: 1, effectiveRange: nil))
        XCTAssertEqual((parsed.attribute(ChatTextInputAttributes.textUrl, at: 7, effectiveRange: nil) as? ChatTextInputTextUrlAttribute)?.url, "https://example.test/")
        try store.set(.integer(0), for: "chats.markdownParser")
        XCTAssertEqual(exteralessComposerMarkdown(source, settings: store).string, source.string)
    }
    func testDisablePreservesExplicitFormattingAndCodeIsAlwaysLiteral() throws {
        let store = try settings()
        let source = NSAttributedString(string: "**literal**", attributes: [ChatTextInputAttributes.monospace: true])
        XCTAssertTrue(exteralessComposerMarkdown(source, settings: store).isEqual(to: source))
        let explicit = NSAttributedString(string: "😀 **bold**", attributes: [ChatTextInputAttributes.italic: true])
        try store.set(.bool(true), for: "chats.disableMarkdown")
        XCTAssertTrue(exteralessComposerMarkdown(explicit, settings: store).isEqual(to: explicit))
    }
    func testNestedFormattingRetainsUTF16AndExistingLinkTarget() throws {
        let store = try settings()
        let source = NSMutableAttributedString(string: "😀 **a__b__** url")
        let urlRange = (source.string as NSString).range(of: "url")
        source.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: "https://signed.test/?sig=x&utm_source=y"), range: urlRange)
        let parsed = exteralessComposerMarkdown(source, settings: store)
        XCTAssertEqual(parsed.string, "😀 ab url")
        XCTAssertNotNil(parsed.attribute(ChatTextInputAttributes.bold, at: 4, effectiveRange: nil))
        XCTAssertNotNil(parsed.attribute(ChatTextInputAttributes.italic, at: 4, effectiveRange: nil))
        XCTAssertEqual((parsed.attribute(ChatTextInputAttributes.textUrl, at: 6, effectiveRange: nil) as? ChatTextInputTextUrlAttribute)?.url, "https://signed.test/?sig=x&utm_source=y")
    }
}
