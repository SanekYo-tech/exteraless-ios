import XCTest
import UIKit
import RichTextEditorCore
import RichTextEditorUIKit
@testable import RichTextEngineEditor

@available(iOS 18.4, *)
final class ChatLinkIngressTests: XCTestCase {
    private var window: UIWindow!
    private var editor: RichTextEngineEditorView!
    private let original = "https://example.test/?utm_source=x"
    private let cleaned = "https://example.test/"
    override func setUp() {
        super.setUp()
        editor = RichTextEngineEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(editor); window.makeKeyAndVisible()
        editor.document = Document(blocks: [.paragraph(ParagraphBlock(id: BlockID("p"), runs: [TextRun(text: "A")]))])
        XCTAssertTrue(editor.engine.becomeFirstResponder())
        editor.engineSelectedRange = NSRange(location: 1, length: 0)
    }
    override func tearDown() {
        editor.engine.resignFirstResponder(); window.isHidden = true
        window = nil; editor = nil
        super.tearDown()
    }
    func testFinalIMEInsertTransformsOnceBeforeNativeUndoableEdit() {
        var calls = 0
        editor.committedTextTransformer = { [cleaned] _ in calls += 1; return cleaned }
        editor.engine.setMarkedText(original, selectedRange: NSRange(location: original.utf16.count, length: 0))
        XCTAssertEqual(calls, 0, "marked candidates belong to the IME")
        editor.engine.insertText(original)
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A" + cleaned])
        XCTAssertGreaterThan(calls, 0)
        XCTAssertEqual(editor.engineSelectedRange, NSRange(location: 1 + cleaned.utf16.count, length: 0))
        editor.engine.undoManager?.undo()
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A"])
    }
    func testPrivateFragmentPasteKeepsQuoteAndCaptionWhileRewritingHref() {
        editor.pastedLinkTargetTransformer = { [cleaned] _ in cleaned }
        let link = TextRun(text: "label", attributes: CharacterAttributes(link: original))
        let fragment = Document(blocks: [.blockQuote(BlockQuote(id: BlockID("q"), children: [.media(MediaBlock(id: BlockID("m"), mediaID: "file", naturalSize: Size2D(width: 100, height: 100), caption: [link]))]))])
        XCTAssertTrue(editor.pasteFragment(from: .fragment(fragment)))
        let doc = editor.document
        guard let quote = doc.blocks.compactMap({ block -> BlockQuote? in if case let .blockQuote(q) = block { return q }; return nil }).first,
              case let .media(media) = quote.children[0] else { return XCTFail("private fragment was flattened") }
        XCTAssertEqual(media.mediaID, "file")
        XCTAssertEqual(media.caption.first?.text, "label")
        XCTAssertEqual(media.caption.first?.attributes.link, cleaned)
    }

    func testActualPlainPasteIntoInlineCodeSkipsEveryHostTransform() {
        editor.document = Document(blocks: [.paragraph(ParagraphBlock(id: BlockID("p"), runs: [
            TextRun(text: "😀 "), TextRun(text: "code", attributes: CharacterAttributes(inlineCode: true)),
            TextRun(text: " tail", attributes: CharacterAttributes(underline: true))
        ]))])
        editor.engineSelectedRange = NSRange(location: 5, length: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let before = editor.document
        editor.discardUndoHistory()
        var transforms = 0
        editor.plainTextFragmentTransformer = { [cleaned] _ in
            transforms += 1
            return Document(blocks: [.paragraph(ParagraphBlock(id: .generate(), runs: [TextRun(text: cleaned)]))])
        }
        editor.committedTextTransformer = { [cleaned] _ in transforms += 1; return cleaned }
        UIPasteboard.general.string = original
        editor.engine.paste(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(transforms, 0)
        XCTAssertTrue(editor.engine.attributedBlocks.map(\.string).joined().contains(original))
        editor.undo()
        XCTAssertEqual(editor.document, before)
    }

    func testActualProsePlainPasteTransformsOnceAndUndoKeepsTheRawSource() {
        var calls = 0
        editor.plainTextFragmentTransformer = { [original, cleaned] text in
            calls += 1
            XCTAssertEqual(text, original)
            return Document(blocks: [.paragraph(ParagraphBlock(id: .generate(), runs: [TextRun(text: cleaned)]))])
        }
        editor.discardUndoHistory()
        UIPasteboard.general.string = original
        editor.engine.paste(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A" + cleaned])
        editor.undo()
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A" + original])
        editor.undo()
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A"])
    }

    func testInputRevisionsChangeBeforeDeferredOnChangeAndNeverRollBackOnUndo() {
        let selectionRevision = editor.selectionRevision
        editor.engineSelectedRange = NSRange(location: 0, length: 1)
        editor.engineSelectedRange = NSRange(location: 1, length: 0)
        XCTAssertGreaterThan(editor.selectionRevision, selectionRevision)
        let documentRevision = editor.documentRevision
        editor.engine.insertText("B")
        let editedRevision = editor.documentRevision
        XCTAssertGreaterThan(editedRevision, documentRevision)
        editor.undo()
        XCTAssertGreaterThan(editor.documentRevision, editedRevision)
        XCTAssertEqual(editor.engine.attributedBlocks.map(\.string), ["A"])
    }
}
