import AsyncDisplayKit
import ExteralessCore
import SwiftSignalKit
import UIKit
import XCTest
@testable import Display

private final class LayoutModeController: ViewController {
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
}
