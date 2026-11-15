import AsyncDisplayKit
import ChatPresentationInterfaceState
import ChatRichTextEditorComposer
import Display
import Foundation
import RichTextEditorMediaView
import RichTextEngineEditor
import TelegramCore
import UIKit

@available(iOS 18.4, *)
@MainActor
extension ClientHarnessSession {
    func runComposerScenario() async throws {
        try await ClientHarnessLocalImages.install(context: self.context)
        let host = try ClientHarnessComposerHost(context: self.context, journal: self.report.journal)
        self.navigation.pushViewController(host)
        defer { host.stop(); UIPasteboard.general.items = [] }
        try await self.driver.settle()
        let seed = self.composerContent()
        host.seed(seed)
        try await self.driver.settle(0.4)
        let node = try host.nativeNode()
        guard let editor = node.inputView as? RichTextEngineEditorView else { throw ClientHarnessFailure(description: "native InputDec editor missing") }
        try await self.driver.until("actual Composer local image") { self.composerMediaBitmapCount(host) > 0 }
        let original = node.currentInputContent().content
        try clientHarnessRequire(original == seed, "native composer lost authored structure while seeding")
        let originalDocument = editor.document
        editor.discardUndoHistory()
        try self.composerProbe("composer-rich-light", host: host)

        _ = node.makeInputFirstResponder()
        try await self.driver.settle(0.5)
        try await self.driver.until("Composer software keyboard") { (self.navigation.validLayout?.inputHeight ?? 0) > 100 }
        try self.selectComposerText("date", in: "😀 date tail", node: node)
        try await self.driver.settle(0.2)
        host.stage = "Native Date · selected body word after emoji"
        try self.composerProbe("composer-date-selected", host: host)
        try self.invokeComposerDate(host)
        guard let add = host.pendingDate else { throw ClientHarnessFailure(description: "native Format Date did not capture its request") }
        host.stage = "Date added · heading / quote / cell / media retained"
        try clientHarnessRequire(add.text.string == "date" && add.apply(1_700_000_000), "native Date add rejected the captured selection")
        try clientHarnessRequire(!add.apply(1_800_000_000), "Date completion was reusable")
        host.pendingDate = nil
        try await self.driver.settle(0.3)
        let dated = self.composerChangingBody(original, date: 1_700_000_000)
        try clientHarnessRequire(node.currentInputContent().content == dated, "CMC01 Date flattened or changed another block")
        try self.composerProbe("composer-date-added", host: host)
        self.report.journal.record("composer-native-undo", ["operation": "date-add"])
        host.stage = "Undo Date add · original rich draft"
        editor.undo(); try await self.driver.settle(0.3)
        try clientHarnessRequire(editor.document == originalDocument && !editor.currentState().canUndo, "Date add was not one structural undo")
        try self.composerProbe("composer-date-add-undone", host: host)
        host.stage = "Redo Date add · marker restored"
        editor.redo(); try await self.driver.settle(0.2)
        try self.selectComposerText("date", in: "😀 date tail", node: node)
        try await self.driver.settle(0.15)
        try self.invokeComposerDate(host)
        guard let remove = host.pendingDate else { throw ClientHarnessFailure(description: "native Date remove request missing") }
        host.stage = "Date removed · authored underline retained"
        try clientHarnessRequire(remove.apply(0), "native Date remove rejected its request")
        host.pendingDate = nil
        try await self.driver.settle(0.3)
        try clientHarnessRequire(node.currentInputContent().content == original, "Date removal damaged structure or authored underline")
        try self.composerProbe("composer-date-removed", host: host)
        host.stage = "Undo Date remove · marker restored"
        editor.undo(); try await self.driver.settle(0.3)
        try clientHarnessRequire(node.currentInputContent().content == dated, "Date remove undo did not restore the marker")
        try self.composerProbe("composer-date-remove-undone", host: host)
        editor.redo(); try await self.driver.settle(0.2)
        editor.discardUndoHistory()

        try self.selectComposerText("cell", in: "😀 cell tail", node: node)
        try await self.driver.settle(0.2)
        try clientHarnessRequire(node.selectedRange.length == 0 && node.captureRichTextSelection()?.text.string == "cell",
            "CMC06 cell selection was projected onto the flat composer axis")
        let beforeMention = editor.document
        host.stage = "Native selection stays in first table cell"
        try self.composerProbe("composer-cell-selected", host: host)
        guard let mention = host.panel.beginSelectionMention() else { throw ClientHarnessFailure(description: "native Mention completion refused the cell") }
        self.report.journal.record("composer-native-mention-completion", ["selected": "cell", "peer": ClientHarnessComposerHost.peer.id.toInt64()])
        host.stage = "Native Mention · first cell only"
        try clientHarnessRequire(mention(ClientHarnessComposerHost.peer.id) && !mention(ClientHarnessComposerHost.peer.id), "Mention completion failed or was reusable")
        try await self.driver.settle(0.3)
        let mentioned = self.composerMentioningCell(original)
        try clientHarnessRequire(node.currentInputContent().content == mentioned, "CMC06 Mention escaped the selected cell")
        try self.composerProbe("composer-cell-mentioned", host: host)
        host.stage = "Undo Mention · same cell and rich draft"
        editor.undo(); try await self.driver.settle(0.3)
        try clientHarnessRequire(editor.document == beforeMention && node.currentInputContent().content == original,
            "Mention undo did not preserve the rich document")
        try self.composerProbe("composer-cell-undone", host: host)

        try self.selectComposerText("literal: ", in: "literal: ", node: node, caretAtEnd: true)
        try await self.driver.settle(0.15)
        let beforePaste = editor.document
        let parserCalls = host.parserCalls
        let url = "https://example.test/?utm_source=code&keep=1"
        UIPasteboard.general.string = url
        self.report.journal.record("composer-native-rich-paste", ["destination": "literal-code", "text": url])
        host.stage = "Literal code paste · utm_source and keep bytes unchanged"
        node.performRichPaste()
        var pasted = original
        if case var .code(code) = pasted.blocks[5] {
            code.runs = [ChatInputRun(text: "literal: " + url)]; pasted.blocks[5] = .code(code)
        }
        try await self.driver.until("literal native paste") { node.currentInputContent().content == pasted }
        try await self.driver.settle(0.3)
        try clientHarnessRequire(host.parserCalls == parserCalls, "CMC08 literal paste entered the markdown/URL cleaner")
        try self.composerProbe("composer-code-pasted", host: host)
        host.stage = "Undo literal paste · original code restored"
        editor.undo(); try await self.driver.settle(0.3)
        try clientHarnessRequire(editor.document == beforePaste && node.currentInputContent().content == original, "literal paste undo lost structure")
        try self.composerProbe("composer-code-undone", host: host)

        self.setDark(true); host.updateAppearance()
        try self.selectComposerText("cell", in: "😀 cell tail", node: node)
        try await self.driver.settle(0.35)
        try clientHarnessRequire(node.captureRichTextSelection()?.text.string == "cell" && node.currentInputContent().content == original,
            "dark repaint moved the cell selection or replaced the draft")
        host.stage = "Dark native composer · same draft and localized selection"
        try self.composerProbe("composer-rich-dark", host: host)
        let backend = NSStringFromClass(type(of: editor))
        host.stop()
        try await self.driver.settle(0.4)
        try self.driver.back(); try await self.driver.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1 && host.panel.view.window == nil
            && self.window.findFirstResponder() == nil, "Composer retained a panel/keyboard after cleanup")
        self.report.facts["visualFamily"] = ["name": "composer-render", "realNativeRenderer": true, "cleanup": true,
            "backend": backend, "parserCallsDuringLiteralPaste": host.parserCalls - parserCalls,
            "dateTimestamp": 1_700_000_000, "literalURL": url, "appHost": "same-client-ui-app"]
        try self.probe("composer-cleanup", extra: ["attached": host.panel.view.window != nil, "firstResponder": self.window.findFirstResponder() != nil])
    }

    private func composerContent() -> ChatInputContent {
        ChatInputContent(blocks: [
            .paragraph(ChatInputParagraph(style: .heading1, runs: [ChatInputRun(text: "Heading")])),
            .paragraph(ChatInputParagraph(runs: [ChatInputRun(text: "😀 "),
                ChatInputRun(text: "date", attributes: ChatInputInlineAttributes(underline: true)),
                ChatInputRun(text: " tail", attributes: ChatInputInlineAttributes(strikethrough: true))])),
            .blockQuote(ChatInputBlockQuote(content: ChatInputContent(blocks: [.paragraph(ChatInputParagraph(runs: [ChatInputRun(text: "Quote")]))]),
                collapsed: false, author: [ChatInputRun(text: "Author")])),
            .table(ChatInputTable(columns: [ChatInputColumnSpec(width: 130), ChatInputColumnSpec(width: 90)], rows: [
                ChatInputTableRow(cells: [ChatInputTableCell(runs: [ChatInputRun(text: "😀 "),
                    ChatInputRun(text: "cell", attributes: ChatInputInlineAttributes(underline: true)), ChatInputRun(text: " tail")]),
                    ChatInputTableCell(runs: [ChatInputRun(text: "other")])])])),
            .media(ChatInputMedia(media: ClientHarnessLocalImages.image(ClientHarnessLocalImages.redId), kind: .image,
                naturalSize: ChatInputSize(width: 8, height: 8), displayWidth: 96, alignment: .left,
                caption: [ChatInputRun(text: "Local PNG caption")])),
            .code(ChatInputCode(language: "text", runs: [ChatInputRun(text: "literal: ")]))
        ])
    }

    private func composerChangingBody(_ value: ChatInputContent, date: Int32) -> ChatInputContent {
        var value = value
        if case var .paragraph(body) = value.blocks[1] {
            body.runs[1].attributes.entity = .date(date); value.blocks[1] = .paragraph(body)
        }
        return value
    }
    private func composerMentioningCell(_ value: ChatInputContent) -> ChatInputContent {
        var value = value
        if case var .table(table) = value.blocks[3] {
            table.rows[0].cells[0].runs[1].attributes.entity = .mention(ClientHarnessComposerHost.peer.id)
            value.blocks[3] = .table(table)
        }
        return value
    }

    /// Search the REAL UITextInput's own text; use its positions/ranges unchanged.
    /// No composerSelectedRange, engine internals or reconstructed offset axis.
    private func selectComposerText(_ word: String, in region: String, node: RichTextEditorChatInputNode, caretAtEnd: Bool = false) throws {
        var candidates: [(UIView, any UITextInput, NSRange)] = []
        for view in self.driver.views(in: node.inputView) {
            guard view.window === self.window, view.isFirstResponder, let input = view as? any UITextInput,
                  let full = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
                  let text = input.text(in: full) else { continue }
            let range = (text as NSString).range(of: region)
            guard range.location != NSNotFound else { continue }
            let local = (region as NSString).range(of: word)
            if local.location != NSNotFound {
                candidates.append((view, input, NSRange(location: range.location + local.location, length: local.length)))
            }
        }
        try clientHarnessRequire(candidates.count == 1, "native Composer UITextInput region missing/ambiguous: " + region)
        let (view, input, selected) = candidates[0]
        let range = caretAtEnd ? NSRange(location: NSMaxRange(selected), length: 0) : selected
        guard let start = input.position(from: input.beginningOfDocument, offset: range.location),
              let end = input.position(from: start, offset: range.length), let native = input.textRange(from: start, to: end) else {
            throw ClientHarnessFailure(description: "native Composer input rejected its own selection positions")
        }
        input.selectedTextRange = native
        try clientHarnessRequire(view.window === self.window && input.text(in: native) == (caretAtEnd ? "" : word), "native selection did not round-trip")
        self.report.journal.record("composer-uitextinput-selection", ["region": region, "text": word,
            "inputClass": NSStringFromClass(type(of: view)), "utf16": [range.location, range.length]])
    }

    private func invokeComposerDate(_ host: ClientHarnessComposerHost) throws {
        func find(_ elements: [UIMenuElement]) -> UIAction? {
            for element in elements {
                if let action = element as? UIAction, action.identifier.rawValue == "exteraless.format.date" { return action }
                if let menu = element as? UIMenu, let action = find(menu.children) { return action }
            }
            return nil
        }
        let node = try host.nativeNode()
        guard let action = find(node.contextMenuItemsProvider?([]) ?? []), !action.attributes.contains(.disabled) else {
            throw ClientHarnessFailure(description: "actual Format Date action missing/disabled")
        }
        host.pendingDate = nil
        let delivery = UIButton()
        delivery.addAction(action, for: .touchUpInside)
        delivery.sendActions(for: .touchUpInside)
    }

    private func composerMediaBitmapCount(_ host: ClientHarnessComposerHost) -> Int {
        self.driver.views(in: host.panel.view).compactMap { $0 as? MediaItemNodeView }.reduce(0) { count, media in
            count + self.driver.views(in: media).filter { view in
                view.window === self.window && view.bounds.height > 0 && view.asyncdisplaykit_node is TransformImageNode
                    && view.asyncdisplaykit_node?.contents != nil
            }.count
        }
    }

    private func composerProbe(_ name: String, host: ClientHarnessComposerHost) throws {
        let node = try host.nativeNode()
        guard let editor = node.inputView as? RichTextEngineEditorView else { throw ClientHarnessFailure(description: "native editor disappeared") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let content = node.currentInputContent().content
        let bytes = try encoder.encode(content)
        let document = try encoder.encode(editor.document)
        let selected = node.captureRichTextSelection()
        let global = editor.selectedGlobalRange()
        let panelFrame = host.panel.view.convert(host.panel.view.bounds, to: self.window)
        let editorFrame = editor.convert(editor.bounds, to: self.window)
        try self.visualProbe(name, view: host.view, extra: [
            "renderer": NSStringFromClass(type(of: node)), "backend": NSStringFromClass(type(of: editor)),
            "panelInstance": self.viewIdentities.id(host.panel.view), "editorInstance": self.viewIdentities.id(editor),
            "panelWindowFrame": [panelFrame.minX, panelFrame.minY, panelFrame.width, panelFrame.height],
            "editorWindowFrame": [editorFrame.minX, editorFrame.minY, editorFrame.width, editorFrame.height],
            "content": try JSONSerialization.jsonObject(with: bytes), "contentSHA256": clientHarnessSHA256(bytes),
            "documentSHA256": clientHarnessSHA256(document), "documentRevision": editor.documentRevision,
            "selectionRevision": editor.selectionRevision, "selectedText": selected?.text.string ?? "",
            "globalSelection": global.map { [$0.from, $0.to] } ?? [],
            "flatSelection": [node.selectedRange.location, node.selectedRange.length],
            "offset": [node.inputContentOffset.x, node.inputContentOffset.y],
            "mediaBitmaps": self.composerMediaBitmapCount(host), "parserCalls": host.parserCalls,
            "canUndo": editor.currentState().canUndo, "firstResponder": node.isInputFirstResponder,
            "selectionRect": [node.selectionRect.minX, node.selectionRect.minY, node.selectionRect.width, node.selectionRect.height]
        ])
    }
}
