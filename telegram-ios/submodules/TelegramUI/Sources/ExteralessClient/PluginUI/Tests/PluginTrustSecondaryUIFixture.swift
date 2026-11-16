#if PLUGIN_TRUST_SECONDARY_UI_FIXTURE
import AccountContext
import Display
import Foundation
import PluginHost
import UIKit

private struct SecondaryUIFailure: Error { let message: String }
private func secondaryExpect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw SecondaryUIFailure(message: message) }
}
private final class SecondaryUIBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
private final class SecondaryUIEngine: CPythonEngine, @unchecked Sendable {
    private let state = SecondaryUIBox<(Int64, [Int64: Thread])>((0, [:]))
    var apiVersion: String { "secondary-ui-canned" }
    var isProcessInitialized: Bool { true }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {}
    func finalizeProcess() throws {}
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        state.with { $0.0 += 1; $0.1[$0.0] = Thread.current; return InterpRef(raw: $0.0) }
    }
    func destroyInterpreter(_ reference: InterpRef) throws { _ = state.with { $0.1.removeValue(forKey: reference.raw) } }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        guard state.with({ $0.1[reference.raw] === Thread.current }) else { throw SecondaryUIFailure(message: "Wrong fixture worker") }
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            return "{\"metadata\":{\"id\":\"secondary\"},\"handles\":{\"app_event\":true},\"has_settings\":false}"
        }
        return "null"
    }
}

/// Invoke from an existing loginless UIKit harness with its visible presenter.
/// Drives real uiPresent dispatch/renderer, openLink, share sheet and retirement.
/// Only OS URL opening/interception results and callback transport are controlled;
/// no real account, Python code, external plugin or network operation is started.
@MainActor public enum PluginTrustSecondaryUIFixture {
    private struct Probe {
        var work: [@MainActor @Sendable () -> Void] = []
        var deliveries: [(String, @Sendable () -> Bool)] = []
        var releasesAllowed = true
        var releaseAttempts = 0
        var released: [Int64] = []
        var resolves = 0
    }

    public static func run(context: AccountContext, presenter: ViewController) async throws {
        guard presenter.viewIfLoaded?.window != nil else { throw SecondaryUIFailure(message: "Loginless presenter must be visible") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("secondary-ui-\(UUID().uuidString)")
        let storage = PluginServiceStorage(rootDirectory: root)
        let own = try storage.filesDirectory(pluginId: "secondary").appendingPathComponent("own.txt")
        let external = root.appendingPathComponent("external.txt")
        try Data("owned fixture".utf8).write(to: own)
        try Data("external fixture".utf8).write(to: external)
        let host = try PluginHost(engine: SecondaryUIEngine(), configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 2), storageDirectory: root, stopTimeout: 1))
        let probe = SecondaryUIBox(Probe())
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 1)
        let ui = PluginUIBridgeExtension(captureOwner: { host.callbackOwner(id: $0) }, callback: { _, _, _, _ in true },
            release: { _, handles in probe.with { value in
                value.releaseAttempts += 1
                guard value.releasesAllowed else { return false }
                value.released += handles
                return true
            } }, hasPermission: { host.permissions.has($0, $1) }, accountIndex: { _ in 0 },
            settingsController: { _, _, _, _ in nil }, presenter: { _ in presenter },
            resolveShareFile: { id, path in
                probe.with { $0.resolves += 1 }
                return try PluginUIShareFiles.resolve(path: path,
                    allowedRoots: [storage.filesDirectory(pluginId: id), storage.cacheDirectory(pluginId: id)],
                    allowExternal: host.permissions.has(id, .files))
            }, effectBudget: budget, permissionAdmission: { host.permissions.futurePredicate($0, requiring: $1) },
            controlledCallback: { _, _, _, json, predicate in
                let event = (try? PluginUIJSON.decode(json))?.array?.first?.object?["event"]?.string ?? "unknown"
                probe.with { $0.deliveries.append((event, predicate)) }
                return true
            }, classifyShareFile: { id, path in
                try PluginResourcePath(path: path, allowedRoots: [storage.filesDirectory(pluginId: id), storage.cacheDirectory(pluginId: id)])
            }, schedulePresentation: { work in probe.with { $0.work.append(work) } })
        host.bridge.extensionProvider = ui
        do {
            try await host.start(safeMode: true)
            let source = root.appendingPathComponent("secondary.plugin")
            try Data("# canned fixture bytes; never executed\n".utf8).write(to: source)
            _ = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "secondary"))
            ui.update(context: context)
            try await links(host: host, ui: ui, probe: probe, budget: budget)
            try await shares(host: host, ui: ui, probe: probe, budget: budget, own: own, external: external, presenter: presenter)
        } catch {
            probe.with { $0.releasesAllowed = true; $0.work.removeAll() }
            ui.clearContext()
            host.bridge.extensionProvider = nil
            await host.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        ui.clearContext()
        host.bridge.extensionProvider = nil
        await host.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static func request(host: PluginHost, member: String = "uiPresent", args: [PluginUIJSON]) async throws -> PluginUIJSON {
        guard let owner = host.callbackOwner(id: "secondary") else { throw SecondaryUIFailure(message: "Fixture owner expired") }
        let json = try PluginUIJSON.object(["op": .string("call"), "fqcn": .string("exteraless.ios.Runtime"),
            "member": .string(member), "ownerToken": .string(owner.wireToken), "args": .array(args)]).encoded()
        return try await Task.detached {
            try PluginUIJSON.decode(host.bridge.dispatchJSON(json, pluginId: "secondary"))
        }.value
    }
    private static func present(host: PluginHost, kind: String, model: [String: PluginUIJSON], handle: Int64) async throws -> PluginUIJSON {
        try await request(host: host, args: [.string(kind), .object(model), .object([
            "action": .object(["__handle__": .integer(handle)]),
            "cancel": .object(["__handle__": .integer(handle + 1)]),
            "closed": .object(["__handle__": .integer(handle + 2)])])])
    }
    private static func id(_ reply: PluginUIJSON) throws -> UUID {
        guard reply.object?["ok"] == .bool(true), let value = reply.object?["value"]?.object?["id"]?.string,
              let id = UUID(uuidString: value) else { throw SecondaryUIFailure(message: "Actual UI admission failed: \(reply)") }
        return id
    }
    private static func drain(_ probe: SecondaryUIBox<Probe>) {
        let jobs = probe.with { value -> [@MainActor @Sendable () -> Void] in
            let jobs = value.work; value.work.removeAll(); return jobs
        }
        for job in jobs { job() }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SecondaryUIFailure(message: "Two-second UI fixture deadline expired") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func budgetFree(_ budget: PluginNativeEffectBudget) throws {
        let ticket = try budget.reserve(pluginId: "secondary", bytes: 1)
        ticket.finish()
    }
    private static func budgetHeld(_ budget: PluginNativeEffectBudget) throws {
        do {
            let ticket = try budget.reserve(pluginId: "secondary", bytes: 1)
            ticket.finish()
        } catch is BridgeFailure { return }
        throw SecondaryUIFailure(message: "Deferred effect refunded credit before drain")
    }

    private static func links(host: PluginHost, ui: PluginUIBridgeExtension, probe: SecondaryUIBox<Probe>, budget: PluginNativeEffectBudget) async throws {
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        let parent = try id(await present(host: host, kind: "alert", model: ["text": .string("Native link fixture"), "messageClickable": .bool(true)], handle: 100))
        drain(probe)
        try await wait { ui.canAct(id: parent, revision: 0) }
        let url = URL(string: "https://example.invalid/fixture")!
        var held: (@MainActor () -> Void)?
        var opened = 0
        try ui.openLink(id: parent, revision: 0, url: url, intercept: { _, original in held = original; return true },
            open: { _, completion in opened += 1; completion() })
        try budgetHeld(budget)
        try host.setPluginTrustLevel(id: "secondary", level: .isolated)
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        try secondaryExpect(ui.canAct(id: parent, revision: 0), "UI-only parent was retired by an intents downgrade")
        await Task.yield() // The held interception returns through the main continuation.
        held?(); held = nil
        try secondaryExpect(opened == 0, "Pre-revocation link reopened after regrant")
        try budgetFree(budget)
        try ui.openLink(id: parent, revision: 0, url: url, intercept: { _, _ in false },
            open: { _, completion in opened += 1; completion() })
        try secondaryExpect(opened == 1, "New authorized link / false-interception control failed")
        try budgetFree(budget)
        try ui.openLink(id: parent, revision: 0, url: url, intercept: { _, original in held = original; return true }, open: { _, _ in opened += 1 })
        held = nil // Handled/cancelled interception drops its original without executing.
        try budgetFree(budget)
        ui.releaseInstances(pluginId: "secondary")
        try await wait { ui.leases.liveCount == 0 }
        await Task.yield()
    }

    private static func shares(host: PluginHost, ui: PluginUIBridgeExtension, probe: SecondaryUIBox<Probe>, budget: PluginNativeEffectBudget,
                               own: URL, external: URL, presenter: ViewController) async throws {
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        let denied = try await present(host: host, kind: "share", model: ["files": .array([.string(external.path)])], handle: 200)
        try secondaryExpect(denied.object?["ok"] == .bool(false) && probe.with { $0.work.isEmpty }, "Ungrantable external share reached the queue")
        try secondaryExpect(probe.with { $0.resolves == 0 }, "Missing files was discovered only by a late grant-dependent resolver")
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents, .files])
        let stale = try id(await present(host: host, kind: "share", model: ["files": .array([.string(external.path)])], handle: 210))
        probe.with { $0.releasesAllowed = false }
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents, .files])
        try budgetHeld(budget)
        drain(probe)
        try secondaryExpect(ui.leases.entry(id: stale) == nil, "Old external share survived files revocation")
        try budgetFree(budget)
        let blocked = try await present(host: host, kind: "share", model: ["files": .array([.string(own.path)])], handle: 220)
        try secondaryExpect(blocked.object?["ok"] == .bool(false), "False cleanup return released native callback ownership early")
        probe.with { $0.releasesAllowed = true }
        try await wait { probe.with { $0.released.contains(212) } }

        // A real visible external sheet retains files through its entire lifetime.
        let visible = try id(await present(host: host, kind: "share", model: ["files": .array([.string(external.path)])], handle: 230))
        drain(probe)
        try await wait { ui.leases.entry(id: visible)?.state.isPresented == true }
        guard let entry = ui.leases.entry(id: visible),
              let action = ui.leases.action(id: visible, revision: entry.state.revision, scope: entry.state.scope,
                  name: "action", payload: [:]).delivery, ui.deliver(action),
              let delivered = probe.with({ $0.deliveries.last(where: { $0.0 == "action" })?.1 }) else {
            throw SecondaryUIFailure(message: "Actual external-share callback was not admitted")
        }
        try secondaryExpect(delivered(), "External share callback was never current")
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        try await wait { ui.leases.entry(id: visible) == nil && presenter.presentedViewController == nil }
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents, .files])
        try secondaryExpect(ui.leases.entry(id: visible) == nil, "Regrant revived the old external sheet")
        try secondaryExpect(!delivered(), "Queued external-share callback revived after regrant")

        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        let ownID = try id(await present(host: host, kind: "share", model: ["files": .array([.string(own.path)])], handle: 240))
        drain(probe)
        try await wait { ui.leases.entry(id: ownID)?.state.isPresented == true }
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents, .files])
        try host.setGrantedPermissions(id: "secondary", permissions: [.intents])
        try secondaryExpect(ui.leases.entry(id: ownID)?.state.isPresented == true, "Own-root share incorrectly depended on files")
        guard let sheet = presenter.presentedViewController as? UIActivityViewController else { throw SecondaryUIFailure(message: "Missing actual native share sheet") }
        sheet.dismiss(animated: false)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        try await wait { ui.leases.entry(id: ownID) == nil && probe.with { $0.released.contains(242) } }
        try budgetFree(budget)
    }
}
#endif
