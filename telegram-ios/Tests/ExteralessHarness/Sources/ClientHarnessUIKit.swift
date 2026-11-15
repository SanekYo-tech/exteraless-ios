import Display
import Foundation
import UIKit

/// Acts on the controls that are on screen. No renderer/model methods are
/// called here. This is deliberately labelled scripted UIKit, not XCUITest/HID.
@MainActor
final class ClientHarnessUIKit {
    let window: UIWindow
    let navigation: NavigationController
    private let journal: ClientHarnessJournal

    init(window: UIWindow, navigation: NavigationController, journal: ClientHarnessJournal) {
        self.window = window
        self.navigation = navigation
        self.journal = journal
    }

    func settle(_ seconds: Double = 0.65) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        self.window.layoutIfNeeded()
    }

    func until(_ name: String, timeout: Double = 1.5, _ predicate: () throws -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while try !predicate() {
            try clientHarnessRequire(ProcessInfo.processInfo.systemUptime < end, "timed out: " + name)
            try await self.settle(0.05)
        }
    }

    func visible(_ view: UIView) -> Bool {
        guard view.window === self.window, !view.bounds.isEmpty else { return false }
        var ancestor: UIView? = view
        var rect = view.convert(view.bounds, to: self.window)
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.02 { return false }
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: self.window)) }
            ancestor = current.superview
        }
        return !rect.isNull && !rect.intersection(self.window.bounds).isEmpty
    }

    func views(in root: UIView? = nil) -> [UIView] {
        var result: [UIView] = []
        func visit(_ view: UIView, depth: Int) {
            guard depth <= 32, result.count < 2048 else { return }
            result.append(view)
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(root ?? self.window, depth: 0)
        return result
    }

    private func matches(_ view: UIView, _ name: String) -> Bool {
        if view.accessibilityIdentifier == name || view.accessibilityLabel == name { return true }
        if view.accessibilityLabel?.components(separatedBy: "\n").first == name { return true }
        if (view as? UILabel)?.text == name { return true }
        if (view as? UIButton)?.title(for: .normal) == name { return true }
        return false
    }

    func control<T: UIControl>(_ name: String, as type: T.Type) throws -> T {
        guard let result = self.views().compactMap({ $0 as? T }).first(where: { self.visible($0) && self.matches($0, name) }) else {
            throw ClientHarnessFailure(description: "visible \(type) missing: " + name)
        }
        try clientHarnessRequire(result.isEnabled, "control is disabled: " + name)
        try self.requireHit(result, name: name)
        return result
    }

    private func requireHit(_ view: UIView, name: String) throws {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: self.window)
        guard let hit = self.window.hitTest(point, with: nil), hit === view || hit.isDescendant(of: view) else {
            throw ClientHarnessFailure(description: "control center is clipped or covered: " + name)
        }
    }

    func press(_ name: String) throws {
        let control = try self.control(name, as: UIControl.self)
        try clientHarnessRequire(!control.allTargets.isEmpty, "control has no target/action: " + name)
        self.journal.record("control-action", ["name": name, "delivery": "UIControl.touchUpInside"])
        control.sendActions(for: .touchUpInside)
    }

    func toggle(_ name: String, to value: Bool) throws {
        let control = try self.control(name, as: UISwitch.self)
        try clientHarnessRequire(control.isOn != value, "switch precondition already equals candidate: " + name)
        self.journal.record("control-action", ["name": name, "delivery": "UISwitch.valueChanged", "value": value])
        control.setOn(value, animated: true)
        control.sendActions(for: .valueChanged)
    }

    func slider(_ name: String, fraction: Float) throws {
        let control = try self.control(name, as: UISlider.self)
        self.journal.record("control-action", ["name": name, "delivery": "UISlider.valueChanged/touchUpInside", "fraction": fraction])
        control.setValue(fraction, animated: true)
        control.sendActions(for: .valueChanged)
        control.sendActions(for: .touchUpInside)
    }

    func row(_ name: String) async throws {
        guard let top = self.navigation.topViewController,
              let table = self.views(in: top.view).compactMap({ $0 as? UITableView }).first else {
            throw ClientHarnessFailure(description: "current production controller has no UITableView")
        }
        for attempt in 0 ..< 5 {
            table.layoutIfNeeded()
            if let cell = table.visibleCells.first(where: { cell in
                self.visible(cell) && self.views(in: cell).contains(where: { self.matches($0, name) })
            }), let path = table.indexPath(for: cell) {
                try self.requireHit(cell, name: name)
                // UITableView's real selection delegate invokes the production row
                // action. Never manufacture cells by calling its data source.
                self.journal.record("row-action", ["name": name, "section": path.section, "row": path.row,
                    "delivery": "UITableView.didSelectRowAt"])
                table.selectRow(at: path, animated: false, scrollPosition: .none)
                table.delegate?.tableView?(table, didSelectRowAt: path)
                return
            }
            guard attempt < 4 else { break }
            let maximum = max(-table.contentInset.top, table.contentSize.height - table.bounds.height + table.contentInset.bottom)
            let next = min(maximum, table.contentOffset.y + table.bounds.height * 0.55)
            try clientHarnessRequire(next > table.contentOffset.y + 1, "row missing at bottom: " + name)
            table.setContentOffset(CGPoint(x: 0, y: next), animated: true)
            try await self.settle(0.3)
        }
        throw ClientHarnessFailure(description: "row not found within bounded scroll: " + name)
    }

    func input(_ name: String) throws -> UIView & UITextInput {
        guard let input = self.views().first(where: {
            self.visible($0) && ($0 is UITextField || $0 is UITextView) && self.matches($0, name)
        }) as? (UIView & UITextInput) else {
            throw ClientHarnessFailure(description: "visible text input missing: " + name)
        }
        try self.requireHit(input, name: name)
        return input
    }

    func enter(_ name: String, text: String) async throws {
        let input = try self.input(name)
        self.journal.record("text-input", ["name": name, "delivery": "becomeFirstResponder + UITextInput.insertText"])
        try clientHarnessRequire(input.becomeFirstResponder(), "input refused first responder: " + name)
        try await self.settle(0.4)
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        input.insertText(text)
        try await self.settle(0.2)
        try clientHarnessRequire(input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!) == text,
            "UITextInput did not contain entered fixture text")
    }

    func rightButton() throws {
        guard let item = self.navigation.topViewController?.navigationItem.rightBarButtonItem,
              item.isEnabled, let selector = item.action, let target = item.target else {
            throw ClientHarnessFailure(description: "visible navigation action is unavailable")
        }
        self.journal.record("navigation-action", ["name": item.title ?? item.accessibilityLabel ?? "<system>"])
        try clientHarnessRequire(UIApplication.shared.sendAction(selector, to: target, from: item, for: nil),
            "navigation action was not delivered")
    }

    func back() throws {
        try clientHarnessRequire(self.navigation.viewControllers.count > 1, "no native screen to go back from")
        self.journal.record("navigation-back", ["delivery": "Display.NavigationController accessibility escape"])
        try clientHarnessRequire(self.navigation.displayNode.accessibilityPerformEscape(), "Display back action was rejected")
    }

    func hasText(_ text: String) -> Bool {
        self.views().contains { self.visible($0) && self.matches($0, text) }
    }

    func snapshot() -> [String: Any] {
        let views = self.views().filter(self.visible)
        let observed = views.filter { $0 is UILabel || $0 is UIControl || $0 is UITextView || $0 is UITableViewCell }
        let elements: [[String: Any]] = observed.prefix(160).map { view in
            let frame = view.convert(view.bounds, to: self.window)
            var value: [String: Any] = ["class": NSStringFromClass(type(of: view)),
                "frame": [frame.minX, frame.minY, frame.width, frame.height],
                "id": view.accessibilityIdentifier as Any? ?? NSNull(), "firstResponder": view.isFirstResponder]
            if let label = view as? UILabel {
                value["text"] = String((label.text ?? "").prefix(240))
                value["fontSize"] = label.font.pointSize
                value["lines"] = label.numberOfLines
                value["rgba"] = clientHarnessRGBA(label.textColor, traits: label.traitCollection)
            } else if let input = view as? UITextField {
                value["text"] = input.isSecureTextEntry ? "<secure>" : String((input.text ?? "").prefix(240))
            } else if let input = view as? UITextView { value["text"] = String(input.text.prefix(240)) }
            if let control = view as? UIControl { value["enabled"] = control.isEnabled }
            if let toggle = view as? UISwitch { value["isOn"] = toggle.isOn }
            if let slider = view as? UISlider { value["value"] = slider.value }
            return value
        }
        return ["controllers": self.navigation.viewControllers.map { ["class": NSStringFromClass(type(of: $0)), "title": $0.title ?? ""] },
            "screenPoints": [self.window.bounds.width, self.window.bounds.height], "scale": self.window.screen.scale,
            "inputHeight": self.navigation.validLayout?.inputHeight as Any? ?? NSNull(),
            "elements": elements, "truncated": observed.count > 160]
    }
}
