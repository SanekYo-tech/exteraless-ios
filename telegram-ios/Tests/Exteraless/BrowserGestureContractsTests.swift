import Display
import ExteralessCore
import Foundation
import UIKit
import XCTest

/// Compiled with the shipping ExteralessBrowserGestures source. No page, Account,
/// WebKit process, live URL or user gesture is created by these contract tests.
@MainActor
final class BrowserGestureContractsTests: XCTestCase {
    func testNativeModalGateCanBeClearedAfterItWasSet() {
        let view = UIView()
        XCTAssertFalse(view.disablesInteractiveModalDismiss)
        view.disablesInteractiveModalDismiss = true
        XCTAssertTrue(view.disablesInteractiveModalDismiss)
        view.disablesInteractiveModalDismiss = false
        XCTAssertFalse(view.disablesInteractiveModalDismiss)
    }

    func testLiveBrowserSettingUpdatesBothIndependentNavigationGates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"))
        try settings.register([ClientSettingDefinition(key: "chats.disableInAppBrowserGestures",
            title: "Browser gestures", section: "Fixture", defaultValue: .bool(false))])
        let root = UIView()
        let gate = ExteralessBrowserGestures(navigationView: root, settings: settings)
        defer { withExtendedLifetime(gate) {} }
        XCTAssertFalse(root.disablesInteractiveModalDismiss)
        XCTAssertEqual(root.disablesInteractiveTransitionGestureRecognizerNow?(), false)

        try settings.set(.bool(true), for: "chats.disableInAppBrowserGestures")
        await drainMainQueue()
        XCTAssertTrue(root.disablesInteractiveModalDismiss)
        XCTAssertEqual(root.disablesInteractiveTransitionGestureRecognizerNow?(), true)

        try settings.reset("chats.disableInAppBrowserGestures")
        await drainMainQueue()
        XCTAssertFalse(root.disablesInteractiveModalDismiss)
        XCTAssertEqual(root.disablesInteractiveTransitionGestureRecognizerNow?(), false)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
