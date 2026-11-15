import Display
import ExteralessCore
import Foundation
import PluginHost
import UIKit

@MainActor
extension ClientHarnessSession {
    func runScenario() async throws {
        try self.probe("home")
        switch self.report.scenario {
        case "sdk-ui": try await self.sdkScenario()
        case "feed-render": try await self.runFeedScenario()
        case "player-render": try await self.runPlayerScenario()
        case "pill-render": try await self.runPillScenario()
        case "avatar-render": try await self.runAvatarScenario()
        case "composer-render":
            if #available(iOS 18.4, *) { try await self.runComposerScenario() }
            else { throw ClientHarnessFailure(description: "composer-render requires the real iOS 18.4+ InputDec backend") }
        default: try await self.coreScenario()
        }
        try clientHarnessRequire(self.report.journal.unexpectedServices.isEmpty, "unexpected fixture service calls")
    }

    private func coreScenario() async throws {
        let ui = self.driver!
        try ui.press("Open client settings")
        try await ui.settle()
        try await ui.until("settings root") { ui.hasText("setting:harness.enabled") }
        try self.probe("settings-root")

        try ui.toggle("setting:harness.enabled", to: true)
        try await ui.until("persisted switch") { self.settings.value("harness.enabled") == .bool(true) }
        try await ui.settle(0.25)
        try self.probe("toggle-confirmed", extra: ["stored": true])

        try await ui.row("setting:harness.mode")
        try await ui.settle()
        try self.probe("selector-open")
        try await ui.row("option:harness.mode:1")
        try await ui.until("selector persistence") { self.settings.value("harness.mode") == .string("ocean") }
        try await ui.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 2, "selector did not close after persistence")
        try self.probe("selector-committed", extra: ["stored": "ocean"])

        try await ui.row("setting:harness.text")
        try await ui.settle()
        try await ui.enter("input:harness.text", text: "Fixture text 雪")
        try await ui.until("software keyboard") { (self.navigation.validLayout?.inputHeight ?? 0) > 100 }
        try self.probe("text-keyboard")
        try ui.rightButton()
        try await ui.until("text persistence") { self.settings.value("harness.text") == .string("Fixture text 雪") }
        try await ui.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 2, "text editor did not close")
        try self.probe("text-committed", extra: ["stored": "Fixture text 雪"])

        try await ui.row("setting:harness.number")
        try await ui.settle()
        try await ui.enter("input:harness.number", text: "-1")
        try ui.rightButton()
        try await ui.settle()
        try clientHarnessRequire(ui.hasText("error"), "validation error row was not rendered")
        try clientHarnessRequire(self.settings.value("harness.number") == .integer(0), "invalid editor value reached storage")
        try self.probe("number-error", extra: ["stored": 0, "invalidDraft": "-1"])
        try await ui.enter("input:harness.number", text: "7")
        try ui.rightButton()
        try await ui.until("numeric persistence") { self.settings.value("harness.number") == .integer(7) }
        try await ui.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 2, "number editor did not close")
        try self.probe("number-committed", extra: ["stored": 7])

        try ui.back()
        try await ui.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1, "core navigation leaked a screen")
        try clientHarnessRequire(self.window.findFirstResponder() == nil, "core editor retained first responder")
        try self.settings.reload()
        let actual = self.settings.snapshot()
        try clientHarnessRequire(actual["harness.enabled"] == .bool(true) && actual["harness.mode"] == .string("ocean")
            && actual["harness.text"] == .string("Fixture text 雪") && actual["harness.number"] == .integer(7),
            "disk reload lost a UI mutation")
        self.report.facts["settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual))
        self.report.facts["realPython"] = false
        try await self.runSecretAvailabilitySegment()
        try self.probe("core-cleanup")
    }

    private func sdkScenario() async throws {
        guard let runtime = self.runtime else { throw ClientHarnessFailure(description: "native runtime missing") }
        let ui = self.driver!
        try clientHarnessRequire(try runtime.stored("loads") == .integer(1), "fixture did not execute exactly once")
        guard case let .object(sources) = try runtime.stored("sdk_sources") else {
            throw ClientHarnessFailure(description: "no SDK/native provenance observation")
        }
        try clientHarnessRequire(sources["native_builtin"] == .bool(true) && sources["loader"] == .bool(true)
            && sources["fixture"] == .bool(true), "SDK/native fixture source boundary was replaced")
        try ui.press("Open plugin manager")
        try await ui.settle()
        try self.probe("plugin-manager")
        try await ui.row("Owned UI Fixture")
        try await ui.settle()
        try await ui.row("Plugin settings")
        try await ui.settle()
        try await ui.until("SDK settings loaded") { ui.hasText("Alert and keyboard") }
        try self.probe("plugin-settings")

        try await ui.row("Alert and keyboard")
        try await ui.until("actual alert appearance") { try runtime.isVisible("alert") }
        try await ui.settle(0.35)
        try self.probe("alert-shown", extra: ["lease": try runtime.uiState("alert")])
        try await ui.enter("Fixture draft", text: "Snow 雪")
        try await ui.until("SDK software keyboard") { (self.navigation.validLayout?.inputHeight ?? 0) > 100 }
        try self.probe("alert-keyboard")
        self.setDark(true)
        try await ui.settle()
        let input = try ui.input("Fixture draft")
        try clientHarnessRequire(input.isFirstResponder, "live theme update lost SDK input focus")
        try clientHarnessRequire(input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!) == "Snow 雪",
            "live theme update lost SDK draft")
        try self.probe("alert-dark-draft")
        try ui.press("Accept fixture")
        try await ui.until("owner callback persisted") {
            try runtime.stored("alertAccepted") == .object(["which": .integer(-1), "text": .string("Snow 雪")])
                && runtime.stored("alertDismissed") == .bool(true)
        }
        try await ui.settle(0.35)
        try clientHarnessRequire(try runtime.uiState("alert")["visible"] as? Bool == false, "dismissed alert is still visible")
        try self.probe("alert-closed", extra: ["lease": try runtime.uiState("alert")])

        try await ui.row("Sheet widgets")
        try await ui.until("sheet appearance") { try runtime.isVisible("bottomSheet") }
        try await ui.settle(0.3)
        try ui.toggle("Fixture toggle", to: true)
        try ui.slider("Fixture amount", fraction: 0.75)
        try await ui.until("widget callbacks") {
            try runtime.stored("widget_sheet-enabled") == .bool(true)
                && runtime.stored("widget_sheet-amount") == .integer(75)
        }
        try self.probe("sheet-widgets", extra: ["lease": try runtime.uiState("bottomSheet")])
        try ui.press("Apply sheet")
        try await ui.until("sheet action") {
            try runtime.stored("sheetApplied") == .object(["sheet-enabled": .bool(true), "sheet-amount": .integer(75)])
        }
        try await ui.settle(0.35)
        try clientHarnessRequire(try runtime.uiState("bottomSheet")["visible"] as? Bool == false, "sheet did not close")
        try self.probe("sheet-closed", extra: ["lease": try runtime.uiState("bottomSheet")])

        try await ui.row("Menu choices")
        try await ui.until("menu appearance") { try runtime.isVisible("menu") }
        try await ui.settle(0.3)
        try self.probe("menu-shown", extra: ["lease": try runtime.uiState("menu")])
        try ui.press("Second fixture item")
        try await ui.until("menu index") { try runtime.stored("menuIndex") == .integer(1) }
        try await ui.settle(0.35)
        try clientHarnessRequire(try runtime.uiState("menu")["visible"] as? Bool == false, "menu did not close")
        try self.probe("menu-closed", extra: ["lease": try runtime.uiState("menu")])

        let depth = self.navigation.viewControllers.count
        try await ui.row("Navigate native settings")
        try await ui.until("native settings route") { self.navigation.viewControllers.count == depth + 1 }
        try await ui.settle()
        try clientHarnessRequire(self.navigation.topViewController?.title == "SDK native settings", "SDK route opened the wrong controller")
        try self.probe("sdk-navigation", extra: ["lease": try runtime.uiState("navigation")])
        try ui.back()
        try await ui.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == depth, "native SDK back leaked a screen")
        try clientHarnessRequire(try runtime.uiState("navigation")["visible"] as? Bool == false, "SDK settings route remained visible after back")
        try await ui.row("Inspect callback leases")
        try await ui.until("SDK lease release") {
            try runtime.stored("leases") == .object(["count": .integer(0), "handles": .integer(0)])
        }
        try self.probe("sdk-leases-clean", extra: ["leases": try runtime.stored("leases").jsonObject])

        // Back through real settings/detail/list. Reload the ONE owned plugin
        // using the manager's switch, then prove a fresh C/Host owner epoch.
        try ui.back()
        try await ui.settle()
        try ui.back()
        try await ui.settle()
        try ui.toggle("Owned UI Fixture", to: false)
        try await ui.until("fixture unload") { runtime.host.callbackOwner(id: ClientHarnessRuntime.pluginId) == nil }
        try await ui.settle(0.2)
        try ui.toggle("Owned UI Fixture", to: true)
        try await ui.until("fresh fixture load") {
            try runtime.stored("loads") == .integer(2) && runtime.host.callbackOwner(id: ClientHarnessRuntime.pluginId) != nil
        }
        try runtime.noteOwner()
        try clientHarnessRequire(runtime.epochs.count == 2 && Set(runtime.epochs).count == 2, "reload reused a Host owner epoch")
        // Read the real serializer to observe a request from the second C owner.
        _ = try await runtime.host.settingsJSON(id: ClientHarnessRuntime.pluginId, account: 41)
        guard let cEpochs = runtime.observedUI.snapshot["cEpochs"] as? [String] else {
            throw ClientHarnessFailure(description: "C epoch observation missing")
        }
        try clientHarnessRequire(Set(cEpochs) == Set(runtime.epochs), "C requests did not observe both native epochs")
        try self.probe("fixture-reloaded")
        try ui.back()
        try await ui.settle()
        try await runtime.stop()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1 && self.window.findFirstResponder() == nil,
            "UIKit did not return to a clean root")
        self.report.facts["runtime"] = runtime.snapshot
        self.report.facts["pluginSettings"] = try runtime.services.serviceStorage.settingsSnapshot(pluginId: ClientHarnessRuntime.pluginId).mapValues(\.jsonObject)
        try self.probe("sdk-cleanup")
    }
}
