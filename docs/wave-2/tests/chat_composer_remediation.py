"""CMC-01/06/07/08 source wiring checks. This is NOT a Swift/XCTest execution."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / "telegram-ios"
CHAT = IOS / "submodules/TelegramUI/Components/Chat"
EDITOR = IOS / "submodules/TelegramUI/Components/RichTextEditor"


def read(path):
    return path.read_text(encoding="utf-8")


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def main():
    panel = read(CHAT / "ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift")
    node = read(CHAT / "ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift")
    load = read(IOS / "submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift")
    date = between(load, "}, openDateEditing:", "}, displaySlowmodeTooltip:")
    assert date.index("beginNativeDateEditing()") < date.index("ChatScheduleTimeScreen(")
    native = between(date, "if let nativeEdit {", "guard let self, let inputMode = inputMode")
    assert "nativeEdit.apply(result.time)" in native
    assert "self.chatDisplayNode.textInputPanelNode === inputPanel" in native
    assert "ChatTextInputState(" not in native and "selectionRange.endIndex" not in native
    assert "dateMarkdownURL(timestamp: timestamp), to: selection" in panel

    translation = between(panel, "@objc public func _translate(", "private func selectionActionScope")
    assert "beginSelectionTranslation()" in translation
    assert "presentInputTextTranslation(request.text, request.apply)" in translation
    native_translation = between(panel, "public func beginSelectionTranslation()", "let expected = self.inputTextState")
    assert "captureRichTextSelection()" in native_translation
    assert "replaceRichTextSelection(selection, with: text)" in native_translation
    assert "node.canReplaceRichTextSelection" in native_translation
    assert "selectedRange.length" not in native_translation
    mention = between(panel, "private func exteralessCreateMention()", "public func beginSelectionMention()")
    assert mention.index("beginSelectionMention()") < mention.index("makePeerSelectionController(")
    assert "_ = apply(peer.id)" in mention
    for seam in ("selectedGlobalRange()", "DocumentTree.build(from: document)",
                 "document.runs(for: ref)", "selection.owner == ObjectIdentifier(self)",
                 "selection.documentRevision == self.editorView.documentRevision",
                 "selection.selectionRevision == self.editorView.selectionRevision",
                 "selection.consumed = true", "self.editorView.replaceRange("):
        assert seam in node, seam
    assert "Self.canReplaceTextRange(selection.range, in: selection.document)" in node
    fragment = read(EDITOR / "Sources/RichTextEditorCore/Model/DocumentFragment.swift")
    media_copy = between(fragment, "return .media(MediaBlock(id: .generate(), items: m.items,", "case .buttonRow")
    assert "displayMode: m.displayMode" in media_copy

    captions = read(IOS / "submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift")
    assert captions.count("exteralessComposerCaption(caption)") == 6
    assert "convertMarkdownToAttributes(caption" not in captions
    forward = read(IOS / "submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift")
    assert "for (text, entities) in exteralessComposerForwardComment(messageText)" in forward
    assert "convertMarkdownToAttributes(messageText)" not in forward
    markdown = read(IOS / "submodules/TextFormat/Sources/ExteralessComposerMarkdown.swift")
    assert "respectDisableMarkdown: Bool = true" in markdown
    assert markdown.count("respectDisableMarkdown: false") == 2
    assert "attributes[ChatTextInputAttributes.date] != nil" in markdown

    clipboard = read(EDITOR / "Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift")
    transformed = between(clipboard, "internal func pasteTransformedPlainText(", "let rich =")
    assert transformed.index("!isLiteralTextDestination(engineSelectedRange)") < transformed.index("transformer(text)")
    canvas = read(EDITOR / "Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView+Clipboard.swift")
    paste = between(canvas, "@objc func legacyPaste(", "private func pasteboardHasRichTextRepresentation")
    assert paste.index("!isLiteralPasteDestination") < paste.index("transformer(s)")
    assert "self.documentRevision == revision" in canvas
    legacy = between(panel, "public func chatInputTextNodeShouldPaste()", "private final func applyPastedAttributedString")
    assert legacy.index("textView.isLiteralTextDestination") < legacy.index("pastedMarkdownParser?")
    assert legacy.index("textView.isLiteralTextDestination") < legacy.index("exteralessCleanPastedPlainText")
    helpers = read(CHAT / "ChatTextInputPanelNode/Sources/ExteralessChatInputHelpers.swift")
    producer = between(helpers, "public func exteralessComposerPasteFragment(", "private func exteralessCleanPastedProse")
    assert producer.index("parseMarkdown(text)") < producer.index("exteralessCleanPastedPlainText(text")
    assert "case .code, .buttonRow: return block" in helpers
    assert "a.inlineCode || a.link != nil" in helpers
    assert "self.pastedMarkdownParser?(context, cleaned)" not in panel

    # The fixture forwards the full interface initializer in its declaration order, changing only
    # presentation endpoints. This checks source drift, not Swift overload/actor/type checking.
    interaction = read(IOS / "submodules/ChatPresentationInterfaceState/Sources/ChatPanelInterfaceInteraction.swift")
    signature = between(interaction, "    public init(\n        setupReplyMessage:", "    ) {")
    names = ["setupReplyMessage"] + re.findall(r"^        (\w+):", signature, re.M)
    fixture = read(IOS / "Tests/ComposerHarness/Tests/ComposerSelectionActionFixture.swift")
    actual = between(fixture, "    return ChatPanelInterfaceInteraction(\n", "    )")
    assert names == re.findall(r"^        (\w+):", actual, re.M)

    print("PASS: owned CMC-01/06/07/08 source wiring (not Swift/XCTest)")
    edit = re.search(r"let text = trimChatInputText\(exteralessComposerMarkdown\([^\n]+", load)
    edit_applied = edit is not None and "respectDisableMarkdown: false" in edit.group()
    print("Edit owner handoff: " + ("APPLIED" if edit_applied else "PENDING respectDisableMarkdown: false; see remediation.md"))


if __name__ == "__main__":
    main()
