import AsyncDisplayKit
import ExteralessCore
import SwiftSignalKit
import UIKit
import XCTest
@testable import Display

private class LayoutModeController: ViewController {
    let readiness: Promise<Bool>
    var layouts: [ContainerViewLayout] = []
    var draft = "retained local editor state"
    var preferredSize: CGSize?

    init(master: Bool = false, ready: Bool = true) {
        self.readiness = Promise(ready)
        super.init(navigationBarPresentationData: nil)
        if master { self.navigationPresentation = .master }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var ready: Promise<Bool> { self.readiness }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.layouts.append(layout)
        super.containerLayoutUpdated(layout, transition: transition)
    }
    override func preferredContentSizeForLayout(_ layout: ContainerViewLayout) -> CGSize? { self.preferredSize }
}

private final class LayoutModeTextInputController: LayoutModeController {
    enum Kind: CaseIterable { case field, view }

    let editor: UIView & UITextInput
    let keyboard = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
    var resignInputOnNextLayout = false

    init(kind: Kind, ready: Bool = true) {
        switch kind {
        case .field:
            let field = UITextField()
            field.text = "retained editing selection"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            self.editor = field
        case .view:
            let view = UITextView()
            view.text = "retained editing selection"
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            self.editor = view
        }
        super.init(ready: ready)
        if let field = self.editor as? UITextField { field.inputView = self.keyboard }
        if let view = self.editor as? UITextView { view.inputView = self.keyboard }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.displayNode.view.addSubview(self.editor)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.editor.frame = CGRect(x: 20, y: (layout.statusBarHeight ?? 0) + 24, width: max(44, layout.size.width - 40), height: self.editor is UITextView ? 96 : 44)
        if self.resignInputOnNextLayout {
            self.resignInputOnNextLayout = false
            let _ = self.editor.resignFirstResponder()
        }
    }

    func select(_ selection: NSRange) throws {
        let start = try XCTUnwrap(self.editor.position(from: self.editor.beginningOfDocument, offset: selection.location))
        let end = try XCTUnwrap(self.editor.position(from: start, offset: selection.length))
        self.editor.selectedTextRange = try XCTUnwrap(self.editor.textRange(from: start, to: end))
    }

    func selection() throws -> NSRange {
        let range = try XCTUnwrap(self.editor.selectedTextRange)
        let start = self.editor.offset(from: self.editor.beginningOfDocument, to: range.start)
        let end = self.editor.offset(from: self.editor.beginningOfDocument, to: range.end)
        return NSRange(location: start, length: end - start)
    }
}

@MainActor
private final class LayoutModeInputFixture {
    let window: UIWindow
    let navigation: NavigationController
    let master = LayoutModeController(master: true)
    let input: LayoutModeTextInputController
    private weak var previousKeyWindow: UIWindow?

    init(kind: LayoutModeTextInputController.Kind, theme: NavigationControllerTheme) throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        self.previousKeyWindow = scene?.windows.first(where: { $0.isKeyWindow })
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        }
        self.window = window
        self.navigation = NavigationController(mode: .automaticMasterDetail, theme: theme, contentLayoutRole: .applicationRoot)
        self.input = LayoutModeTextInputController(kind: kind)
        var initialized = false
        defer { if !initialized { self.tearDown() } }
        self.navigation.setViewControllers([self.master, self.input], animated: false)
        self.window.rootViewController = self.navigation
        self.window.makeKeyAndVisible()
        self.window.layoutIfNeeded()
        self.navigation.view.frame = self.window.bounds
        self.navigation.containerLayoutUpdated(self.physicalLayout(keyboard: nil), transition: .immediate)
        XCTAssertTrue(self.input.editor.becomeFirstResponder(), "fixture needs a real UIKit responder")
        XCTAssertEqual(self.input.keyboard.bounds.height, 500)
        // Establish the pre-handoff physical keyboard layout on the already
        // presented child. No layout call is made to repair a mode switch in tests.
        self.navigation.containerLayoutUpdated(self.physicalLayout(), transition: .immediate)
        try self.input.select(NSRange(location: 3, length: 8))
        XCTAssertEqual(self.input.layouts.last?.inputHeight, 500)
        initialized = true
    }

    func physicalLayout(keyboard: CGFloat? = 500) -> ContainerViewLayout {
        // Regular is the tested native layout input. UIWindow bounds and scene
        // orientation are read from this fixture's real window; traits/device
        // idiom and the keyboard-handling flags are never overridden.
        let size = self.window.bounds.size
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: .regular, heightClass: .regular, orientation: self.window.windowScene?.interfaceOrientation, windowSize: size), deviceMetrics: .iPhoneDuo, intrinsicInsets: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0), safeInsets: UIEdgeInsets(top: 24, left: 20, bottom: 20, right: 32), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: 24, inputHeight: keyboard, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }

    func tearDown() {
        let _ = self.input.editor.resignFirstResponder()
        self.window.isHidden = true
        self.window.rootViewController = nil
        self.previousKeyWindow?.makeKey()
    }
}

@MainActor
final class AppearanceLayoutModeTests: XCTestCase {
    private func layout(_ size: CGSize, regular: Bool, keyboard: CGFloat? = nil) -> ContainerViewLayout {
        ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: regular ? .regular : .compact, heightClass: .regular, orientation: .landscapeLeft, windowSize: size), deviceMetrics: .iPhoneDuo, intrinsicInsets: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0), safeInsets: UIEdgeInsets(top: 24, left: 20, bottom: 20, right: 32), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: 24, inputHeight: keyboard, inputHeightIsInteractivellyChanging: keyboard != nil, inVoiceOver: false, presentedInFormSheet: false)
    }

    private func theme() -> NavigationControllerTheme {
        let bar = NavigationBarTheme(overallDarkAppearance: false, buttonColor: .blue, disabledButtonColor: .gray, primaryTextColor: .black, badgeBackgroundColor: .red, badgeTextColor: .white, accentButtonColor: .blue, accentDisabledButtonColor: .gray, accentForegroundColor: .white)
        return NavigationControllerTheme(statusBar: .black, navigationBar: bar, emptyAreaColor: .white, separatorColor: .gray, opaqueBackgroundColor: .white)
    }

    private func plan(_ mode: Int, layout: ContainerViewLayout, controllers: [ViewController]) -> NavigationLayout {
        let content = navigationContentLayout(role: .applicationRoot, rawMode: mode, layout: layout, hasMaster: controllers.contains { if case .master = $0.navigationPresentation { return true }; return false })
        return makeNavigationLayout(mode: .automaticMasterDetail, layout: layout, controllers: controllers, contentLayout: content)
    }

    @MainActor
    func testActualMakerKeepsAutomaticAndScopesOverridesToRoot() throws {
        let master = LayoutModeController(master: true)
        let chat = LayoutModeController()
        let sheet = LayoutModeController()
        sheet.navigationPresentation = .modalInLargeLayout
        let nextChat = LayoutModeController()
        for regular in [false, true] {
            let source = layout(CGSize(width: 1024, height: 1366), regular: regular)
            XCTAssertNil(navigationContentLayout(role: .applicationRoot, rawMode: 0, layout: source, hasMaster: true))
            XCTAssertNil(navigationContentLayout(role: .unmanaged, rawMode: 1, layout: source, hasMaster: true))
            let stock = makeNavigationLayout(mode: .automaticMasterDetail, layout: source, controllers: [master, chat, sheet])
            let automatic = plan(0, layout: source, controllers: [master, chat, sheet])
            XCTAssertFalse(NavigationContentLayoutOwners(automatic).needsHandoff(from: NavigationContentLayoutOwners(stock)))
            XCTAssertEqual(automatic.modal.count, regular ? 1 : 0)
            if case .split = automatic.root { XCTAssertTrue(regular) } else { XCTAssertFalse(regular) }
            let phone = plan(2, layout: source, controllers: [master, chat, sheet])
            guard case let .flat(items) = phone.root else { return XCTFail("phone must be single even with regular system metrics") }
            XCTAssertEqual(items.map(ObjectIdentifier.init), [master, chat, sheet].map(ObjectIdentifier.init))
            XCTAssertTrue(phone.modal.isEmpty)
            let pushed = plan(2, layout: source, controllers: [master, chat, sheet, nextChat])
            XCTAssertFalse(NavigationContentLayoutOwners(pushed).needsHandoff(from: NavigationContentLayoutOwners(phone)), "an ordinary push must retain its native container/timeline")
            XCTAssertEqual(source.metrics.windowSize, source.size)
            XCTAssertEqual(source.metrics.orientation, .landscapeLeft)
        }
        let auxiliary = NavigationController(mode: .single, theme: theme())
        XCTAssertFalse(auxiliary.updateContentLayoutMode(1))
        XCTAssertEqual(auxiliary.contentLayoutMode, 0)
    }

    @MainActor
    func testActualMakerHandlesCompactLandscapeSplitWindowAndKeyboard() {
        let master = LayoutModeController(master: true)
        let chat = LayoutModeController()
        let sheet = LayoutModeController()
        sheet.navigationPresentation = .modalInLargeLayout
        for (size, keyboard, split) in [
            (CGSize(width: 390, height: 844), CGFloat(0), false),
            (CGSize(width: 844, height: 390), CGFloat(0), true),
            (CGSize(width: 620, height: 1024), CGFloat(0), false),
            (CGSize(width: 1024, height: 1366), CGFloat(500), true),
            (CGSize(width: 844, height: 390), CGFloat(240), false)
        ] {
            let source = layout(size, regular: false, keyboard: keyboard)
            let result = plan(1, layout: source, controllers: [master, chat, sheet])
            if case let .split(masters, details) = result.root {
                XCTAssertTrue(split)
                XCTAssertTrue(masters.first === master)
                XCTAssertTrue(details.first === chat)
            } else { XCTAssertFalse(split) }
            let phone = plan(2, layout: source, controllers: [master, chat])
            guard case let .flat(items) = phone.root else { return XCTFail("phone root") }
            XCTAssertTrue(items.last === chat)
        }
    }

    @MainActor
    func testLiveRecompositionRetainsControllersDraftBackStackAndLayoutMetadata() throws {
        let navigation = NavigationController(mode: .automaticMasterDetail, theme: theme(), contentLayoutRole: .applicationRoot)
        let master = LayoutModeController(master: true)
        let chat = LayoutModeController()
        let details = LayoutModeController()
        navigation.setViewControllers([master, chat, details], animated: false)
        let source = layout(CGSize(width: 1024, height: 1366), regular: true, keyboard: 500)
        navigation.containerLayoutUpdated(source, transition: .immediate)
        let identities = navigation.viewControllers.map(ObjectIdentifier.init)
        for mode in [2, 1, 0, 2] {
            XCTAssertTrue(navigation.updateContentLayoutMode(mode))
            XCTAssertEqual(navigation.contentLayoutMode, mode)
            XCTAssertEqual(navigation.viewControllers.map(ObjectIdentifier.init), identities)
            XCTAssertTrue(navigation.topViewController === details)
            XCTAssertEqual(details.draft, "retained local editor state")
            XCTAssertEqual(navigation.validLayout, source)
            let delivered = try XCTUnwrap(details.layouts.last)
            XCTAssertEqual(delivered.metrics, source.metrics)
            XCTAssertEqual(delivered.deviceMetrics, source.deviceMetrics)
            XCTAssertEqual(delivered.inputHeight, source.inputHeight)
            XCTAssertEqual(delivered.inputHeightIsInteractivellyChanging, source.inputHeightIsInteractivellyChanging)
            if mode == 2 { XCTAssertEqual(delivered.size.width, source.size.width) }
            else { XCTAssertLessThan(delivered.size.width, source.size.width) }
        }
        XCTAssertFalse(navigation.updateContentLayoutMode(3))
        XCTAssertEqual(navigation.contentLayoutMode, 2)
        XCTAssertTrue(navigation.popViewController(animated: false) === details)
        XCTAssertTrue(navigation.topViewController === chat)
        navigation.updateContentLayoutMode(1)
        XCTAssertEqual(navigation.viewControllers.map(ObjectIdentifier.init), [master, chat].map(ObjectIdentifier.init))
        XCTAssertEqual(chat.draft, "retained local editor state")
    }

    @MainActor
    func testRetiredBackGestureAndPendingReadyCannotChangeTheNewStack() throws {
        let navigation = NavigationController(mode: .automaticMasterDetail, theme: theme(), contentLayoutRole: .applicationRoot)
        navigation.updateContentLayoutMode(2)
        let master = LayoutModeController(master: true)
        let chat = LayoutModeController()
        navigation.setViewControllers([master, chat], animated: false)
        let source = layout(CGSize(width: 1024, height: 744), regular: true)
        navigation.containerLayoutUpdated(source, transition: .immediate)
        let old = try XCTUnwrap(navigation.displayNode.subnodes?.compactMap { $0 as? NavigationContainer }.first)
        old.interactivePopBegan(translation: 0, velocity: 0, time: 0)
        old.interactivePopChanged(translation: 500, velocity: 1500, time: 0.1)
        XCTAssertNotNil(old.transitionCoordinatorForTesting)
        navigation.updateContentLayoutMode(1)
        XCTAssertNil(old.transitionCoordinatorForTesting)
        old.interactivePopEnded(translation: 900, velocity: 2000, isCancelled: false, time: 0.2)
        old.controllerRemoved(chat)
        XCTAssertTrue(navigation.topViewController === chat)
        XCTAssertEqual(navigation.viewControllers.count, 2)

        navigation.updateContentLayoutMode(2)
        let waiting = LayoutModeController(ready: false)
        navigation.setViewControllers([master, chat, waiting], animated: false)
        let pendingOwner = try XCTUnwrap(navigation.displayNode.subnodes?.compactMap { $0 as? NavigationContainer }.first)
        navigation.updateContentLayoutMode(1)
        waiting.readiness.set(.single(true))
        let drained = expectation(description: "ready delivered to current owner")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(navigation.topViewController === waiting)
        XCTAssertFalse(waiting.displayNode.supernode === pendingOwner)
        XCTAssertTrue(pendingOwner.controllers.isEmpty)
    }

    @MainActor
    func testActualModalFitsSafeAreasAndKeyboardThenFallsBackToFullScreen() throws {
        let modal = NavigationModalContainer(theme: theme(), isFlat: false, controllerRemoved: { _ in XCTFail("layout must not pop") })
        let screen = LayoutModeController()
        screen.navigationPresentation = .modal
        screen.preferredSize = CGSize(width: 10000, height: 10000)
        let source = layout(CGSize(width: 1024, height: 1366), regular: false, keyboard: 500)
        let content = try XCTUnwrap(navigationContentLayout(role: .applicationRoot, rawMode: 1, layout: source, hasMaster: true))
        modal.frame = CGRect(origin: .zero, size: source.size)
        modal.update(layout: source, controllers: [screen], coveredByModalTransition: 0, transition: .immediate, contentLayout: content)
        let frame = try XCTUnwrap(modal.presentedCardFrame)
        XCTAssertEqual(frame, content.sheetFrame(preferredSize: screen.preferredSize))
        XCTAssertGreaterThanOrEqual(frame.minX, source.safeInsets.left)
        XCTAssertLessThanOrEqual(frame.maxX, source.size.width - source.safeInsets.right)
        XCTAssertLessThanOrEqual(frame.maxY, source.size.height - 500)
        XCTAssertTrue(try XCTUnwrap(screen.layouts.last).presentedInFormSheet)
        XCTAssertEqual(screen.layouts.last?.metrics, source.metrics)

        let small = layout(CGSize(width: 390, height: 844), regular: true, keyboard: 300)
        modal.update(layout: small, controllers: [screen], coveredByModalTransition: 0, transition: .immediate, contentLayout: navigationContentLayout(role: .applicationRoot, rawMode: 1, layout: small, hasMaster: true))
        XCTAssertEqual(modal.presentedCardFrame, CGRect(origin: .zero, size: small.size))
        XCTAssertFalse(try XCTUnwrap(screen.layouts.last).presentedInFormSheet)
        XCTAssertEqual(screen.layouts.last?.metrics, small.metrics)
        modal.retireForContentLayoutChange()
        XCTAssertNil(modal.interactivelyDismissed)
        XCTAssertNil(modal.updateDismissProgress)
        let retiredProgress = modal.dismissProgress
        modal.scrollViewDidEndDragging(UIScrollView(), willDecelerate: false)
        XCTAssertEqual(modal.dismissProgress, retiredProgress, "retired gesture callbacks cannot start another dismissal")
    }

    func testPNP01TextInputAdoptionKeeps500AndSelectionImmediately() throws {
        for kind in LayoutModeTextInputController.Kind.allCases {
            let fixture = try LayoutModeInputFixture(kind: kind, theme: theme())
            defer { fixture.tearDown() }
            let selection = try fixture.input.selection()
            let identities = fixture.navigation.viewControllers.map(ObjectIdentifier.init)
            for mode in [2, 1, 0] {
                let before = fixture.input.layouts.count
                // Exercise both a surviving responder and actual focus recovery.
                fixture.input.resignInputOnNextLayout = mode == 1
                XCTAssertTrue(fixture.navigation.updateContentLayoutMode(mode))
                let delivered = Array(fixture.input.layouts.dropFirst(before))
                XCTAssertFalse(delivered.isEmpty)
                XCTAssertTrue(delivered.allSatisfy { $0.inputHeight == 500 }, "adoption must never deliver the fresh-push nil layout")
                XCTAssertEqual(fixture.input.layouts.last?.inputHeight, 500, "check before another notification/runloop turn")
                XCTAssertTrue(fixture.input.editor.isFirstResponder)
                XCTAssertEqual(try fixture.input.selection(), selection)
                XCTAssertEqual(fixture.navigation.validLayout, fixture.physicalLayout())
                XCTAssertEqual(fixture.navigation.viewControllers.map(ObjectIdentifier.init), identities)
                XCTAssertTrue(fixture.navigation.topViewController === fixture.input)
            }
        }
    }

    func testPNP01DelayedReadyAdoptsCurrentViewportBeforeReadyReturns() throws {
        for kind in LayoutModeTextInputController.Kind.allCases {
            let fixture = try LayoutModeInputFixture(kind: kind, theme: theme())
            defer { fixture.tearDown() }
            let identities = fixture.navigation.viewControllers.map(ObjectIdentifier.init)
            for mode in [2, 1] {
                try fixture.input.select(NSRange(location: 5, length: 6))
                let selection = try fixture.input.selection()
                let oldOwner = try XCTUnwrap(fixture.input.displayNode.supernode as? NavigationContainer)
                fixture.input.readiness.set(.single(false))
                let before = fixture.input.layouts.count
                fixture.navigation.updateContentLayoutMode(mode)
                XCTAssertEqual(fixture.input.layouts.last?.inputHeight, 500, "initial adoption layout is already physical, even while ready is delayed")
                XCTAssertTrue(fixture.input.layouts.dropFirst(before).allSatisfy { $0.inputHeight == 500 })
                XCTAssertTrue(oldOwner.controllers.isEmpty)
                if mode == 2 {
                    fixture.navigation.updateContentLayoutMode(1)
                    fixture.navigation.updateContentLayoutMode(2)
                    XCTAssertTrue(fixture.input.layouts.dropFirst(before).allSatisfy { $0.inputHeight == 500 }, "pending Phone-Tablet-Phone adopts the latest generation")
                }

                // A real window resize while readiness is pending must win over
                // the old pane's geometry. This is not a keyboard notification.
                fixture.window.frame = CGRect(x: 0, y: 0, width: mode == 2 ? 1000 : 960, height: 1300)
                fixture.navigation.view.frame = fixture.window.bounds
                let current = fixture.physicalLayout()
                fixture.navigation.containerLayoutUpdated(current, transition: .immediate)
                let beforeReady = fixture.input.layouts.count
                fixture.input.readiness.set(.single(true))

                // No wait, layout repair or extra keyboard event after ready.
                let final = try XCTUnwrap(fixture.input.layouts.last)
                XCTAssertEqual(final.inputHeight, 500)
                XCTAssertTrue(fixture.input.layouts.dropFirst(beforeReady).allSatisfy { $0.inputHeight == 500 })
                XCTAssertEqual(final.metrics, current.metrics)
                XCTAssertEqual(final.deviceMetrics, current.deviceMetrics)
                let masterWidth = navigationContentLayout(role: .applicationRoot, rawMode: mode, layout: current, hasMaster: true)?.masterWidth ?? 0
                XCTAssertEqual(final.size.width, current.size.width - masterWidth)
                XCTAssertTrue(fixture.input.editor.isFirstResponder)
                XCTAssertEqual(try fixture.input.selection(), selection)
                XCTAssertEqual(fixture.navigation.viewControllers.map(ObjectIdentifier.init), identities)
                XCTAssertFalse(fixture.input.displayNode.supernode === oldOwner)
                oldOwner.controllerRemoved(fixture.input)
                oldOwner.interactivePopEnded(translation: 900, velocity: 2000, isCancelled: false, time: 1)
                XCTAssertTrue(fixture.navigation.topViewController === fixture.input)
            }
        }
    }

    func testPNP01FreshPushAndSupersededReadyKeepTheirNativeOwnership() throws {
        let fixture = try LayoutModeInputFixture(kind: .field, theme: theme())
        defer { fixture.tearDown() }
        fixture.navigation.updateContentLayoutMode(2)
        let pending = LayoutModeTextInputController(kind: .view, ready: false)
        fixture.navigation.pushViewController(pending, animated: false)
        XCTAssertNil(pending.layouts.first?.inputHeight, "a genuinely fresh push keeps native keyboard suppression")
        fixture.navigation.updateContentLayoutMode(1)
        XCTAssertTrue(fixture.navigation.popViewController(animated: false) === pending)
        let retained = fixture.navigation.viewControllers.map(ObjectIdentifier.init)
        pending.readiness.set(.single(true))
        XCTAssertEqual(fixture.navigation.viewControllers.map(ObjectIdentifier.init), retained)
        XCTAssertTrue(fixture.navigation.topViewController === fixture.input)
        XCTAssertNil(pending.displayNode.supernode, "old ready must not mount a popped controller")
        XCTAssertFalse(pending.editor.isFirstResponder)
    }
}
