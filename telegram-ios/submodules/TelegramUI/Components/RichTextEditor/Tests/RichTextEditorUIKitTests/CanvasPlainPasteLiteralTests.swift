#if canImport(UIKit)
import XCTest
import UIKit
import RichTextEditorCore
@testable import RichTextEditorUIKit

/// CMC-08: the second native input backend must decide literal destinations before calling a host
/// plaintext transformer. Mixed selections are not uniformly `currentState().code`.
final class CanvasPlainPasteLiteralTests: XCTestCase {
    func testActualPlainPasteGuardCoversInlineCodeAndMixedSelection() {
        for mixed in [false, true] {
            let editor = RichTextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
            editor.document = Document(blocks: [.paragraph(ParagraphBlock(id: BlockID("p"), runs: [
                TextRun(text: "a"), TextRun(text: "code", attributes: CharacterAttributes(inlineCode: true)), TextRun(text: "z")
            ]))])
            let canvas = editor.canvas
            let pasteboard = CanvasClipboardTests.FakePasteboard()
            canvas.pasteboard = pasteboard
            let url = "https://example.test/?utm_source=code"
            pasteboard.string = url
            let from = mixed ? 1 : 3, to = mixed ? 6 : 3
            canvas.setSelectedGlobalRange(from: from, to: to)
            let before = editor.document
            var calls = 0
            editor.plainTextFragmentTransformer = { _ in
                calls += 1
                return Document(blocks: [.paragraph(ParagraphBlock(id: .generate(), runs: [TextRun(text: "WRONG")]))])
            }
            let undo = UndoManager()
            undo.groupsByEvent = false
            canvas.undoManagerOverride = undo
            undo.beginUndoGrouping()
            canvas.paste(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(editor.document.blocks.map(blockPlainText).joined().contains(url))
            undo.undo()
            XCTAssertEqual(editor.document, before)
        }
    }

    func testNativeSelectionRevisionSeesABAWithoutWaitingForOnChange() {
        let editor = RichTextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        editor.document = Document(blocks: [.paragraph(ParagraphBlock(id: BlockID("p"), runs: [TextRun(text: "abc")]))])
        editor.canvas.setSelectedGlobalRange(from: 1, to: 2)
        let revision = editor.selectionRevision
        editor.canvas.setSelectedGlobalRange(from: 2, to: 3)
        editor.canvas.setSelectedGlobalRange(from: 1, to: 2)
        XCTAssertGreaterThan(editor.selectionRevision, revision)
        let contentRevision = editor.documentRevision
        editor.setLink("tg://timestamp?t=99")
        XCTAssertGreaterThan(editor.documentRevision, contentRevision)
    }

    func testNativeCaptionDateAddRemoveKeepsUnderlineMediaAndOneUndo() throws {
        let editor = RichTextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        editor.document = Document(blocks: [
            .paragraph(ParagraphBlock(id: BlockID("heading"), style: .heading1, runs: [TextRun(text: "Heading")])),
            .media(MediaBlock(id: BlockID("media"), mediaID: "opaque-media", naturalSize: Size2D(width: 100, height: 100), caption: [
                TextRun(text: "😀 "), TextRun(text: "date", attributes: CharacterAttributes(underline: true)), TextRun(text: " tail")
            ]))
        ])
        let start = try XCTUnwrap(PositionResolver.globalPosition(of: .caption(BlockID("media")), offset: 3, in: DocumentTree.build(from: editor.document)))
        editor.canvas.setSelectedGlobalRange(from: start, to: start + 4)
        XCTAssertEqual(editor.composerSelectedRange.length, 0, "caption is off the composer axis")
        XCTAssertEqual(editor.selectedGlobalRange()?.from, start)
        let before = editor.document
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.canvas.undoManagerOverride = undo
        undo.beginUndoGrouping()
        editor.setLink("tg://timestamp?t=99")
        undo.endUndoGrouping()
        let dated = editor.document
        XCTAssertNotEqual(dated, before)
        XCTAssertEqual(editor.currentLink(), "tg://timestamp?t=99")
        let datedRuns = try XCTUnwrap(dated.runs(for: .caption(BlockID("media"))))
        XCTAssertTrue(datedRuns.filter { $0.attributes.link != nil }.allSatisfy { $0.attributes.underline })
        undo.beginUndoGrouping()
        editor.removeLink()
        undo.endUndoGrouping()
        XCTAssertEqual(editor.document, before, "removal must preserve caption underline and its own color")
        undo.undo()
        XCTAssertEqual(editor.document, dated)
        undo.undo()
        XCTAssertEqual(editor.document, before)
        XCTAssertFalse(undo.canUndo)
    }
}
#endif
