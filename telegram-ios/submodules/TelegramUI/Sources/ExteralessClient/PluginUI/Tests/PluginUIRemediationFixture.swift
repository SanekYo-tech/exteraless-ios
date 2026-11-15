#if PLUGIN_UI_REMEDIATION_FIXTURE
import ExteralessCore
import Foundation
import PluginHost

private struct HNSFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func hnsExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw HNSFixtureError(message) }
}

private func hnsReject(_ body: () throws -> Void) throws {
    do { try body() }
    catch is HNSFixtureError { throw HNSFixtureError("Fixture setup failed instead of rejecting native work") }
    catch { return }
    throw HNSFixtureError("Expected native rejection")
}

private final class HNSFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true
    var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
    func revoke() { self.lock.lock(); self.stored = false; self.lock.unlock() }
}

private final class HNSTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { self.lock.lock(); self.stored.append(value); self.lock.unlock() }
    var values: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
}

private func hnsWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw HNSFixtureError("One-second fixture admission deadline exceeded") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func hnsWaitAsync(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while !(await predicate()) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw HNSFixtureError("One-second native queue deadline exceeded") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func hnsScriptArguments(_ source: String, method: String) throws -> [String]? {
    let prefix = "_exteraless_runtime.\(method)("
    guard source.hasPrefix(prefix) else { return nil }
    return try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
}

private final class HNSHostReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var host: PluginHost?
    func set(_ host: PluginHost) { self.lock.lock(); self.host = host; self.lock.unlock() }
    func get() -> PluginHost? { self.lock.lock(); defer { self.lock.unlock() }; return self.host }
}

private final class HNSConsumerEffects: @unchecked Sendable {
    struct Item: Sendable {
        let effect: PluginUIRetainedEffect
        let owner: PluginHost.CallbackOwner
    }
    private let lock = NSLock()
    private var stored: [Item] = []
    func add(_ effect: PluginUIRetainedEffect, owner: PluginHost.CallbackOwner) {
        self.lock.lock(); self.stored.append(Item(effect: effect, owner: owner)); self.lock.unlock()
    }
    var items: [Item] { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
}

private final class HNSTemporaryFiles {
    let root: URL
    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-ui-hns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: self.root) }
}

private final class HNSManualQueue {
    private var jobs: [() throws -> Void] = []
    var count: Int { self.jobs.count }
    func append(_ work: @escaping () throws -> Void) { self.jobs.append(work) }
    func runOne() throws { try self.jobs.removeFirst()() }
}

private final class HNSDeferredOpen {
    var original: (() -> Void)?
    var completion: (() -> Void)?
    func resume() { let original = self.original; self.original = nil; original?() }
    func finish() { let completion = self.completion; self.completion = nil; completion?() }
    func discard() { self.original = nil }
}

/// A deterministic engine fixture, not a CPython/SDK execution claim. The actual
/// PluginHost, interpreter worker, expected-owner checks and mailbox predicate run.
private final class HNSSettingsEngine: CPythonEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var initialized = false
    private var next: Int64 = 0
    private var threads: [Int64: Thread] = [:]
    let scripts = HNSTrace()
    let blocked = HNSTrace()
    let resume = DispatchSemaphore(value: 0)
    private let onScript: (@Sendable (InterpRef, String) throws -> String?)?

    init(onScript: (@Sendable (InterpRef, String) throws -> String?)? = nil) { self.onScript = onScript }

    var apiVersion: String { "owned-HNS-fixture" }
    var isProcessInitialized: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.initialized }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws { self.lock.lock(); self.initialized = true; self.lock.unlock() }
    func finalizeProcess() throws { self.lock.lock(); self.initialized = false; self.lock.unlock() }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        self.lock.lock(); defer { self.lock.unlock() }
        self.next += 1
        self.threads[self.next] = Thread.current
        return InterpRef(raw: self.next)
    }
    func destroyInterpreter(_ reference: InterpRef) throws {
        try self.requireThread(reference)
        self.lock.lock(); self.threads.removeValue(forKey: reference.raw); self.lock.unlock()
    }
    private func requireThread(_ reference: InterpRef) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.threads[reference.raw] === Thread.current else { throw HNSFixtureError("Settings invocation left its native owner worker") }
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        try self.requireThread(reference)
        self.scripts.add(source)
        if let value = try self.onScript?(reference, source) { return value }
        if source.hasPrefix("_exteraless_runtime.invoke_handle_json(900,") {
            self.blocked.add(Thread.current.name ?? "owner")
            guard self.resume.wait(timeout: .now() + 3) == .success else { throw HNSFixtureError("Three-second worker gate expired") }
        }
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            return "{\"metadata\":{\"id\":\"fixture\"},\"handles\":{\"app_event\":true},\"has_settings\":true}"
        }
        return "null"
    }
}

/// Positive Core control: this fixture owns an immutable native declarative
/// schema and all admission state. It holds the pin during actual Core I/O.
private final class HNSNativeSchemaPin: ToolsPluginSchemaValidity, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [String: ToolsPluginSchemaEvidence]
    private var active = true
    init(_ expected: [String: ToolsPluginSchemaEvidence]) { self.expected = expected }
    func revoke() { self.lock.lock(); self.active = false; self.lock.unlock() }
    func withCurrent<T>(evidence: [String: ToolsPluginSchemaEvidence], use: ToolsPluginSchemaUse, _ body: () throws -> T) throws -> T {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.active, evidence == self.expected else { throw ToolsError.unavailable("Fixture source/owner/revision authority expired") }
        return try body()
    }
}

@main private enum PluginUIRemediationFixture {
    static func main() async throws {
        try self.cleanupDuringRetirement()
        try self.cleanupCannotRevokeReplacement()
        try self.effectCountAndBytes()
        try self.cancelledEffectsRetainCredit()
        try self.deferredEffectsRetainCredit()
        try self.dynamicSchemasNeverAuthorize()
        try self.sourceAndUnloadSnapshotsAreChecked()
        for change in ["account", "accountClick", "page", "revision", "cancel"] { try await self.queuedSettingAction(change: change) }
        try await self.expectedOwnerCapturedBeforeAwait()
        for outcome in ["timeout", "cancel", "deferredTimeout", "success"] { try await self.batchConsumer(outcome: outcome) }
        for change in ["reload", "account", "page", "revision", "cancel"] { try await self.queuedSettingsRead(change: change) }
        try self.initialReadAndSuccessfulPublish()
        print("PluginUI HNS fixture: 23 scenarios passed (Foundation + real Host worker with fixture engine; no UIKit, CPython, account or network execution)")
    }

    private struct Owner: Hashable, Sendable { let plugin: String; let token: String }
    private typealias Store = PluginUILeaseStore<Owner>
    private static func callback(_ handle: Int64) throws -> PluginUICallback { try PluginUICallback(.object(["__handle__": .integer(handle)])) }

    private static func cleanupDuringRetirement() throws {
        let store = Store()
        _ = store.replaceScope(accountRecordId: 42)
        let owner = Owner(plugin: "fixture", token: "immutable-old")
        let entry = try store.accept(pluginId: owner.plugin, owner: owner, content: .presentation(PluginUIModel(kind: .alert, value: .object([:]))),
                                     callbacks: ["closed": callback(1), "dismiss": callback(2)])
        let origin = try PluginUIRequestOrigin(["ownerToken": .string(owner.token)])
        // There is deliberately no active-owner provider available to this path.
        let cleanup = try store.revoke(reference: entry.state.id.uuidString, pluginId: owner.plugin, menu: false) { stored in
            try origin.validate(currentToken: stored.token)
        }
        try hnsExpect(cleanup.changed && store.beginPresentation(id: entry.state.id) == nil, "Retiring cleanup required an active owner or resurrected presentation")
        let repeated = try store.revoke(reference: entry.state.id.uuidString, pluginId: owner.plugin, menu: false) { try origin.validate(currentToken: $0.token) }
        try hnsExpect(!repeated.changed, "Repeated cleanup scheduled another dismissal")
        guard let retired = store.finish(id: entry.state.id, notify: false) else { throw HNSFixtureError("Missing retirement") }
        try hnsExpect(retired.handles == [1, 2] && retired.deliveries.isEmpty, "Unload cleanup invoked users or lost original handles")
        store.completeRetirement(id: retired.id, owner: retired.owner)
        try hnsReject { _ = try store.revoke(reference: entry.state.id.uuidString, pluginId: owner.plugin, menu: false) { _ in
            try PluginUIRequestOrigin(["ownerToken": .string("replacement")]).validate(currentToken: owner.token)
        } }
        let closed = try store.revoke(reference: entry.state.id.uuidString, pluginId: owner.plugin, menu: false) { try origin.validate(currentToken: $0.token) }
        try hnsExpect(!closed.changed && store.finish(id: entry.state.id) == nil, "Terminal cleanup released a second time")
    }

    private static func cleanupCannotRevokeReplacement() throws {
        let store = Store()
        _ = store.replaceScope(accountRecordId: 42)
        let old = Owner(plugin: "fixture", token: "old")
        let fresh = Owner(plugin: "fixture", token: "new")
        let model = try PluginUIMenuModel(.object(["menu_type": .string("MAIN_MENU"), "item_id": .string("stable"), "text": .string("Menu")]))
        _ = try store.registerMenu(pluginId: old.plugin, owner: old, model: model, callback: callback(3))
        let replacement = try store.registerMenu(pluginId: fresh.plugin, owner: fresh, model: model, callback: callback(4))
        for retired in replacement.retired { store.completeRetirement(id: retired.id, owner: retired.owner) }
        let origin = try PluginUIRequestOrigin(["ownerToken": .string(old.token)])
        try hnsReject { _ = try store.revoke(reference: "stable", pluginId: old.plugin, menu: true) { try origin.validate(currentToken: $0.token) } }
        try hnsExpect(store.entry(id: replacement.entry.state.id)?.owner == fresh, "Old cleanup removed a replacement menu")
        let current = try PluginUIRequestOrigin(["ownerToken": .string(fresh.token)])
        let removed = try store.revoke(reference: "stable", pluginId: fresh.plugin, menu: true) { try current.validate(currentToken: $0.token) }
        try hnsExpect(removed.retirement?.handles == [4], "Cleanup selected a different owner's callback")
    }

    private static func effectCountAndBytes() throws {
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 2, maximumBytes: 12)
        let queue = HNSManualQueue()
        let flag = HNSFlag()
        let first = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 8, isCurrent: { flag.value })
        queue.append {
            try hnsReject { _ = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 1, isCurrent: { flag.value }) }
            first.finish() // Executing work held count and bytes until this point.
        }
        try hnsReject { _ = try PluginUIRetainedEffect(budget: budget, pluginId: "other", bytes: 5, isCurrent: { flag.value }) }
        let second = try PluginUIRetainedEffect(budget: budget, pluginId: "other", bytes: 4, isCurrent: { flag.value })
        try hnsReject { _ = try PluginUIRetainedEffect(budget: budget, pluginId: "third", bytes: 0, isCurrent: { flag.value }) }
        try hnsExpect(queue.count == 1, "Rejected effect reached the manual main queue")
        try queue.runOne()
        second.finish()
        let next = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 12, isCurrent: { flag.value })
        first.finish() // Old completion cannot return the new ticket's credit.
        try hnsReject { _ = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 1, isCurrent: { flag.value }) }
        next.finish()
    }

    private static func cancelledEffectsRetainCredit() throws {
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 1, maximumBytes: 8)
        let flag = HNSFlag()
        let queue = HNSManualQueue()
        let effects = HNSTrace()
        let effect = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 8, isCurrent: { flag.value })
        queue.append {
            defer { effect.finish() }
            if effect.permitsExecution { effects.add("clipboard") }
        }
        flag.revoke()
        let fresh = HNSFlag()
        for _ in 0..<16 {
            try hnsReject { _ = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 1, isCurrent: { fresh.value }) }
        }
        try hnsExpect(queue.count == 1, "Cancelled retained payload allowed an unbounded main backlog")
        try queue.runOne()
        try hnsExpect(effects.values.isEmpty, "Expired effect reached the native sink")
        let next = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 8, isCurrent: { fresh.value })
        next.finish()
    }

    private static func deferredEffectsRetainCredit() throws {
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 1, maximumBytes: 8)
        let flag = HNSFlag()
        let queue = HNSManualQueue()
        let barrier = HNSDeferredOpen()
        func enqueue() throws {
            let effect = try PluginUIRetainedEffect(budget: budget, pluginId: "fixture", bytes: 8, isCurrent: { flag.value })
            queue.append {
                barrier.original = { [weak barrier] in
                    guard effect.permitsExecution, let barrier else { effect.finish(); return }
                    barrier.completion = { effect.finish() }
                }
            }
        }
        try enqueue()
        try queue.runOne()
        try hnsReject { _ = try budget.reserve(pluginId: "fixture", bytes: 1) }
        barrier.resume()
        try hnsReject { _ = try budget.reserve(pluginId: "fixture", bytes: 1) }
        barrier.finish()
        try enqueue()
        try queue.runOne()
        flag.revoke()
        try hnsReject { _ = try budget.reserve(pluginId: "fixture", bytes: 1) }
        barrier.discard() // Handled/cancelled path never calls original.
        let recovered = try budget.reserve(pluginId: "fixture", bytes: 8)
        recovered.finish()
    }

    private static func export(_ location: ToolsBackupPluginLocation) throws -> ToolsBackupInspection {
        let bytes = try ToolsBackupArchive.export(settings: [:], definitions: [], appVersion: "HNS-fixture", plugins: location)
        return try ToolsBackupArchive.inspect(bytes, definitions: [])
    }

    private static func dynamicSchemasNeverAuthorize() throws {
        let files = try HNSTemporaryFiles()
        let directory = files.root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = try ToolsPluginSchemaCache.settingsFileName(pluginId: "fixture")
        let file = directory.appendingPathComponent(name)
        let s1 = Data("[{\"type\":\"slider\",\"key\":\"amount\",\"min\":0,\"max\":100}]".utf8)
        let s2 = Data("[{\"type\":\"slider\",\"key\":\"amount\",\"min\":0,\"max\":1}]".utf8)
        let cache = PluginUIUnprovenSchemaCache()
        let owner = "account:42:epoch:same"
        try Data("{\"mode\":0,\"amount\":80}".utf8).write(to: file)
        try cache.recordDynamic(fileName: name, owner: owner, cachedNativeSettingsJSON: s1)
        let captured = try cache.location(directory: directory, activeOwners: [name: owner])
        try hnsExpect(try self.export(captured).payload.pluginSettings.isEmpty, "Epoch-only S1 exported dynamic fields")
        try cache.recordDynamic(fileName: name, owner: owner, cachedNativeSettingsJSON: s1)
        let repeated = try cache.location(directory: directory, activeOwners: [name: owner])
        try hnsExpect(try self.export(repeated).payload.pluginSettings.isEmpty, "Repeated equal JSON was treated as immutable proof")
        let current = Data("{\"mode\":1,\"amount\":1}".utf8)
        try current.write(to: file)
        try cache.recordDynamic(fileName: name, owner: owner, cachedNativeSettingsJSON: s2)
        try hnsExpect(try self.export(captured).payload.pluginSettings.isEmpty, "Captured S1 permission survived same-epoch mode/S2 change")
        let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture", clientSettings: [:],
            pluginSettings: [.init(path: name, values: ["amount": .integer(80)])], clientStoredKeys: [])
        let archive = try ToolsBackupArchive.encode(payload)
        let inspection = try ToolsBackupArchive.inspect(archive, definitions: [])
        try hnsExpect(!archive.isEmpty && inspection.payload.pluginSettings == payload.pluginSettings,
            "The dynamic-schema fixture did not construct and inspect its real archive")
        let writes = HNSTrace()
        let settings = ToolsBackupSettingsAccess(snapshot: { .init(definitions: [], values: [:], storedKeys: []) }, applyAtomically: { _, _, _ in writes.add("client") })
        do {
            _ = try ToolsBackupRestorer().restore(inspection, settings: settings, plugins: captured)
            throw HNSFixtureError("Unproven dynamic schema unexpectedly authorized restore")
        } catch let error as ToolsError {
            try hnsExpect(error == .invalidArchive("Plugin backup requires current native schema evidence."),
                "Restore failed before/instead of its schema-authority boundary: \(error)")
        }
        try hnsExpect(try Data(contentsOf: file) == current && writes.values.isEmpty, "Rejected dynamic restore mutated a store")
        cache.clear() // Runtime's pre-drain invalidation.
        try Data("{\"mode\":2}".utf8).write(to: file) // unload writes after old location capture
        let postDrain = try cache.location(directory: directory, activeOwners: [:])
        try hnsExpect(try self.export(postDrain).payload.pluginSettings.isEmpty, "Post-drain location revived pre-unload dynamic schema")
    }

    private static func sourceAndUnloadSnapshotsAreChecked() throws {
        let files = try HNSTemporaryFiles()
        let directory = files.root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = try ToolsPluginSchemaCache.settingsFileName(pluginId: "fixture")
        let file = directory.appendingPathComponent(name)
        let source = files.root.appendingPathComponent("fixture.native-schema")
        let sourceBytes = Data("native immutable fixture schema v1".utf8)
        let settings = Data("{\"enabled\":true}".utf8)
        let schema = Data("[{\"type\":\"switch\",\"key\":\"enabled\"}]".utf8)
        try sourceBytes.write(to: source)
        try settings.write(to: file)
        let evidence = ToolsPluginSchemaEvidence(accountId: 42, owner: "exact-owner", sourceURL: source,
            sourceSHA256: ToolsSHA256.hex(sourceBytes), settingsRevision: 7, settingsSHA256: ToolsSHA256.hex(settings),
            schemaSHA256: ToolsSHA256.hex(schema), guarantee: .nativeImmutable)
        let cache = ToolsPluginSchemaCache()
        let pin = HNSNativeSchemaPin([name: evidence])
        try cache.record(fileName: name, owner: evidence.owner, cachedNativeSettingsJSON: schema, evidence: evidence)
        let location = try cache.location(directory: directory, activeOwners: [name: evidence.owner], validity: pin)
        try hnsExpect(try self.export(location).payload.pluginSettings.count == 1, "Valid native immutable control failed")
        try Data("native replacement v2".utf8).write(to: source)
        try hnsReject { _ = try self.export(location) }
        try sourceBytes.write(to: source)
        try Data("{\"enabled\":false}".utf8).write(to: file) // unload mutation, same callback owner
        try hnsReject { _ = try self.export(location) }
        try settings.write(to: file)
        pin.revoke() // ABA bytes do not revive a revoked revision/owner pin.
        try hnsReject { _ = try self.export(location) }
    }

    private static func makeHost(_ files: HNSTemporaryFiles, engine: HNSSettingsEngine) async throws -> PluginHost {
        let source = files.root.appendingPathComponent("fixture.plugin")
        try Data("# owned fixture engine input; never executed by Python".utf8).write(to: source)
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: files.root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 4), queue: .init(dispatchTimeout: 4), storageDirectory: files.root))
        try await host.start(safeMode: true)
        let installed = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "fixture", enabled: true))
        try hnsExpect(installed.loaded, "Fixture failed to load: \(installed.loadError ?? "unknown")")
        return host
    }

    private static func makeScope(host: PluginHost, account: PluginUISettingsAccountGate) throws -> PluginUISettingsActionScope {
        guard let owner = host.callbackOwner(id: "fixture"), let token = account.snapshot else { throw HNSFixtureError("Missing fixture owner/account token") }
        let scope = PluginUISettingsActionScope(owner: owner, accountGate: account, accountToken: token, captureOwner: { host.callbackOwner(id: $0) })
        scope.publish()
        scope.setVisible(true)
        return scope
    }

    private static func queuedSettingAction(change: String) async throws {
        let files = try HNSTemporaryFiles()
        let engine = HNSSettingsEngine()
        let host = try await self.makeHost(files, engine: engine)
        do {
            let account = PluginUISettingsAccountGate()
            account.replace(recordId: 9000, index: 41)
            let scope = try self.makeScope(host: host, account: account)
            let invocation = try scope.capture()
            let prior = Task { try await host.invokeCallback(id: "fixture", handle: 900, method: "run", expectedOwner: invocation.owner) }
            defer { engine.resume.signal() }
            try await hnsWait { !engine.blocked.values.isEmpty }
            let checks = HNSTrace()
            let queued = Task {
                try await PluginUISettingsActionExecution.withInvocation(invocation) {
                    let captured = try PluginUISettingsActionExecution.require(pluginId: "fixture")
                    let predicate: @Sendable () -> Bool = {
                        checks.add(Thread.current.name ?? "caller")
                        return captured.isCurrent
                    }
                    if change == "accountClick" {
                        try await host.clickSetting(id: "fixture", callbackId: "stale",
                            expectedOwner: captured.owner, account: captured.account, shouldExecute: predicate)
                    } else {
                        try await host.updateSetting(id: "fixture", key: "stale", valueJSON: "true",
                            expectedOwner: captured.owner, account: captured.account, shouldExecute: predicate)
                    }
                }
            }
            try await hnsWait { !checks.values.isEmpty }
            switch change {
            case "account", "accountClick": account.replace(recordId: 9001, index: 42)
            case "page": scope.setVisible(false)
            case "revision": scope.invalidate(); scope.publish()
            default: queued.cancel()
            }
            engine.resume.signal()
            try await prior.value
            do { try await queued.value; throw HNSFixtureError("Revoked queued settings action ran") }
            catch PluginHostError.superseded { }
            catch is CancellationError { }
            try hnsExpect(!engine.scripts.values.contains { $0.contains("setting_changed_json") || $0.contains("setting_click_json") }, "Old settings body reached the native worker")
            if change != "cancel" { try hnsExpect(checks.values.last == engine.blocked.values.last, "Execution predicate did not run on the actual owner worker") }
        } catch {
            engine.resume.signal()
            await host.stop()
            throw error
        }
        await host.stop()
    }

    private static func expectedOwnerCapturedBeforeAwait() async throws {
        let files = try HNSTemporaryFiles()
        let engine = HNSSettingsEngine()
        let host = try await self.makeHost(files, engine: engine)
        do {
            let account = PluginUISettingsAccountGate()
            account.replace(recordId: 9000, index: 41)
            let scope = try self.makeScope(host: host, account: account)
            let old = try scope.capture()
            try await host.reloadPlugin(id: "fixture")
            do {
                try await host.clickSetting(id: "fixture", callbackId: "old", expectedOwner: old.owner,
                    account: old.account, shouldExecute: { old.isCurrent })
                throw HNSFixtureError("Old owner was replaced during settings admission")
            } catch PluginHostError.superseded { }
            try hnsExpect(!engine.scripts.values.contains { $0.contains("setting_click_json") }, "Stale callback reached a replacement interpreter")
            let fresh = try self.makeScope(host: host, account: account)
            let current = try fresh.capture()
            try await PluginUISettingsActionExecution.withInvocation(current) {
                let value = try PluginUISettingsActionExecution.require(pluginId: "fixture")
                try await host.clickSetting(id: "fixture", callbackId: "current", expectedOwner: value.owner,
                    account: value.account, shouldExecute: { value.isCurrent })
            }
            let source = engine.scripts.values.last { $0.contains("setting_click_json") }
            try hnsExpect(source?.hasSuffix(", 41)") == true, "Settings callback did not use the captured SDK account index")
        } catch { await host.stop(); throw error }
        await host.stop()
    }

    /// A constructs the actual UI consumer on its Host owner worker, then B holds
    /// the batch. Only the manual-main sink is simulated; no common-lease stand-in.
    private static func batchConsumer(outcome: String) async throws {
        let files = try HNSTemporaryFiles()
        let hostReference = HNSHostReference()
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 1, maximumBytes: 8)
        let account = HNSFlag()
        let effects = HNSConsumerEffects()
        let betaEntered = HNSTrace()
        let betaGate = DispatchSemaphore(value: 0)
        let isSend = outcome == "cancel"
        let external = HNSFlag()
        let engine = HNSSettingsEngine(onScript: { reference, source in
            if let arguments = try hnsScriptArguments(source, method: "load_json") {
                let id = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
                return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":true,\"send_message\":true},\"has_settings\":false}"
            }
            guard source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("ui_followup") else { return nil }
            if reference.raw == 1 {
                guard let host = hostReference.get(), let owner = host.callbackOwner(id: "alpha") else { throw HNSFixtureError("Missing actual A owner") }
                let effect = try PluginUIRetainedEffect(budget: budget, pluginId: "alpha", bytes: 8, isCurrent: { [weak host] in
                    host?.callbackOwner(id: "alpha") == owner && host?.permissions.has("alpha", .ui) == true && account.value
                })
                effects.add(effect, owner: owner)
            } else if reference.raw == 2 {
                betaEntered.add("B")
                guard betaGate.wait(timeout: .now() + 3) == .success else { throw HNSFixtureError("Bounded B gate expired") }
            }
            return isSend ? "{\"strategy\":\"DEFAULT\"}" : "null"
        })
        let timeout: TimeInterval = (outcome == "timeout" || outcome == "deferredTimeout") ? 0.5 : 4
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: files.root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 4), queue: .init(dispatchTimeout: timeout), storageDirectory: files.root))
        hostReference.set(host)
        do {
            try await host.start(safeMode: true)
            for id in ["alpha", "beta"] {
                let file = files.root.appendingPathComponent(id + ".plugin")
                try Data("# own fixture-engine input".utf8).write(to: file)
                let plugin = try await host.installPlugin(sourceURL: file, metadata: Plugin(id: id, enabled: true))
                try hnsExpect(plugin.loaded, "Batch fixture plugin did not load")
                try host.setGrantedPermissions(id: id, permissions: [.ui, .messagesSend])
            }
            let waiting = Task {
                if isSend {
                    _ = try await host.events.preSendMessageResult(.init(account: 41, paramsJSON: "{\"text\":\"ui_followup\"}"),
                        shouldExecute: { external.value })
                } else { try await host.deliverAppEvent("ui_followup") }
            }
            defer { betaGate.signal() }
            try await hnsWait { !betaEntered.values.isEmpty }
            guard let item = effects.items.first, effects.items.count == 1 else { throw HNSFixtureError("A did not create exactly one actual UI retained effect") }
            let sink = HNSTrace()
            let main = HNSManualQueue()
            let deferred = HNSDeferredOpen()
            let modelStore = PluginUILeaseStore<PluginHost.CallbackOwner>()
            _ = modelStore.replaceScope(accountRecordId: 9000)
            let original = try modelStore.accept(pluginId: "alpha", owner: item.owner,
                content: .presentation(PluginUIModel(kind: .alert, value: .object(["title": .string("original")]))), callbacks: [:])
            if outcome == "deferredTimeout" {
                main.append {
                    try hnsExpect(item.effect.permitsExecution, "Deferred native opening was never admitted")
                    deferred.original = {
                        guard item.effect.permitsExecution else { item.effect.finish(); return }
                        sink.add("url")
                        deferred.completion = { item.effect.finish() }
                    }
                }
                try main.runOne() // Main started; the URL barrier still owns the work.
            } else {
                main.append {
                    defer { item.effect.finish() }
                    if item.effect.permitsExecution {
                        _ = try modelStore.update(id: original.state.id, pluginId: "alpha", patch: .object(["title": .string("batch")]))
                        sink.add("clipboard")
                    }
                }
            }
            switch outcome {
            case "success":
                betaGate.signal()
                try await waiting.value
                waiting.cancel() // Completing successfully is not revocation.
            case "cancel":
                external.revoke()
                waiting.cancel()
                do { try await waiting.value; throw HNSFixtureError("Cancelled send completed successfully") }
                catch is CancellationError { }
            default:
                do { try await waiting.value; throw HNSFixtureError("Blocked batch did not time out") }
                catch PluginHostError.timeout { }
            }
            try hnsExpect(host.callbackOwner(id: "alpha") == item.owner && host.permissions.has("alpha", .ui) && account.value,
                "The fixture accidentally revoked owner/account/permission instead of the batch")
            try hnsReject { _ = try budget.reserve(pluginId: "alpha", bytes: 1) }
            if outcome == "deferredTimeout" { deferred.resume(); deferred.finish() }
            else { try main.runOne() }
            try hnsExpect(sink.values.count == (outcome == "success" ? 1 : 0), "Deferred UI consumer lost batch revocation or cancelled a successful batch")
            let next = try budget.reserve(pluginId: "alpha", bytes: 8)
            next.finish()
            _ = try modelStore.update(id: original.state.id, pluginId: "alpha", patch: .object(["progress": .integer(20)]))
            guard let modelEntry = modelStore.entry(id: original.state.id), case let .presentation(model) = modelEntry.content else { throw HNSFixtureError("Lost update model") }
            try hnsExpect(model.title == (outcome == "success" ? "batch" : "original"), "A cancelled queued update contaminated a later partial update")
            betaGate.signal()
            try await hnsWaitAsync { await host.events.queueStatistics().retainedCount == 0 }
        } catch {
            betaGate.signal()
            await host.stop()
            throw error
        }
        await host.stop()
    }

    /// The event queue, not the target settings worker, is held by another plugin.
    /// Reloading P can finish while P1's read remains queued behind that event.
    private static func queuedSettingsRead(change: String) async throws {
        let files = try HNSTemporaryFiles()
        let entered = HNSTrace()
        let gate = DispatchSemaphore(value: 0)
        let engine = HNSSettingsEngine(onScript: { _, source in
            if let arguments = try hnsScriptArguments(source, method: "load_json") {
                let id = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
                return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":\(id == "blocker")},\"has_settings\":\(id == "fixture")}"
            }
            if source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("read_block") {
                entered.add("blocker")
                guard gate.wait(timeout: .now() + 3) == .success else { throw HNSFixtureError("Bounded settings-event gate expired") }
                return "null"
            }
            if source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("create_settings") { return "[]" }
            return nil
        })
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: files.root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 4), queue: .init(dispatchTimeout: 4), storageDirectory: files.root))
        do {
            try await host.start(safeMode: true)
            for id in ["fixture", "blocker"] {
                let file = files.root.appendingPathComponent(id + ".plugin")
                try Data("# own read fixture".utf8).write(to: file)
                let plugin = try await host.installPlugin(sourceURL: file, metadata: Plugin(id: id, enabled: true))
                try hnsExpect(plugin.loaded, "Read fixture plugin failed to load")
            }
            let blocked = Task { try await host.deliverAppEvent("read_block") }
            defer { gate.signal() }
            try await hnsWait { !entered.values.isEmpty }
            let account = PluginUISettingsAccountGate()
            account.replace(recordId: 9000, index: 41)
            let scope = try self.makeScope(host: host, account: account)
            let read = try scope.captureRead()
            let queued = Task {
                try await PluginUISettingsReadExecution.withInvocation(read) {
                    let captured = try PluginUISettingsReadExecution.require(pluginId: "fixture")
                    return try await host.settingsJSON(id: "fixture", account: captured.account, expectedOwner: captured.owner,
                        shouldExecute: { captured.isCurrent })
                }
            }
            try await hnsWaitAsync { await host.events.queueStatistics().retainedCount >= 2 }
            switch change {
            case "reload": try await host.reloadPlugin(id: "fixture")
            case "account": account.replace(recordId: 9001, index: 42)
            case "page": scope.setVisible(false)
            case "revision": scope.invalidate()
            default: queued.cancel()
            }
            gate.signal()
            try await blocked.value
            do { _ = try await queued.value; throw HNSFixtureError("Expired queued read entered Python") }
            catch PluginHostError.superseded { }
            catch is CancellationError { }
            try hnsExpect(!engine.scripts.values.contains { $0.contains("create_settings") }, "Old read rebuilt callback state in the old or replacement interpreter")
            let current = try self.makeScope(host: host, account: account)
            let fresh = try current.captureRead()
            let result = try await PluginUISettingsReadExecution.withInvocation(fresh) {
                let captured = try PluginUISettingsReadExecution.require(pluginId: "fixture")
                return try await host.settingsJSON(id: "fixture", account: captured.account, expectedOwner: captured.owner,
                    shouldExecute: { captured.isCurrent })
            }
            current.invalidateActions()
            current.publish()
            try hnsExpect(result == "[]" && fresh.isCurrent, "Normal result publication cancelled its successful read")
            try hnsExpect(engine.scripts.values.filter { $0.contains("create_settings") }.count == 1, "Fresh read was missing or duplicated")
        } catch { gate.signal(); await host.stop(); throw error }
        await host.stop()
    }

    private static func initialReadAndSuccessfulPublish() throws {
        let page = PluginUISettingsPageGate()
        try hnsReject { _ = try page.captureRead() }
        page.beginAppearance()
        let first = try page.captureRead()
        try hnsReject { _ = try page.capture() }
        page.invalidateActions()
        page.publish()
        page.setVisible(true)
        try hnsExpect(first.isCurrent, "Initial read was cancelled by first appearance/publish")
        let newer = try page.captureRead()
        try hnsExpect(!first.isCurrent && newer.isCurrent, "A later read reused an older request identity")
        page.setVisible(false)
        page.beginAppearance()
        try hnsExpect(!newer.isCurrent, "Returning to a page resurrected its expired read")
    }
}
#endif
