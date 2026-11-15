import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import TelegramPresentationData
import UIKit

/// Containment only. The child comes from the domain owner's real UIKit factory;
/// no pixels, rows, animation curves or provider results are generated here.
@MainActor
final class ClientHarnessDomainHost: ViewController {
    let child: UIViewController
    init(context: AccountContext, title: String, child: UIViewController) {
        self.child = child
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = title
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.addChild(self.child)
        self.displayNode.view.addSubview(self.child.view)
        self.child.didMove(toParent: self)
        self.displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = max(layout.safeInsets.top, self.navigationLayout(layout: layout).navigationFrame.maxY)
        let sides = layout.sideInsets(forBandFrom: top, to: layout.size.height)
        transition.updateFrame(view: self.child.view, frame: CGRect(x: sides.left, y: top,
            width: max(0, layout.size.width - sides.left - sides.right),
            height: max(0, layout.size.height - top - max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom))))
    }
}

@MainActor
extension ClientHarnessSession {
    func nativeTable(_ identifier: String, in root: UIView? = nil) throws -> UITableView {
        guard let table = self.driver.views(in: root).compactMap({ $0 as? UITableView }).first(where: {
            $0.accessibilityIdentifier == identifier && $0.window === self.window
        }) else { throw ClientHarnessFailure(description: "actual native table missing: " + identifier) }
        return table
    }

    func tableEvidence(_ table: UITableView) -> [String: Any] {
        table.layoutIfNeeded()
        let cells = table.visibleCells.map { cell -> [String: Any] in
            var result: [String: Any] = ["id": cell.accessibilityIdentifier ?? "", "instance": self.viewIdentities.id(cell),
                "class": NSStringFromClass(type(of: cell)), "height": cell.bounds.height,
                "subviews": self.driver.views(in: cell).prefix(96).map { view -> [String: Any] in
                    ["instance": self.viewIdentities.id(view), "class": NSStringFromClass(type(of: view)),
                     "nodeClass": view.asyncdisplaykit_node.map { NSStringFromClass(type(of: $0)) } ?? ""]
                }]
            if table.accessibilityIdentifier == "exteraless.player.lyrics.lines", let label = cell.textLabel, let text = label.attributedText {
                result["text"] = text.string
                var colors: [[String: Any]] = []
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    if let color = value as? UIColor { colors.append(["range": [range.location, range.length], "rgba": clientHarnessRGBA(color, traits: label.traitCollection)]) }
                }
                result["colors"] = colors
            }
            return result
        }
        return ["rows": (0 ..< table.numberOfSections).reduce(0) { $0 + table.numberOfRows(inSection: $1) },
            "offset": [table.contentOffset.x, table.contentOffset.y], "contentHeight": table.contentSize.height,
            "cells": cells]
    }

    func manualScroll(_ table: UITableView, offset: CGFloat) async throws {
        self.report.journal.record("native-scroll", ["id": table.accessibilityIdentifier ?? "", "offset": offset])
        table.delegate?.scrollViewWillBeginDragging?(table)
        let maximum = max(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(-table.adjustedContentInset.top, offset))), animated: true)
        try await self.driver.settle(0.4)
    }
}

func clientHarnessRGBA(_ color: UIColor, traits: UITraitCollection) -> [CGFloat] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return [] }
    return [red, green, blue, alpha]
}
