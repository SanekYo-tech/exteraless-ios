import XCTest
import UIKit
import ExteralessCore
import TelegramCore
import TextFormat
import ChatInputTextNode
import ChatTextInputPanelNode
import RichTextEditorCore
import RichTextEditorUIKit
@testable import ComposerHarnessLib
@testable import RichTextEngineEditor

/// CMC-08, Tier 1: actual plain-paste entry points (native and UITextView), real injected CommonMark
/// parser, code/label bytes and undo. Clipboard contents are written before any read.
@available(iOS 18.4, *)
final class HarnessComposerPlainPasteTests: XCTestCase {
    private let url = "https://example.test/?utm_source=code&keep=1"
    private let label = "https://label.test/?utm_source=label"
    private let target = "https://target.test/?utm_source=href"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try composerSettingsForTesting(self, ["chats.stripTrackingOnPaste": .bool(true), "chats.disableMarkdown": .bool(false)])
    }

    private func waitForPaste(_ changed: () -> Bool) {
        let deadline = Date().addingTimeInterval(1.0)
        while !changed(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(changed(), "plain paste did not land before the bounded deadline")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    private var inlineCode: ChatInputContent {
        ChatInputContent(blocks: [.paragraph(ChatInputParagraph(runs: [
            ChatInputRun(text: "😀 "),
            ChatInputRun(text: "code", attributes: ChatInputInlineAttributes(monospace: true)),
            ChatInputRun(text: " tail", attributes: ChatInputInlineAttributes(underline: true))
        ]))])
    }

    func testLegacyPlainPasteInsideInlineCodeKeepsTheURLAndUndo() throws {
        let arranged = try HarnessLegacy.arrange(inlineCode)
        defer { HarnessLegacy.restore(arranged) }
        let textView = try XCTUnwrap(arranged.node.inputView as? ChatInputTextView)
        textView.selectedRange = NSRange(location: 5, length: 0)
        HarnessEngine.settle(arranged.root, seconds: 0.03)
        let before = arranged.host.panel.inputTextState.content
        textView.undoManager?.removeAllActions()
        UIPasteboard.general.string = url
        textView.paste(nil)
        waitForPaste { textView.text.contains(self.url) }
        XCTAssertTrue(arranged.host.panel.inputTextState.content.plainText.contains(url))
        XCTAssertFalse(arranged.host.panel.richTextInputNode?.usesNativeRichTextEngine ?? true, "code paste must not latch via Markdown")
        textView.undoManager?.undo()
        HarnessEngine.settle(arranged.root, seconds: 0.03)
        XCTAssertEqual(arranged.host.panel.inputTextState.content, before)
    }

    func testEnginePlainPasteInsideInlineCodeNeverCallsTheHostParser() throws {
        let root = try HarnessEngine.root()
        let host = try XCTUnwrap(root.panelHost)
        host.setInputContent(inlineCode)
        let node = try HarnessEngine.node(host)
        let editor = try XCTUnwrap(node.inputView as? RichTextEngineEditorView)
        defer { _ = node.resignInputFirstResponder() }
        _ = node.makeInputFirstResponder()
        editor.engineSelectedRange = NSRange(location: 5, length: 0)
        HarnessEngine.settle(root, seconds: 0.03)
        let before = editor.document
        let parser = host.panel.pastedMarkdownParser
        defer { host.panel.pastedMarkdownParser = parser }
        var calls = 0
        host.panel.pastedMarkdownParser = { context, text in calls += 1; return parser?(context, text) }
        editor.discardUndoHistory()
        UIPasteboard.general.string = url
        node.performRichPaste()
        waitForPaste { editor.engine.attributedBlocks.map(\.string).joined().contains(self.url) }
        XCTAssertEqual(calls, 0, "literal guard must precede the transformer")
        editor.undo()
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(editor.document, before)
    }

    private func checkFencedPaste(startingLegacy: Bool) throws {
        let root = try HarnessEngine.root()
        if startingLegacy { root.setBackend(.legacy) }
        defer {
            _ = root.panelHost?.panel.richTextInputNode?.resignInputFirstResponder()
            if startingLegacy { root.setBackend(.engine) }
        }
        let host = try XCTUnwrap(root.panelHost)
        host.setInputContent(HarnessContent.plainText("A"))
        let node = try XCTUnwrap(host.panel.richTextInputNode)
        _ = node.makeInputFirstResponder()
        node.selectedRange = NSRange(location: 1, length: 0)
        HarnessEngine.settle(root, seconds: 0.03)
        let original = host.panel.inputTextState.content
        let source = "```swift\nlet url = \"\(url)\"\n```\n\n[\(label)](\(target))"
        let parser = host.panel.pastedMarkdownParser
        defer { host.panel.pastedMarkdownParser = parser }
        var parseInputs: [String] = []
        host.panel.pastedMarkdownParser = { context, text in parseInputs.append(text); return parser?(context, text) }
        UIPasteboard.general.string = source
        if let textView = node.inputView as? UITextView { textView.paste(nil) }
        else { node.performRichPaste() }
        waitForPaste { host.panel.inputTextState.content.blocks.contains { if case .code = $0 { return true }; return false } }
        XCTAssertFalse(parseInputs.isEmpty)
        XCTAssertTrue(parseInputs.allSatisfy { $0 == source }, "no parser call may receive precleaned code or labels")
        let content = host.panel.inputTextState.content
        let code = try XCTUnwrap(content.blocks.compactMap { block -> ChatInputCode? in
            if case let .code(value) = block { return value }; return nil
        }.first)
        XCTAssertEqual(code.text, "let url = \"\(url)\"")
        let linked = content.blocks.compactMap { block -> ChatInputParagraph? in
            if case let .paragraph(value) = block { return value }; return nil
        }.flatMap(\.runs).filter { if case .url? = $0.attributes.entity { return true }; return false }
        XCTAssertEqual(linked.map(\.text).joined(), label)
        XCTAssertTrue(linked.allSatisfy { $0.attributes.entity == .url("https://target.test/") })
        let liveNode = try XCTUnwrap(host.panel.richTextInputNode)
        let editor = try XCTUnwrap(liveNode.inputView as? any RichTextEditor)
        editor.undo()
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(host.panel.inputTextState.content.plainText, "A" + source, "first undo restores ORIGINAL raw source")
        editor.undo()
        HarnessEngine.settle(root, seconds: 0.03)
        XCTAssertEqual(host.panel.inputTextState.content, original)
    }

    func testEngineFencedPlainPasteParsesOriginalCodeAndKeepsAuthoredLinkLabel() throws {
        try checkFencedPaste(startingLegacy: false)
    }

    func testLegacyFencedPlainPasteParsesOriginalCodeAndKeepsAuthoredLinkLabel() throws {
        try checkFencedPaste(startingLegacy: true)
    }

    func testLegacyOrdinaryURLStillCleansAndIsOneUndo() throws {
        let arranged = try HarnessLegacy.arrange(HarnessContent.plainText("before "))
        defer { HarnessLegacy.restore(arranged) }
        arranged.node.selectedRange = NSRange(location: 7, length: 0)
        HarnessEngine.settle(arranged.root, seconds: 0.03)
        let before = arranged.host.panel.inputTextState.content
        arranged.textView.undoManager?.removeAllActions()
        UIPasteboard.general.string = target
        arranged.textView.paste(nil)
        waitForPaste { arranged.host.panel.inputTextState.content.plainText != before.plainText }
        XCTAssertEqual(arranged.host.panel.inputTextState.content.plainText, "before https://target.test/")
        arranged.textView.undoManager?.undo()
        HarnessEngine.settle(arranged.root, seconds: 0.03)
        XCTAssertEqual(arranged.host.panel.inputTextState.content, before)
    }

    func testDisabledMarkdownKeepsLiteralCodeAndLabelsButCleansEligibleURLs() throws {
        try ClientSettings.shared.set(.bool(true), for: "chats.disableMarkdown")
        let source = "~~~~swift\n\(url)\n~~~~~\n`\(url)`\n[\(label)](\(target))\nhttps://control.test/?utm_source=x"
        var calls = 0
        let fragment = try XCTUnwrap(exteralessComposerPasteFragment(source, parseMarkdown: { _ in calls += 1; return nil }))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fragment.blocks.map(blockPlainText).joined(separator: "\n"),
                       "~~~~swift\n\(url)\n~~~~~\n`\(url)`\n[\(label)](https://target.test/)\nhttps://control.test/")
    }

    func testRawCodeSpanTreatsBackslashAsContentAndUnclosedFenceStaysLiteral() {
        XCTAssertEqual(exteralessCleanPastedPlainText("`\(url)\\` https://control.test/?utm_source=x"),
                       "`\(url)\\` https://control.test/")
        XCTAssertEqual(exteralessCleanPastedPlainText("```swift\n\(url)"), "```swift\n\(url)")
    }
}
