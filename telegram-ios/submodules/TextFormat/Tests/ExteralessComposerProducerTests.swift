import ExteralessCore
import Foundation
import TelegramCore
import XCTest
@testable import TextFormat

/// CMC-07: production caption and forwarding-comment boundaries, including trim/split/entities.
/// These are the functions the actual pickers/forward callback call, not a second parser oracle.
final class ExteralessComposerProducerTests: XCTestCase {
    private func settings() throws -> ClientSettings {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try ClientSettings(storageURL: folder.appendingPathComponent("settings.json"))
        try store.register(ChatFeatures.definitions)
        return store
    }

    func testCaptionAndForwardCommentChooseTheSameNekoGrammarAndUTF16Entities() throws {
        let store = try settings()
        let input = NSMutableAttributedString(string: "  😀 x**bold**y [title](https://example.test/)  ")
        input.addAttribute(ChatTextInputAttributes.italic, value: true, range: NSRange(location: 2, length: 2))
        let caption = exteralessComposerCaption(input, settings: store)
        let comment = try XCTUnwrap(exteralessComposerForwardComment(input, settings: store).first)
        for piece in [caption, comment] {
            XCTAssertEqual(piece.text.string, "😀 xboldy title")
            XCTAssertTrue(piece.entities.contains(MessageTextEntity(range: 0 ..< 2, type: .Italic)))
            XCTAssertTrue(piece.entities.contains(MessageTextEntity(range: 4 ..< 8, type: .Bold)))
            XCTAssertTrue(piece.entities.contains(MessageTextEntity(range: 10 ..< 15, type: .TextUrl(url: "https://example.test/"))))
        }
        try store.set(.integer(0), for: "chats.markdownParser")
        XCTAssertEqual(exteralessComposerCaption(input, settings: store).text.string, "😀 x**bold**y [title](https://example.test/)")
        XCTAssertEqual(exteralessComposerForwardComment(input, settings: store).first?.text.string, "😀 x**bold**y [title](https://example.test/)")
    }

    func testDisableIsIndependentOfCaptionCommentAndEditGrammarAndKeepsExplicitMarks() throws {
        let store = try settings()
        try store.set(.bool(true), for: "chats.disableMarkdown")
        let input = NSAttributedString(string: "😀 **bold**", attributes: [ChatTextInputAttributes.underline: true])
        XCTAssertTrue(exteralessComposerMarkdown(input, settings: store).isEqual(to: input), "ordinary text-send disable")
        let caption = exteralessComposerCaption(input, settings: store)
        let comment = try XCTUnwrap(exteralessComposerForwardComment(input, settings: store).first)
        let edit = exteralessComposerMarkdown(input, settings: store, respectDisableMarkdown: false)
        for text in [caption.text, comment.text, edit] {
            XCTAssertEqual(text.string, "😀 bold")
            XCTAssertNotNil(text.attribute(ChatTextInputAttributes.underline, at: 0, effectiveRange: nil))
            XCTAssertNotNil(text.attribute(ChatTextInputAttributes.bold, at: 3, effectiveRange: nil))
        }
    }

    func testProducerKeepsAuthoredCodeDateAndLinkTextInsteadOfReparsingThem() throws {
        let store = try settings()
        let input = NSMutableAttributedString(string: "😀 `https://code.test/?utm_source=x` **day** [label](https://literal.test/) x**ok**y")
        let code = (input.string as NSString).range(of: "`https://code.test/?utm_source=x`")
        let date = (input.string as NSString).range(of: "**day**")
        let label = (input.string as NSString).range(of: "[label](https://literal.test/)")
        input.addAttribute(ChatTextInputAttributes.monospace, value: true, range: code)
        input.addAttribute(ChatTextInputAttributes.date, value: ChatTextInputTextDateAttribute(date: 99), range: date)
        input.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: "https://authored.test/?sig=x"), range: label)
        let result = exteralessComposerCaption(input, settings: store)
        XCTAssertEqual(result.text.string, "😀 `https://code.test/?utm_source=x` **day** [label](https://literal.test/) xoky")
        XCTAssertTrue(result.entities.contains(MessageTextEntity(range: date.location ..< NSMaxRange(date), type: .FormattedDate(format: nil, date: 99))))
        XCTAssertEqual((result.text.attribute(ChatTextInputAttributes.textUrl, at: label.location, effectiveRange: nil) as? ChatTextInputTextUrlAttribute)?.url, "https://authored.test/?sig=x")
    }

    func testForwardCommentSplitsAfterParsingWithoutMovingExplicitUTF16Entities() throws {
        let store = try settings()
        let input = NSAttributedString(string: String(repeating: "a", count: 4090) + " 😀 x**bold**y")
        let pieces = exteralessComposerForwardComment(input, settings: store)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.text.length <= 4096 })
        XCTAssertTrue(pieces.flatMap(\.entities).contains { $0.type == .Bold })
        for piece in pieces {
            for entity in piece.entities {
                XCTAssertGreaterThanOrEqual(entity.range.lowerBound, 0)
                XCTAssertLessThanOrEqual(entity.range.upperBound, piece.text.length)
                if entity.type == .Bold { XCTAssertEqual((piece.text.string as NSString).substring(with: NSRange(location: entity.range.lowerBound, length: entity.range.count)), "bold") }
            }
        }
    }
}
