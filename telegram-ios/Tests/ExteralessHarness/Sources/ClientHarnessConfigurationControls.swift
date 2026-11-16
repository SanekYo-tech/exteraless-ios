import AccountContext
import ExteralessCore
import Foundation
import RichTextEngineEditor
import TelegramCore
import UIKit

/// Observes the production UIButton/UILabel after layout. It never draws a
/// replacement control or manufactures geometry for a missing native view.
@MainActor
private func configurationControl(_ root: UIView, window: UIWindow, identifier: String,
                                  leading: CGFloat, trailing: CGFloat, wrapping: Bool) throws -> [String: Any] {
    var matches: [UIButton] = []
    func visit(_ view: UIView) {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { matches.append(button) }
        for child in view.subviews { visit(child) }
    }
    visit(root)
    guard matches.count == 1, let button = matches.first, button.window === window,
          !button.isHidden, button.alpha > 0.99, let label = button.titleLabel,
          let configuration = button.configuration, let title = configuration.title, !title.isEmpty else {
        throw ClientHarnessFailure(description: "actual configured control missing: " + identifier)
    }
    let frame = button.convert(button.bounds, to: window)
    let text = label.convert(label.bounds, to: window)
    let attributes = label.attributedText.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil }
    let font = attributes ?? label.font!
    let renderedText = label.attributedText?.string ?? label.text ?? ""
    try clientHarnessRequire(renderedText == title, "native configured title is absent from its UILabel: " + identifier)
    try clientHarnessRequire(frame.width > 0 && frame.height >= 44 && text.width > 0 && text.height > 0
        && window.bounds.contains(frame) && frame.insetBy(dx: -0.5, dy: -0.5).contains(text), "configured button/text is clipped: " + identifier)
    try clientHarnessRequire(configuration.contentInsets.leading == leading && configuration.contentInsets.trailing == trailing,
        "native button insets differ: " + identifier)
    try clientHarnessRequire(configuration.titleLineBreakMode == (wrapping ? .byWordWrapping : .byTruncatingTail),
        "native configured line-break mode differs: " + identifier)
    if wrapping {
        let fitted = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        try clientHarnessRequire(fitted.height <= label.bounds.height + 1, "inline calculation title was clipped vertically")
    }
    return ["id": identifier, "nativeClass": NSStringFromClass(type(of: button)), "title": title,
            "label": renderedText, "buttonFrame": [frame.minX, frame.minY, frame.width, frame.height],
            "labelFrame": [text.minX, text.minY, text.width, text.height],
            "insets": [configuration.contentInsets.top, leading, configuration.contentInsets.bottom, trailing],
            "font": font.fontName, "pointSize": font.pointSize, "lines": label.numberOfLines,
            "lineBreak": configuration.titleLineBreakMode.rawValue, "inWindow": true]
}

@MainActor
extension ClientHarnessSession {
    func pillConfigurationProbe(_ name: String, pills: ClientHarnessPills) throws {
        var fields = pills.snapshot
        fields["configurationControl"] = try configurationControl(pills.header.view, window: self.window,
            identifier: "exteraless.pill.current", leading: 38, trailing: 16, wrapping: false)
        try self.visualProbe(name, view: pills.header.view, extra: fields)
    }

    /// Two short actual-control frames before the existing rich-document segment.
    /// Numeric arithmetic never enters the currency/network suggestion branch.
    @available(iOS 18.4, *)
    func runInlineMathConfigurationSegment(host: ClientHarnessComposerHost) async throws {
        try clientHarnessRequire(ClientSettings.shared.bool("chats.inlineMathResult", default: true), "inline math fixture requires its published default")
        let node = try host.nativeNode()
        guard let editor = node.inputView as? RichTextEngineEditorView else {
            throw ClientHarnessFailure(description: "native inline calculation editor missing")
        }
        let text = "1 + 2"
        let content = ChatInputContent(blocks: [.paragraph(ChatInputParagraph(runs: [ChatInputRun(text: text)]))])
        _ = node.makeInputFirstResponder()
        host.applyInput { _, mode in
            let end = text.utf16.count
            return (ChatTextInputState(content: content, selectionRange: end ..< end), mode)
        }
        defer {
            _ = node.resignInputFirstResponder()
            host.seed(ChatInputContent())
            self.setDark(false)
            host.updateAppearance()
        }
        for (palette, dark) in [("light", false), ("dark", true)] {
            self.setDark(dark)
            host.updateAppearance()
            try await self.driver.settle(0.25)
            try await self.driver.until("actual inline calculation control", timeout: 1) {
                self.driver.views(in: host.panel.view).contains { $0.accessibilityIdentifier == "exteraless.inlineMath.insert" && $0.window === self.window }
            }
            let control = try configurationControl(host.panel.view, window: self.window,
                identifier: "exteraless.inlineMath.insert", leading: 14, trailing: 14, wrapping: true)
            try clientHarnessRequire(control["title"] as? String == "= 3  ·  Insert", "calculation control did not use the native result")
            let bytes = try JSONEncoder().encode(editor.document)
            try self.visualProbe("composer-inline-math-" + palette, view: host.view, extra: [
                "configurationControl": control, "expression": text,
                "renderer": NSStringFromClass(type(of: node)), "backend": NSStringFromClass(type(of: editor)),
                "panelInstance": self.viewIdentities.id(host.panel.view), "editorInstance": self.viewIdentities.id(editor),
                "documentSHA256": clientHarnessSHA256(bytes)])
        }
    }
}
