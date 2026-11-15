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
}
