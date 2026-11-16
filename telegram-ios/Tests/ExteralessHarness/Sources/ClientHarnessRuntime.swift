import AccountContext
import ClientHarnessAppContext
import Foundation
import PluginHost
import Postbox
import TelegramCore
import TelegramUI

@MainActor
final class ClientHarnessRuntime {
    nonisolated static let pluginId = "clientUIFixture"
    let services: ClientHarnessServices
    let engine: ClientHarnessObservedEngine
    let host: PluginHost
    private let binding: NativeBridgeBinding
    private let callbacks: PluginCallbackDispatcher
    private var settingsAuthority: PluginUISettingsActionAuthority?
    private let journal: ClientHarnessJournal
    private weak var context: ClientHarnessAccountContext?
    private var scopeActive = true
    private(set) var ui: PluginUIBridgeExtension!
    private(set) var observedUI: ClientHarnessObservedUI!
    private(set) var epochs: [String] = []
    private var stopped = false

    init(root: URL, context: ClientHarnessAccountContext, scale: Double, journal: ClientHarnessJournal) throws {
        self.context = context
        self.journal = journal
        self.services = ClientHarnessServices(root: root, recordId: context.account.id.int64,
            userId: context.account.peerId.id._internalGetInt64Value(), scale: scale, journal: journal)
        self.engine = ClientHarnessObservedEngine(journal: journal)
        let plugins = try self.services.serviceStorage.pluginsDirectory()
        try clientHarnessRequire(try FileManager.default.contentsOfDirectory(atPath: plugins.path).isEmpty,
            "dedicated plugin directory must start empty")
        var config = PythonRuntimeConfiguration.standard(bundle: .main)
        config.pluginRootDirectory = plugins.path
        let resources = Bundle.main.resourceURL!
        config.compatibilityDirectories = [resources.appendingPathComponent("python").path,
            resources.appendingPathComponent("python/sdk").path,
            resources.appendingPathComponent("python/vendor").path, plugins.path]
        self.host = try PluginHost(engine: self.engine,
            configuration: .init(runtime: config, interpreters: .init(maxInterpreters: 2, callTimeout: 2), storageDirectory: plugins),
            services: .init(messages: self.services, settings: self.services, ui: self.services),
            log: { journal.record("host-log", ["message": String($0.prefix(1000))]) })
        self.binding = NativeBridgeBinding(services: self.host.bridge)
        self.callbacks = PluginCallbackDispatcher(host: self.host,
            log: { journal.reject("callback dispatcher: " + $0) })
        let callbacks = self.callbacks
        let gate = PluginUICallbackGate()
        let recordId = context.account.id.int64
        let settingsAuthority = PluginUISettingsActionAuthority(captureOwner: { callbacks.captureOwner($0) },
            accountIndex: { $0 == recordId ? 41 : nil })
        self.settingsAuthority = settingsAuthority
        settingsAuthority.update(context: context)
        PluginUISettingsActionRegistry.install(settingsAuthority)
        self.ui = PluginUIBridgeExtension(
            captureOwner: { callbacks.captureOwner($0) },
            callback: { owner, handle, method, json in
                let admitted = callbacks.callback(owner, handle, method, json,
                    shouldExecute: { gate.permits(owner: owner, argumentsJSON: json) },
                    guaranteed: PluginUICallbackGate.isTerminal(argumentsJSON: json))
                journal.record("ui-callback-admission", ["accepted": admitted, "terminal": PluginUICallbackGate.isTerminal(argumentsJSON: json)])
                if !admitted { journal.reject("UI callback rejected") }
                return admitted
            },
            release: { owner, handles in
                let admitted = callbacks.release(owner, handles)
                journal.record("ui-release-admission", ["accepted": admitted, "count": handles.count])
                if !admitted { journal.reject("UI release rejected") }
                return admitted
            },
            hasPermission: { callbacks.hasPermission($0, $1) },
            accountIndex: { $0 == recordId ? 41 : nil },
            settingsController: { [weak self] context, id, title, path in
                guard let self else { return nil }
                return exteralessPluginSettingsController(context: context, actions: self.actions(), pluginId: id,
                    title: title, pagePath: path,
                    actionScope: self.settingsAuthority?.capture(context: context, pluginId: id), scopeIsCurrent: self.captureScope(id))
            })
        gate.bind(self.ui)
        self.observedUI = ClientHarnessObservedUI(provider: self.ui, host: self.host, journal: journal)
        self.host.bridge.extensionProvider = self.observedUI
        self.host.bridge.onOwnedCallback = { _, _, _, _, _, _ in
            journal.reject("general callback scheduler is not provided by this bounded fixture")
            return false
        }
        self.ui.update(context: context)
    }

    func start() async throws {
        try clientHarnessRequire(!self.engine.isProcessInitialized, "Python process was already initialized")
        try self.binding.install()
        try await self.host.start()
        try clientHarnessRequire(self.host.pluginList().isEmpty, "host discovered an unowned plugin")
        guard let input = Bundle.main.url(forResource: "client_ui_fixture", withExtension: "plugin") else {
            throw ClientHarnessFailure(description: "fixture resource missing from main bundle")
        }
        var metadata = try await self.host.readPluginMetadata(sourceURL: input)
        try clientHarnessRequire(metadata.id == Self.pluginId && metadata.requirements.isEmpty,
            "only the known, dependency-free fixture may be installed")
        metadata.enabled = false
        let installed = try await self.host.installPlugin(sourceURL: input, metadata: metadata)
        try clientHarnessRequire(!installed.loaded && !installed.enabled, "disabled fixture installation executed Python")
        guard let copied = installed.path else { throw ClientHarnessFailure(description: "fixture install has no source") }
        let original = try Data(contentsOf: input)
        let staged = try Data(contentsOf: URL(fileURLWithPath: copied))
        try clientHarnessRequire(original == staged, "installed fixture bytes differ")
        try self.host.setGrantedPermissions(id: Self.pluginId, permissions: [.ui, .intents])
        try await self.host.setPluginEnabled(id: Self.pluginId, true)
        try self.noteOwner()
        try clientHarnessRequire(self.host.pluginList().count == 1 && self.host.pluginList()[0].loaded
            && self.host.pluginList()[0].hasSettings, "actual SDK fixture did not load with settings")
        self.journal.record("native-fixture-ready")
    }

    func noteOwner() throws {
        guard let owner = self.host.callbackOwner(id: Self.pluginId) else {
            throw ClientHarnessFailure(description: "fixture has no real CallbackOwner")
        }
        if self.epochs.last != owner.wireToken { self.epochs.append(owner.wireToken) }
    }

    private func captureScope(_ id: String) -> @MainActor () -> Bool {
        let owner = self.host.callbackOwner(id: id)
        return { [weak self, weak context = self.context] in
            guard let self, let context, let owner else { return false }
            return self.scopeActive && self.context === context && self.host.callbackOwner(id: id) == owner
        }
    }

    func actions() -> PluginManagerActions {
        let host = self.host
        let journal = self.journal
        return PluginManagerActions(status: { "Real CPython \(self.engine.apiVersion) · fixture services" },
            snapshot: { host.pluginList() },
            importPlugin: { _ in throw ClientHarnessFailure(description: "client-ui-harness: document import is not provided") },
            setEnabled: { id, enabled in
                try Self.requireOwned(id)
                try await host.setPluginEnabled(id: id, enabled)
                journal.record("fixture-enabled", ["enabled": enabled])
            },
            remove: { id in try Self.requireOwned(id); try await host.uninstallPlugin(id: id) },
            settings: { id in
                try Self.requireOwned(id)
                let read = try PluginUISettingsReadExecution.require(pluginId: id)
                let json = try await host.settingsJSON(id: id, account: read.account, expectedOwner: read.owner,
                    shouldExecute: { read.isCurrent }, page: PluginSettingsPageExecution.current)
                guard read.isCurrent else { throw PluginHostError.superseded("Harness settings page/read expired") }
                return json
            },
            updateSetting: { id, key, value in
                try Self.requireOwned(id)
                let invocation = try PluginUISettingsActionExecution.require(pluginId: id)
                try await host.updateSetting(id: id, key: key, valueJSON: value,
                    expectedOwner: invocation.owner, account: invocation.account, shouldExecute: { invocation.isCurrent })
            },
            click: { id, callback in
                try Self.requireOwned(id)
                let invocation = try PluginUISettingsActionExecution.require(pluginId: id)
                try await host.clickSetting(id: id, callbackId: callback,
                    expectedOwner: invocation.owner, account: invocation.account, shouldExecute: { invocation.isCurrent })
            },
            logs: { self.services.serviceLogs.entries.map { $0.message } },
            settingsScope: { [weak self] id in self?.captureScope(id) ?? { false } })
    }

    nonisolated private static func requireOwned(_ id: String) throws {
        try clientHarnessRequire(id == Self.pluginId, "action addressed an unowned plugin")
    }

    func isVisible(_ kind: String) throws -> Bool {
        guard self.observedUI.lastId(kind) != nil else { return false }
        let state = try self.uiState(kind)
        try clientHarnessRequire(state["error"] == nil || state["error"] is NSNull, "native presentation failed: " + kind)
        return state["visible"] as? Bool == true
    }

    /// Read the REAL lease store + native view-window visibility. This is an
    /// observation, not a fake C-origin request or evidence of SDK transport.
    func uiState(_ kind: String) throws -> [String: Any] {
        guard let id = self.observedUI.lastId(kind), let owner = self.host.callbackOwner(id: Self.pluginId) else {
            throw ClientHarnessFailure(description: "missing actual UI lease: " + kind)
        }
        let request: [String: Any] = ["op": "call", "fqcn": "exteraless.ios.Runtime", "member": "uiState",
            "args": [id], "kwargs": [:], "ownerToken": owner.wireToken]
        guard let json = try self.ui.dispatch(requestJSON: clientHarnessJSON(request), pluginId: Self.pluginId),
              let reply = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              reply["ok"] as? Bool == true, let state = reply["value"] as? [String: Any] else {
            throw ClientHarnessFailure(description: "uiState did not return a native lease state")
        }
        return state
    }

    func stored(_ key: String) throws -> PluginJSONValue {
        try self.services.serviceStorage.getSetting(pluginId: Self.pluginId, key: key, defaultValue: .null)
    }

    func stop() async throws {
        guard !self.stopped else { return }
        self.settingsAuthority?.clearContext()
        PluginUISettingsActionRegistry.install(nil)
        self.scopeActive = false
        self.ui.clearContext()
        await self.host.stop()
        self.binding.uninstall()
        self.stopped = true
        try clientHarnessRequire(!self.engine.isProcessInitialized && !self.host.isRunning,
            "native CPython did not finalize")
        try clientHarnessRequire(self.engine.snapshot["allDestroyed"] as? Bool == true,
            "native interpreter cleanup incomplete")
        try clientHarnessRequire(self.journal.unexpectedServices.isEmpty, "unprovided native service was requested")
        self.journal.record("native-cleanup-complete")
    }

    var snapshot: [String: Any] {
        ["engine": self.engine.snapshot, "ui": self.observedUI.snapshot, "hostEpochs": self.epochs,
         "stopped": self.stopped, "realPython": true, "telegramServices": "strict fixture",
         "uikitProvider": "TelegramUI.PluginUIBridgeExtension"]
    }
}
