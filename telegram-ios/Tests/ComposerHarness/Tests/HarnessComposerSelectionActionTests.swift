import XCTest
import UIKit
import TelegramCore
import TextFormat
import ChatInputTextNode
import ChatRichTextEditorComposer
import ChatTextInputPanelNode
@testable import ComposerHarnessLib
@testable import RichTextEngineEditor

/// CMC-01/06, Tier 1: real Format UIActions, held presentation completions, the real node and
/// kernel. The Date presenter answers the SAME request ChatController passes to its date picker.
/// Mention tests call the production peer-picker completion request without constructing a picker.
@available(iOS 18.4, *)
final class HarnessComposerSelectionActionTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try composerSettingsForTesting(self, ["chats.showTextCreateDate": .bool(true), "chats.showTextTranslate": .bool(true)])
    }
    private enum Region: String, CaseIterable {
        case body, cell, caption, title, detail, author
    }

    private func runs(_ region: Region) -> [ChatInputRun] {
        [ChatInputRun(text: "😀 "),
         ChatInputRun(text: region.rawValue, attributes: ChatInputInlineAttributes(underline: true)),
         ChatInputRun(text: " tail", attributes: ChatInputInlineAttributes(strikethrough: true))]
    }

    private func fixture() -> ChatInputContent {
        var media = HarnessEdited.media(807, caption: "")
        if case var .media(value) = media {
            value.caption = runs(.caption)
            value.items.append(ChatInputMediaItem(media: HarnessEdited.image(808), kind: .image, naturalSize: ChatInputSize(width: 400, height: 300), isSpoiler: true))
            value.displayMode = .slideshow
            media = .media(value)
        }
        return ChatInputContent(blocks: [
            .paragraph(ChatInputParagraph(style: .heading1, runs: [ChatInputRun(text: "Heading")])),
            .paragraph(ChatInputParagraph(runs: runs(.body))),
            .blockQuote(ChatInputBlockQuote(content: ChatInputContent(blocks: [
                .paragraph(ChatInputParagraph(runs: [ChatInputRun(text: "Quote")])),
                .blockQuote(ChatInputBlockQuote(content: ChatInputContent(blocks: [
                    .paragraph(ChatInputParagraph(runs: [ChatInputRun(text: "Nested")]))
                ]), collapsed: false, author: [ChatInputRun(text: "Inner")]))
            ]), collapsed: false, author: runs(.author))),
            .table(ChatInputTable(columns: [ChatInputColumnSpec(width: 120), ChatInputColumnSpec(width: 120)], rows: [
                ChatInputTableRow(cells: [ChatInputTableCell(runs: runs(.cell)), ChatInputTableCell(runs: [ChatInputRun(text: "other")])])
            ])),
            media,
            .details(ChatInputDetails(content: ChatInputContent(blocks: [
                .paragraph(ChatInputParagraph(runs: runs(.detail)))
            ]), title: runs(.title), expanded: true)),
            HarnessEdited.buttonRow(["One", "Two"])
        ])
    }

    private func arranged() throws -> (HarnessRootViewController, HarnessPanelHost, RichTextEditorChatInputNode, RichTextEngineEditorView) {
        let root = try HarnessEngine.root()
        let host = try XCTUnwrap(root.panelHost)
        host.setInputContent(fixture())
        let node = try XCTUnwrap(host.panel.richTextInputNode as? RichTextEditorChatInputNode)
        let editor = try XCTUnwrap(node.inputView as? RichTextEngineEditorView)
        _ = node.makeInputFirstResponder()
        HarnessEngine.settle(root, seconds: 0.03)
        editor.discardUndoHistory()
        return (root, host, node, editor)
    }

    private func select(_ region: Region, in editor: RichTextEngineEditorView) throws {
        let blocks = editor.engine.attributedBlocks
        let index = try XCTUnwrap(blocks.firstIndex { $0.string == "😀 \(region.rawValue) tail" })
        let range = (blocks[index].string as NSString).range(of: region.rawValue)
        XCTAssertEqual(range.location, 3, "the fixture must exercise UTF-16 after an emoji")
        editor.engineSelectedRange = NSRange(location: editor.flatOffset(ofRoleAt: index) + range.location, length: range.length)
    }

    private func invokeFormat(_ id: String, node: ChatRichTextInputNode) throws {
        func find(_ elements: [UIMenuElement]) -> UIAction? {
            for element in elements {
                if let action = element as? UIAction, action.identifier.rawValue == "exteraless.format." + id { return action }
                if let menu = element as? UIMenu, let action = find(menu.children) { return action }
            }
            return nil
        }
        let action = try XCTUnwrap(find(node.contextMenuItemsProvider?([]) ?? []))
        XCTAssertFalse(action.attributes.contains(.disabled))
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
    }

    /// Expected field-specific change, independent of either selection coordinate implementation.
    private func expected(_ source: ChatInputContent, region: Region, change: (ChatInputRun) -> ChatInputRun) -> ChatInputContent {
        func changed(_ runs: [ChatInputRun]) -> [ChatInputRun] {
            runs.map { $0.text == region.rawValue ? change($0) : $0 }
        }
        var result = source
        switch region {
        case .body:
            if case var .paragraph(p) = result.blocks[1] { p.runs = changed(p.runs); result.blocks[1] = .paragraph(p) }
        case .author:
            if case var .blockQuote(q) = result.blocks[2] { q.author = changed(q.author); result.blocks[2] = .blockQuote(q) }
        case .cell:
            if case var .table(t) = result.blocks[3] { t.rows[0].cells[0].runs = changed(t.rows[0].cells[0].runs); result.blocks[3] = .table(t) }
        case .caption:
            if case var .media(m) = result.blocks[4] { m.caption = changed(m.caption); result.blocks[4] = .media(m) }
        case .title, .detail:
            if case var .details(d) = result.blocks[5] {
                if region == .title { d.title = changed(d.title) }
                else if case var .paragraph(p) = d.content.blocks[0] { p.runs = changed(p.runs); d.content.blocks[0] = .paragraph(p) }
                result.blocks[5] = .details(d)
            }
        }
        return result
    }

    func testFormatDateAddAndRemoveKeepTheWholeRichDraftAndEachUndoOnce() throws {
        let (root, host, node, editor) = try arranged()
        defer { _ = node.resignInputFirstResponder() }
        let base = try XCTUnwrap(host.panel.interfaceInteraction)
        defer { host.panel.interfaceInteraction = base }
        var request: (text: NSAttributedString, apply: (Int32) -> Bool)?
        host.panel.interfaceInteraction = composerSelectionActionInteraction(base, openDate: { [weak panel = host.panel] in
            request = panel?.beginNativeDateEditing()
        }, translate: { _, _ in XCTFail("wrong presentation endpoint") })
        try select(.body, in: editor)
        let original = node.currentInputContent().content
        let originalDocument = editor.document
        try invokeFormat("date", node: node)
        let add = try XCTUnwrap(request)
        XCTAssertEqual(add.text.string, "body")
        XCTAssertTrue(add.apply(1_700_000_000))
        HarnessEngine.settle(root, seconds: 0.03)
        let dated = expected(original, region: .body) { run in
            var run = run; run.attributes.entity = .date(1_700_000_000); return run
        }
        XCTAssertEqual(node.currentInputContent().content, dated)
        XCTAssertFalse(add.apply(1_800_000_000), "a completion is single-use")
        editor.undo()
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(editor.document, originalDocument)
        XCTAssertFalse(editor.currentState().canUndo, "Date must be one undo step")
        editor.redo()
        HarnessEngine.settle(root, seconds: 0.03)
        try select(.body, in: editor)
        request = nil
        try invokeFormat("date", node: node)
        let remove = try XCTUnwrap(request)
        XCTAssertEqual((remove.text.attribute(ChatTextInputAttributes.date, at: 0, effectiveRange: nil) as? ChatTextInputTextDateAttribute)?.date, 1_700_000_000)
        XCTAssertTrue(remove.apply(0))
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(node.currentInputContent().content, original)
        editor.undo()
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(node.currentInputContent().content, dated)
    }

    func testFormatTranslateUsesEachRealRegionAndKeepsEverythingOutsideIt() throws {
        let (root, host, node, editor) = try arranged()
        defer { _ = node.resignInputFirstResponder() }
        let base = try XCTUnwrap(host.panel.interfaceInteraction)
        defer { host.panel.interfaceInteraction = base }
        var request: (text: NSAttributedString, apply: (NSAttributedString) -> Void)?
        host.panel.interfaceInteraction = composerSelectionActionInteraction(base, openDate: {}, translate: { text, apply in
            request = (text, apply)
        })
        for region in Region.allCases {
            try select(region, in: editor)
            let before = node.currentInputContent().content
            let beforeDocument = editor.document
            if region != .body { XCTAssertEqual(node.selectedRange.length, 0, "off-flat-axis control") }
            request = nil
            try invokeFormat("translate", node: node)
            let held = try XCTUnwrap(request)
            XCTAssertEqual(held.text.string, region.rawValue)
            XCTAssertNotNil(held.text.attribute(ChatTextInputAttributes.underline, at: 0, effectiveRange: nil))
            held.apply(NSAttributedString(string: "новое", attributes: [ChatTextInputAttributes.strikethrough: true, ChatTextInputAttributes.underline: true]))
            HarnessEngine.settle(root, seconds: 0.03)
            XCTAssertEqual(node.currentInputContent().content, expected(before, region: region) { _ in
                ChatInputRun(text: "новое", attributes: ChatInputInlineAttributes(strikethrough: true, underline: true))
            })
            editor.undo()
            HarnessEngine.settle(root, seconds: 0.03)
            XCTAssertEqual(editor.document, beforeDocument)
        }
    }

    func testMentionPickerCompletionLinksEachRealRegionAsOneUndo() throws {
        let (root, host, node, editor) = try arranged()
        defer { _ = node.resignInputFirstResponder() }
        for region in Region.allCases {
            try select(region, in: editor)
            let before = node.currentInputContent().content
            let beforeDocument = editor.document
            let apply = try XCTUnwrap(host.panel.beginSelectionMention())
            XCTAssertTrue(apply(EnginePeer.Id(42)))
            HarnessEngine.settle(root, seconds: 0.03)
            XCTAssertEqual(node.currentInputContent().content, expected(before, region: region) { run in
                var run = run; run.attributes.entity = .mention(EnginePeer.Id(42)); return run
            })
            editor.undo()
            HarnessEngine.settle(root, seconds: 0.03)
            XCTAssertEqual(editor.document, beforeDocument)
        }
    }

    func testHeldActionsRejectSameFlatRangeABAAndAReplacedDraft() throws {
        let (root, host, node, editor) = try arranged()
        defer { _ = node.resignInputFirstResponder() }
        try select(.cell, in: editor)
        let date = try XCTUnwrap(host.panel.beginNativeDateEditing())
        let mention = try XCTUnwrap(host.panel.beginSelectionMention())
        let translate = try XCTUnwrap(host.panel.beginSelectionTranslation())
        let original = editor.document
        let flat = node.selectedRange
        // No run-loop turn: onChange is still pending. Both regions have the SAME flat range.
        try select(.caption, in: editor)
        XCTAssertEqual(node.selectedRange, flat)
        try select(.cell, in: editor)
        XCTAssertFalse(date.apply(1_700_000_000))
        XCTAssertFalse(mention(EnginePeer.Id(42)))
        translate.apply(NSAttributedString(string: "must not replace the draft"))
        XCTAssertEqual(editor.document, original)
        let next = try XCTUnwrap(host.panel.beginSelectionTranslation())
        host.setInputContent(HarnessContent.plainText("New draft"))
        HarnessEngine.settle(root, seconds: 0.03)
        next.apply(NSAttributedString(string: "old result"))
        XCTAssertEqual(node.currentInputContent().content.plainText, "New draft")
    }

    func testTranslateNeverWidensAPartialUnitToItsUnselectedContent() throws {
        let (_, host, node, editor) = try arranged()
        defer { _ = node.resignInputFirstResponder() }
        let blocks = editor.engine.attributedBlocks
        let firstCell = try XCTUnwrap(blocks.firstIndex { $0.string == "😀 cell tail" })
        let lastCell = try XCTUnwrap(blocks.firstIndex { $0.string == "other" })
        let body = try XCTUnwrap(blocks.firstIndex { $0.string == "😀 body tail" })
        let caption = try XCTUnwrap(blocks.firstIndex { $0.string == "😀 caption tail" })
        let ranges = [
            editor.flatOffset(ofRoleAt: firstCell) + 3 ..< editor.flatOffset(ofRoleAt: lastCell) + 2,
            editor.flatOffset(ofRoleAt: body) + 3 ..< editor.flatOffset(ofRoleAt: caption) + 5
        ]
        for range in ranges {
            editor.engineSelectedRange = NSRange(location: range.lowerBound, length: range.count)
            let before = editor.document
            let snapshot = try XCTUnwrap(node.captureRichTextSelection())
            XCTAssertFalse(node.canReplaceRichTextSelection)
            XCTAssertNil(host.panel.beginSelectionTranslation())
            XCTAssertFalse(node.replaceRichTextSelection(snapshot, with: NSAttributedString(string: "replacement")))
            XCTAssertEqual(editor.document, before)
        }
    }
}
