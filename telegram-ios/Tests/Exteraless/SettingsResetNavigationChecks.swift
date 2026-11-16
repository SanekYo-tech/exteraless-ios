import AccountContext
import AsyncDisplayKit
import ExteralessCore
import Foundation
import UIKit
@testable import Display
@testable import TelegramUI

private struct SettingsResetNavigationFailure: Error {
    let message: String
}

/// Holds a completed provider reply, never the main thread or a settings lock.
/// One bounded hold per gate; later preparations only increment the counter.
private final class SettingsResetReplyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let holdFirst: Bool
    private var count = 0
    private var released = false
    private var expired = false

    init(holdFirst: Bool) { self.holdFirst = holdFirst }
    var arrivals: Int { self.condition.lock(); defer { self.condition.unlock() }; return self.count }
    var timedOut: Bool { self.condition.lock(); defer { self.condition.unlock() }; return self.expired }

    func arrive() {
        self.condition.lock()
        defer { self.condition.unlock() }
        self.count += 1
        if self.holdFirst && self.count == 1 {
            let deadline = Date().addingTimeInterval(6.0)
            while !self.released {
                if !self.condition.wait(until: deadline) { self.expired = true; break }
            }
        }
    }

    func release() {
        self.condition.lock()
        self.released = true
        self.condition.broadcast()
        self.condition.unlock()
    }
}

private struct SettingsResetNoSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { throw ClientSettingsError.secretStorageUnavailable }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretStorageUnavailable }
}

/// The shipping reset renderer/provider, with lifecycle recording only. The
/// fixture never invokes these callbacks itself: NavigationContainer does.
@MainActor
private final class SettingsResetRecordedController: SettingsResetController {
    var lifecycle: [String] = []

    override func viewWillAppear(_ animated: Bool) { self.lifecycle.append("willAppear"); super.viewWillAppear(animated) }
    override func viewDidAppear(_ animated: Bool) { self.lifecycle.append("didAppear"); super.viewDidAppear(animated) }
    override func viewWillDisappear(_ animated: Bool) { self.lifecycle.append("willDisappear"); super.viewWillDisappear(animated) }
    override func viewDidDisappear(_ animated: Bool) { self.lifecycle.append("didDisappear"); super.viewDidDisappear(animated) }
}

/// Given-context checks for the existing loginless, debug_sim_arm64 harness.
/// Each case mounts the real Display container and reset controller in the given
/// live window. Internal gesture entry points are the same ones used by Display's
/// own NavigationContainerSwipeCatchTests, not synthesized UIViewController order.
@MainActor
enum SettingsResetNavigationChecks {
    enum Scenario: String, CaseIterable {
        case readyCancelled = "reset-ready-cancelled"
        case prepareBeforeReturn = "reset-prepare-before-return"
        case prepareAfterReturn = "reset-prepare-after-return"
        case resetBeforeReturn = "reset-reply-before-return"
        case resetAfterReturn = "reset-reply-after-return"
        case prepareActualPop = "reset-prepare-actual-pop"
        case resetActualPop = "reset-reply-actual-pop"
        case retiredReady = "reset-retired-ready"
        case retiredPrepare = "reset-retired-prepare"
        case retiredReset = "reset-retired-reply"

        var holdsPrepare: Bool { [.prepareBeforeReturn, .prepareAfterReturn, .prepareActualPop, .retiredPrepare].contains(self) }
        var holdsReset: Bool { [.resetBeforeReturn, .resetAfterReturn, .resetActualPop, .retiredReset].contains(self) }
        var finishesBeforeReturn: Bool { [.prepareBeforeReturn, .resetBeforeReturn].contains(self) }
        var actualPop: Bool { [.prepareActualPop, .resetActualPop].contains(self) }
        var retiresContext: Bool { [.retiredReady, .retiredPrepare, .retiredReset].contains(self) }
    }

    /// Passed from the existing verified domainSources manifest/ready protocol;
    /// include this file and the real lifecycle/worker bodies in the build inputs.
    static let requiredSources = [
        "telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift",
        "telegram-ios/Tests/ExteralessHarness/BUILD",
        "telegram-ios/Tests/ExteralessHarness/Info.plist",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenario.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetIntegration.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetCatalog.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetOperation.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSourceRoutes.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/ToolsFeatures.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/PrivacyFeatures.swift",
        "telegram-ios/submodules/Display/Source/Navigation/NavigationContainer.swift",
        "telegram-ios/submodules/Display/Source/NavigationTransitionCoordinator.swift",
        "telegram-ios/submodules/Display/Source/NavigationTransitionSpring.swift",
        "telegram-ios/submodules/Display/Source/NavigationInteractivePopTracker.swift"
    ]

    static func run(_ scenario: Scenario, context: AccountContext, hostView: UIView, layout: ContainerViewLayout,
                    sourceHashes: [String: String], probe: (String, [String: Any]) throws -> Void) async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw SettingsResetNavigationFailure(message: message) }
        }
        try require(hostView.window != nil && layout.size.width > 0 && layout.size.height > 0, "reset fixture requires a mounted harness window/layout")
        try require(self.requiredSources.allSatisfy { sourceHashes[$0]?.count == 64 }, "reset fixture source/ready hashes are incomplete")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-reset-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("settings.json")
        let key = "tools.downloadSpeedBoost"
        let settings: ClientSettings
        do {
            settings = try await Task.detached(priority: .userInitiated) {
                let result = try ClientSettings(storageURL: url, secretStore: SettingsResetNoSecrets(), durabilityRootURL: root)
                let fields = CoreSettingsResetCatalog.fields(for: .general)
                let definitions = (PrivacyFeatures.definitions + ToolsFeatures.definitions).filter { definition in
                    fields.contains { CoreSettingsResetCatalog.matches(definition, source: $0) }
                }
                try result.register(definitions)
                try result.set(.integer(2), for: key)
                return result
            }.value
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        let authority = CoreSettingsResetAuthority()
        let prepareGate = SettingsResetReplyGate(holdFirst: scenario.holdsPrepare)
        let resetGate = SettingsResetReplyGate(holdFirst: scenario.holdsReset)
        let controller = SettingsResetRecordedController(context: context, provider: CoreSettingsResetProvider(settings: settings),
            authority: authority, scope: .general, workHooks: SettingsResetWorkHooks(afterPrepare: { prepareGate.arrive() }, afterReset: { resetGate.arrive() }))
        let beneath = ViewController(navigationBarPresentationData: nil)
        beneath.title = "Reset navigation fixture"
        let container = NavigationContainer(isFlat: false, controllerRemoved: { _ in })
        var removals = 0
        container.controllerRemoved = { [weak container] leaving in
            guard let container, leaving === controller else { return }
            removals += 1
            // Same immediate stack update that NavigationController performs at
            // commit. This lets Display deliver the real DidDisappear ending.
            container.update(layout: layout, canBeClosed: false, controllers: [beneath], transition: .immediate)
        }
        container.frame = CGRect(origin: .zero, size: layout.size)
        hostView.addSubview(container.view)
        let deadline = Date().addingTimeInterval(18.0)

        func until(_ message: String, seconds: TimeInterval = 2.0, _ ready: () -> Bool) async throws {
            let end = min(deadline, Date().addingTimeInterval(seconds))
            while !ready() {
                try require(Date() < end, "Timed out: " + message)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func row(_ id: String) -> (IndexPath, ExteralessSettingsRow)? {
            for (section, group) in controller.sections.enumerated() {
                if let index = group.rows.firstIndex(where: { $0.id == id }) { return (IndexPath(row: index, section: section), group.rows[index]) }
            }
            return nil
        }
        func ready() -> Bool {
            let state = controller.navigationStateForTesting
            return !controller.isBusy && state.authorityIsValid && state.planID != nil && row("reset.apply")?.1.enabled == true
        }
        func emit(_ label: String, extra: [String: Any] = [:]) throws {
            let state = controller.navigationStateForTesting
            var payload: [String: Any] = [
                "scenario": scenario.rawValue, "lifecycle": controller.lifecycle,
                "authorityID": state.authorityID.uuidString, "authorityValid": state.authorityIsValid,
                "planID": state.planID?.uuidString ?? "none", "sessionPlanID": state.sessionPlanID?.uuidString ?? "none",
                "busy": controller.isBusy, "visible": controller.isScreenVisible, "queuedPreview": state.pendingPreview,
                "prepareReplies": prepareGate.arrivals, "resetReplies": resetGate.arrivals, "removals": removals,
                "storedOverride": settings.readSnapshot().storedKeys.contains(key), "actualValue": settings.integer(key),
                "pageFrame": [controller.displayNode.frame.minX, controller.displayNode.frame.minY, controller.displayNode.frame.width, controller.displayNode.frame.height]
            ]
            payload.merge(extra, uniquingKeysWith: { _, new in new })
            try probe(label, payload)
        }
        func cleanup() async throws {
            authority.invalidate()
            prepareGate.release()
            resetGate.release()
            defer {
                container.view.removeFromSuperview()
                if !controller.isBusy { try? FileManager.default.removeItem(at: root) }
            }
            try await until("reset worker cleanup", seconds: 5.0) { !controller.isBusy }
        }

        do {
            container.update(layout: layout, canBeClosed: false, controllers: [beneath, controller], transition: .immediate)
            try await until("first prepare reply") { prepareGate.arrivals == 1 }
            if scenario.holdsPrepare {
                try require(controller.isBusy && controller.navigationStateForTesting.planID == nil, "prepare reply was not held before publication")
            } else {
                try await until("initial native preview", ready)
            }
            try require(controller.lifecycle == ["willAppear", "didAppear"], "initial Display Will+Did sequence changed")
            if scenario.holdsReset {
                let state = controller.navigationStateForTesting
                guard let plan = state.planID else { throw SettingsResetNavigationFailure(message: "initial confirmation has no native plan") }
                // Execute the shipping positive-confirmation continuation; the
                // fixture barrier is AFTER session.run, not a fake reset result.
                controller.applyConfirmedPlan(plan, authorityID: state.authorityID)
                try await until("held committed reset reply") { resetGate.arrivals == 1 }
                try require(controller.isBusy && !settings.readSnapshot().storedKeys.contains(key), "real public reset did not complete before the held reply")
                try require(controller.navigationStateForTesting.sessionPlanID == plan, "the held reply has no actual reset session")
            }
            let old = controller.navigationStateForTesting
            let beforeSwipe = try Data(contentsOf: url)
            try emit("reset-before-swipe", extra: ["sources": Dictionary(uniqueKeysWithValues: self.requiredSources.map { ($0, sourceHashes[$0]!) })])
            controller.lifecycle.removeAll()
            container.interactivePopBegan(translation: 0, velocity: 250)
            container.interactivePopChanged(translation: layout.size.width * 0.22, velocity: 250)
            try require(controller.lifecycle == ["willDisappear"], "real interactive pop did not send WillDisappear")
            try require(!controller.navigationStateForTesting.authorityIsValid, "leaving authority was not invalidated")
            try await Task.sleep(nanoseconds: 120_000_000)
            try emit("reset-dragging")

            if scenario.finishesBeforeReturn {
                prepareGate.release()
                resetGate.release()
                try await until("old reply before navigation return") { !controller.isBusy }
                try require(prepareGate.arrivals == 1 && !controller.isScreenVisible, "work restarted while the gesture still hid the page")
                try emit("reset-old-reply-before-return")
            }
            if scenario.retiresContext { authority.invalidate() }
            if scenario.actualPop {
                container.interactivePopChanged(translation: layout.size.width * 0.9, velocity: 1600)
                container.interactivePopEnded(translation: layout.size.width * 0.9, velocity: 1600, isCancelled: false)
                try await until("committed Display pop") { controller.lifecycle.contains("didDisappear") }
                try require(removals == 1 && controller.view.window == nil, "actual pop did not detach the reset page")
            } else {
                container.interactivePopEnded(translation: layout.size.width * 0.22, velocity: 0, isCancelled: true)
                try await until("Display cancelled-pop return") { controller.lifecycle.contains("didAppear") }
                try require(controller.lifecycle == ["willDisappear", "didAppear"], "cancel fixture must exercise DidAppear WITHOUT a new WillAppear")
                try require(removals == 0 && container.controllers.last === controller, "cancelled pop removed its reset page")
                if !scenario.retiresContext {
                    let returned = controller.navigationStateForTesting
                    try require(returned.authorityIsValid && returned.authorityID != old.authorityID, "actual return did not create a fresh child authority")
                    try require(returned.sessionPlanID == nil, "actual return revived the old reset session")
                    if (scenario.holdsPrepare || scenario.holdsReset) && !scenario.finishesBeforeReturn {
                        try require(controller.isBusy && returned.pendingPreview && returned.planID == nil, "return must queue the new preview behind old work")
                        try require(prepareGate.arrivals == 1, "a second prepare started before Base.perform became idle")
                    }
                }
            }
            try emit("reset-navigation-ended")
            prepareGate.release()
            resetGate.release()

            if scenario.actualPop || scenario.retiresContext {
                try await until("retired old reply drained") { !controller.isBusy }
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(prepareGate.arrivals == 1, "popped/retired page restarted preparation")
                try require(!controller.navigationStateForTesting.authorityIsValid && !controller.navigationStateForTesting.pendingPreview, "retired page retained recovery admission")
                try require(row("reset.apply")?.1.enabled != true, "retired native reset action remained enabled")
                try emit("reset-retired-idle")
            } else {
                try await until("fresh returned native preview", ready)
                try await Task.sleep(nanoseconds: 100_000_000)
                let returned = controller.navigationStateForTesting
                try require(prepareGate.arrivals == 2, "cancelled return must create exactly ONE replacement preview")
                try require(returned.planID != old.planID && returned.sessionPlanID == nil, "returned preview reused the prior plan/session")
                guard let (path, model) = row("reset.apply") else { throw SettingsResetNavigationFailure(message: "native reset action row missing") }
                controller.tableView.scrollToRow(at: path, at: .middle, animated: false)
                controller.tableView.layoutIfNeeded()
                guard let cell = controller.tableView.cellForRow(at: path), cell.window != nil else { throw SettingsResetNavigationFailure(message: "actual UIKit reset cell was not mounted") }
                try require(model.enabled && cell.accessibilityIdentifier == "reset.apply" && !cell.accessibilityTraits.contains(.notEnabled), "returned actual UIKit reset action is disabled")
                let frame = cell.convert(cell.bounds, to: cell.window)
                try require(frame.width > 0 && frame.height > 0, "returned reset action has no rendered geometry")
                try emit("reset-returned-ready", extra: ["actionLabel": cell.accessibilityLabel ?? "", "actionFrame": [frame.minX, frame.minY, frame.width, frame.height]])
            }
            try require(!prepareGate.timedOut && !resetGate.timedOut, "a native fixture reply barrier expired")
            try require(resetGate.arrivals == (scenario.holdsReset ? 1 : 0), "a stale reset session ran again")
            let afterSwipe = try Data(contentsOf: url)
            try require(afterSwipe == beforeSwipe, "navigation recovery changed the actual settings file")
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }
}
