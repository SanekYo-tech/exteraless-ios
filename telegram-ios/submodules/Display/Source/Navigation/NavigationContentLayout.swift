import ExteralessCore
import Foundation
import UIKit

/// Explicit ownership, supplied by the application root. Auxiliary navigation
/// controllers keep the mode they were constructed with.
public enum NavigationContentLayoutRole: Equatable, Sendable {
    case unmanaged
    case applicationRoot
}

struct NavigationContentLayout {
    let mode: AppearanceLayoutModePolicy.Mode
    let viewport: AppearanceLayoutModePolicy.Viewport
    let decision: AppearanceLayoutModePolicy.Decision

    var masterWidth: CGFloat? {
        if case let .split(width) = self.decision.root { return CGFloat(width) }
        return nil
    }

    func sheetFrame(preferredSize: CGSize?) -> CGRect? {
        let value = AppearanceLayoutModePolicy.resolve(mode: self.mode, viewport: self.viewport, hasMaster: false, preferredSheetWidth: preferredSize.map { Double($0.width) }, preferredSheetHeight: preferredSize.map { Double($0.height) })
        return value.sheetFrame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }
}

func navigationContentLayout(role: NavigationContentLayoutRole, rawMode: Int, layout: ContainerViewLayout, hasMaster: Bool, hasMinimizedStack: Bool = false) -> NavigationContentLayout? {
    guard role == .applicationRoot, let mode = AppearanceLayoutModePolicy.Mode(rawValue: rawMode), mode != .automatic else { return nil }
    let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
    let verticalDivision = layout.division.flatMap { division -> CGRect? in
        guard division.width < layout.size.width, division.minY <= 0.5, division.maxY >= layout.size.height - 0.5 else { return nil }
        return division
    }
    let viewport = AppearanceLayoutModePolicy.Viewport(
        width: Double(layout.size.width), height: Double(layout.size.height),
        left: Double(max(sides.left, layout.intrinsicInsets.left)),
        top: Double(max(layout.safeInsets.top, max(layout.intrinsicInsets.top, layout.statusBarHeight ?? 0))),
        right: Double(max(sides.right, layout.intrinsicInsets.right)),
        bottom: Double(max(layout.safeInsets.bottom, layout.intrinsicInsets.bottom)),
        keyboardHeight: Double(layout.inputHeight ?? 0),
        dividerX: verticalDivision.map { Double($0.midX) }, dividerWidth: Double(verticalDivision?.width ?? 0),
        allowsSheets: layout.division == nil && !layout.presentedInFormSheet
    )
    return NavigationContentLayout(mode: mode, viewport: viewport, decision: AppearanceLayoutModePolicy.resolve(mode: mode, viewport: viewport, hasMaster: hasMaster, hasMinimizedStack: hasMinimizedStack))
}

/// Only a retained controller changing container ownership needs a handoff.
/// Ordinary pushes/pops in the same pane keep their native transition timeline.
struct NavigationContentLayoutOwners {
    private enum Owner: Equatable {
        case single, master, detail
        case modal(index: Int, flat: Bool, standalone: Bool)
    }
    private let split: Bool
    private let owners: [ObjectIdentifier: Owner]

    init(_ layout: NavigationLayout) {
        var owners: [ObjectIdentifier: Owner] = [:]
        switch layout.root {
        case let .flat(controllers):
            self.split = false
            for controller in controllers { owners[ObjectIdentifier(controller)] = .single }
        case let .split(master, detail):
            self.split = true
            for controller in master { owners[ObjectIdentifier(controller)] = .master }
            for controller in detail { owners[ObjectIdentifier(controller)] = .detail }
        }
        for (index, modal) in layout.modal.enumerated() {
            for controller in modal.controllers { owners[ObjectIdentifier(controller)] = .modal(index: index, flat: modal.isFlat, standalone: modal.isStandalone) }
        }
        self.owners = owners
    }

    func needsHandoff(from previous: NavigationContentLayoutOwners) -> Bool {
        if self.split != previous.split { return true }
        return self.owners.contains { id, owner in previous.owners[id].map { $0 != owner } ?? false }
    }

    func contains(_ controller: ViewController) -> Bool {
        return self.owners[ObjectIdentifier(controller)] != nil
    }
}

/// A handoff preserves the actual responder, not an invented keyboard flag.
/// Offsets refer to the same UITextInput document; no text is copied or changed.
final class NavigationContentLayoutInputState {
    enum Restoration {
        case waiting, restored, superseded
    }

    weak var controller: ViewController?
    private weak var responder: UIView?
    private weak var window: UIWindow?
    private let selection: NSRange?
    private let documentLength: Int?

    init?(rootView: UIView, controllers: [ViewController]) {
        guard let responder = getFirstResponderAndAccessoryHeight(rootView).0,
              let controller = controllers.first(where: { $0.isViewLoaded && responder.isDescendant(of: $0.view) }) else { return nil }
        self.controller = controller
        self.responder = responder
        self.window = responder.window
        if let input = responder as? UITextInput, let range = input.selectedTextRange {
            let start = input.offset(from: input.beginningOfDocument, to: range.start)
            let end = input.offset(from: input.beginningOfDocument, to: range.end)
            self.selection = start >= 0 && end >= start ? NSRange(location: start, length: end - start) : nil
            self.documentLength = input.offset(from: input.beginningOfDocument, to: input.endOfDocument)
        } else {
            self.selection = nil
            self.documentLength = nil
        }
    }

    func belongs(to controller: ViewController) -> Bool { self.controller === controller }

    func restore(in rootView: UIView) -> Restoration {
        guard let controller = self.controller, let responder = self.responder else { return .superseded }
        guard controller.isInFocus, responder.isDescendant(of: rootView), let window = responder.window else { return .waiting }
        guard window === self.window else { return .superseded }
        if let current = getFirstResponderAndAccessoryHeight(rootView).0, current !== responder {
            return .superseded
        }
        if !responder.isFirstResponder && !responder.becomeFirstResponder() { return .waiting }
        if let input = responder as? UITextInput, let selection = self.selection,
           self.documentLength == input.offset(from: input.beginningOfDocument, to: input.endOfDocument),
           let start = input.position(from: input.beginningOfDocument, offset: selection.location),
           let end = input.position(from: start, offset: selection.length), let range = input.textRange(from: start, to: end) {
            input.selectedTextRange = range
        }
        return .restored
    }
}

/// Taken once by a new container and retained by its pending child until ready.
/// It supplies an adoption contract, never a cached size or keyboard height.
final class NavigationContentLayoutAdoption {
    private weak var navigation: NavigationController?
    private weak var controller: ViewController?
    let generation: UInt64
    let preservesInputFocus: Bool

    init(navigation: NavigationController, controller: ViewController, generation: UInt64, preservesInputFocus: Bool) {
        self.navigation = navigation
        self.controller = controller
        self.generation = generation
        self.preservesInputFocus = preservesInputFocus
    }

    var isCurrent: Bool {
        guard let navigation = self.navigation, let controller = self.controller else { return false }
        return navigation.isCurrentContentLayoutAdoption(self, controller: controller)
    }

    func didAttach() {
        guard self.isCurrent else { return }
        self.navigation?.contentLayoutAdoptionDidAttach(self)
    }
}
