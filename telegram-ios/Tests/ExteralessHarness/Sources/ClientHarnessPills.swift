import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramUI
import UIKit

/// One finite native provider of fixture readings. The production registry owns
/// throttling, subscription lifetime and all delivery to the actual native header.
final class ClientHarnessPillProvider: PillPluginProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var update: (@Sendable (PillModel) -> Void)?
    private var starts = 0
    private var cancellations = 0
    let generation: String
    let id = 10041

    init(generation: String) { self.generation = generation }
    func start(_ request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        precondition(request.id == self.id)
        self.lock.lock(); self.update = update; self.starts += 1; self.lock.unlock()
        update(PillModel(id: self.id, title: "Fixture pill", value: "Loading " + self.generation,
            source: "Finite native acceptance provider", phase: .loading))
        // Deliberately synchronous: FPP-10 must deliver this via its real trailing
        // slot; no fake clock or handwritten header state is installed.
        update(PillModel(id: self.id, title: "Fixture pill", value: "Ready " + self.generation,
            source: "Finite native acceptance provider", phase: .ready))
        return PillCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cancellations += 1; self.lock.unlock()
        }
    }
    func perform(_ action: PillPluginAction, request: PillPluginRequest) {
        fatalError("client-ui-harness: unprovided Pill action \(action)")
    }
    func publishRetiredValue() {
        self.lock.lock(); let update = self.update; self.lock.unlock()
        update?(PillModel(id: self.id, title: "Fixture pill", value: "RETIRED MUST NOT RENDER",
            source: "Finite retired producer", phase: .ready))
    }
    var counts: [String: Int] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["starts": self.starts, "cancellations": self.cancellations]
    }
}

@MainActor
final class ClientHarnessPills {
    let integration = ExteralessPillIntegration()
    let header: any ExteralessPillHeader
    private var registration: PillCancellation?
    private(set) var providers: [ClientHarnessPillProvider] = []
    private(set) var owners: [PillPluginOwner] = []

    init(context: AccountContext, home: ClientHarnessHomeController) throws {
        self.integration.update(context: context)
        guard let header = ExteralessPillEntry.makeHeader(context: context, open: { [weak home] in home?.push($0) }) else {
            throw ClientHarnessFailure(description: "real Pill header factory unavailable")
        }
        self.header = header
        home.attachPillHeader(header)
    }

    func register(generation: String) throws {
        self.registration?.cancel()
        let provider = ClientHarnessPillProvider(generation: generation)
        let owner = PillPluginOwner(pluginId: "clientUIHarnessPill", generation: UUID())
        self.providers.append(provider)
        self.owners.append(owner)
        self.registration = try PillPluginRegistry.shared.register(owner: owner,
            descriptor: PillDescriptor(id: provider.id, title: "Fixture pill", symbol: "checkmark.circle", interval: 3600),
            provider: provider)
    }

    func setVisible(_ visible: Bool) {
        self.header.view.isHidden = !visible
        self.header.setVisible(visible)
    }

    func close() {
        self.header.invalidate()
        self.header.view.removeFromSuperview()
        self.registration?.cancel()
        self.registration = nil
        self.integration.clearContext()
        ExteralessSettingsUI.unregisterActions(ids: ["pills.status"])
    }

    var snapshot: [String: Any] {
        ["renderer": NSStringFromClass(type(of: self.header.view)), "id": 10041,
         "label": self.header.view.accessibilityLabel ?? "", "height": self.header.preferredHeight,
         "owners": self.owners.map { $0.generation.uuidString }, "providers": self.providers.map(\.counts)]
    }
}

@MainActor
extension ClientHarnessSession {
    func runPillScenario() async throws {
        guard let home = self.navigation.viewControllers.first as? ClientHarnessHomeController else {
            throw ClientHarnessFailure(description: "Pill fixture home missing")
        }
        try ClientSettings.shared.applyPublic(PillLayout(active: [5], hidden: [], selected: 5).patch,
            expected: ClientSettings.shared.readSnapshot())
        let pills = try ClientHarnessPills(context: self.context, home: home)
        defer { pills.close() }
        try await self.driver.settle()
        try await self.driver.until("real Cache header") { pills.header.preferredHeight > 0 }
        try self.probe("pill-cache-initial", extra: pills.snapshot)
        try self.driver.press("Open client settings")
        try await self.driver.settle()
        try await self.driver.row("action:pills.status")
        try await self.driver.settle()
        try await self.driver.row("Cache")
        try await self.driver.until("hide last pill committed") {
            try PillConfiguration(values: ClientSettings.shared.snapshot()).layout.visible(available: [5]).isEmpty
        }
        try self.driver.back(); try await self.driver.settle()
        try self.driver.back(); try await self.driver.settle()
        try await self.driver.until("last pill has no reserved band") { pills.header.preferredHeight == 0 }
        try self.probe("pill-last-hidden", extra: pills.snapshot)

        try self.driver.press("Open client settings")
        try await self.driver.settle()
        try await self.driver.row("action:pills.status")
        try await self.driver.settle()
        try self.probe("pill-independent-settings")
        try await self.driver.row("Cache")
        try await self.driver.until("enable Cache committed") {
            try PillConfiguration(values: ClientSettings.shared.snapshot()).layout.visible(available: [5]) == [5]
        }
        try self.driver.back(); try await self.driver.settle()
        try self.driver.back(); try await self.driver.settle()
        try await self.driver.until("Cache header returned") { pills.header.preferredHeight > 0 }
        try self.probe("pill-cache-enabled", extra: pills.snapshot)
        self.setDark(true)
        try await self.driver.settle(0.3)
        try self.probe("pill-dark-header", extra: pills.snapshot)

        try pills.register(generation: "one")
        try ClientSettings.shared.applyPublic(PillLayout(active: [10041], hidden: [5], selected: 10041).patch,
            expected: ClientSettings.shared.readSnapshot())
        try await self.driver.until("native Pill loading", timeout: 1) {
            (pills.header.view.accessibilityLabel ?? "").contains("Loading")
        }
        try self.probe("pill-provider-loading", extra: pills.snapshot)
        try await self.driver.until("native Pill trailing ready") {
            (pills.header.view.accessibilityLabel ?? "").contains("Ready one")
        }
        try await self.driver.settle(0.2)
        try self.probe("pill-provider-ready", extra: pills.snapshot)

        pills.setVisible(false)
        try await self.driver.until("native Pill cancellation") { pills.providers[0].counts["cancellations"] == 1 }
        pills.providers[0].publishRetiredValue()
        try pills.register(generation: "two")
        pills.setVisible(true)
        try await self.driver.until("replacement loading before cancellation", timeout: 1) {
            pills.providers[1].counts["starts"] == 1 && (pills.header.view.accessibilityLabel ?? "").contains("Loading")
        }
        try self.probe("pill-cancel-pending", extra: pills.snapshot)
        pills.setVisible(false)
        try await self.driver.until("trailing delivery cancelled") { pills.providers[1].counts["cancellations"] == 1 }
        pills.providers[1].publishRetiredValue()
        try pills.register(generation: "three")
        pills.setVisible(true)
        try await self.driver.until("replacement native Pill") {
            (pills.header.view.accessibilityLabel ?? "").contains("Ready three")
        }
        pills.providers[0].publishRetiredValue()
        pills.providers[1].publishRetiredValue()
        try await self.driver.settle(0.4)
        try clientHarnessRequire(!(pills.header.view.accessibilityLabel ?? "").contains("RETIRED"), "old Pill owner reached native header")
        try self.probe("pill-reloaded", extra: pills.snapshot)
        pills.close()
        try await self.driver.settle(0.25)
        try await self.driver.until("Pill provider cleanup") { pills.providers.allSatisfy { $0.counts["cancellations"] == $0.counts["starts"] } }
        try clientHarnessRequire(pills.header.view.window == nil && !PillPluginRegistry.shared.descriptors.contains(where: { $0.id == 10041 }), "Pill cleanup left an owned renderer/provider")
        try clientHarnessRequire(self.navigation.viewControllers.count == 1, "Pill settings left a navigation controller")
        self.report.facts["domain"] = ["name": "pill-render", "realNativeRenderer": true, "cleanup": true,
            "providerKind": "finite native fixture through production registry", "final": pills.snapshot]
        try self.probe("pill-cleanup", extra: pills.snapshot)
    }
}
