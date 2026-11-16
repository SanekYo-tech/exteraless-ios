import ComponentFlow
import ExteralessCore
import Foundation
import SwitchComponent
import UIKit
import XCTest

final class AppearanceSwitchTests: XCTestCase {
    @MainActor
    func testRealControlBackendsAndAccessibilityActionRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"))
        try settings.register(AppearanceFeatures.definitions)
        let host = ComponentView<Empty>()
        var changes: [Bool] = []
        for style in [2, 3, 0, 2] {
            try settings.set(.integer(Int64(style)), for: "appearance.switchStyle")
            _ = host.update(transition: .init(animation: .none), component: AnyComponent(SwitchComponent(value: false, accessibilityLabel: "Show previews", appearanceSettings: settings, valueUpdated: { changes.append($0) })), environment: {}, containerSize: CGSize(width: 80, height: 44))
            let root = try XCTUnwrap(host.view)
            let control = try XCTUnwrap(root.subviews.compactMap { $0 as? UIControl }.first { !$0.isHidden })
            XCTAssertEqual(control.accessibilityLabel, "Show previews")
            if style == 0 {
                XCTAssertTrue(control is UISwitch)
            } else {
                XCTAssertFalse(control is UISwitch)
                XCTAssertGreaterThanOrEqual(control.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
                XCTAssertTrue(control.accessibilityActivate())
                XCTAssertEqual(changes.last, true)
                XCTAssertTrue(control.accessibilityActivate())
                XCTAssertEqual(changes.last, false)
                control.isEnabled = false
                let count = changes.count
                XCTAssertFalse(control.accessibilityActivate())
                XCTAssertEqual(changes.count, count)
                control.isEnabled = true
            }
        }
    }
}
