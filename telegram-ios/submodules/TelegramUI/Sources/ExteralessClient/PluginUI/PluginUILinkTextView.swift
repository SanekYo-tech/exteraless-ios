import Foundation
import TelegramPresentationData
import UIKit

/// Read-only selectable native text. URLs use our own attributed key and tap
/// hit-testing so UIKit cannot open a link before the host permission/scope gate.
final class PluginUILinkTextView: UITextView {
    private static let targetKey = NSAttributedString.Key("ExteralessPluginLinkTarget")
    private let activate: (URL) -> Void
    private let tapDelegate = PluginUILinkTapDelegate()

    init(text: String, data: PresentationData, centered: Bool, activate: @escaping (URL) -> Void) throws {
        self.activate = activate
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        self.isEditable = false
        self.isSelectable = true
        self.isScrollEnabled = false
        self.backgroundColor = .clear
        self.dataDetectorTypes = []
        self.textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        self.adjustsFontForContentSizeCategory = true
        self.tintColor = data.theme.list.itemAccentColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .natural
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: pluginUIFont(data), .foregroundColor: data.theme.list.itemPrimaryTextColor, .paragraphStyle: paragraph
        ])
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var actions: [UIAccessibilityCustomAction] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).prefix(128) {
            guard let url = match.url, (try? PluginUIModel.validateURL(url.absoluteString)) != nil else { continue }
            attributed.addAttributes([Self.targetKey: url, .foregroundColor: data.theme.list.itemAccentColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            actions.append(UIAccessibilityCustomAction(name: url.absoluteString, actionHandler: { [weak self] _ in
                guard let self else { return false }
                self.activate(url)
                return true
            }))
        }
        self.attributedText = attributed
        self.accessibilityCustomActions = actions
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.linkTapped(_:)))
        tap.cancelsTouchesInView = false
        self.tapDelegate.textView = self
        tap.delegate = self.tapDelegate
        self.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func target(at point: CGPoint) -> URL? {
        guard let position = self.closestPosition(to: point), self.textStorage.length > 0 else { return nil }
        let offset = self.offset(from: self.beginningOfDocument, to: position)
        let local = CGPoint(x: point.x + self.contentOffset.x - self.textContainerInset.left,
                            y: point.y + self.contentOffset.y - self.textContainerInset.top)
        self.layoutManager.ensureLayout(for: self.textContainer)
        for index in [offset, offset - 1] where index >= 0 && index < self.textStorage.length {
            guard let url = self.textStorage.attribute(Self.targetKey, at: index, effectiveRange: nil) as? URL else { continue }
            let glyph = self.layoutManager.glyphIndexForCharacter(at: index)
            let rect = self.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: self.textContainer)
            if rect.contains(local) { return url }
        }
        return nil
    }

    @objc private func linkTapped(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended, let url = self.target(at: gesture.location(in: self)) { self.activate(url) }
    }

}

private final class PluginUILinkTapDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var textView: PluginUILinkTextView?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let textView = self.textView else { return false }
        return textView.target(at: touch.location(in: textView)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
