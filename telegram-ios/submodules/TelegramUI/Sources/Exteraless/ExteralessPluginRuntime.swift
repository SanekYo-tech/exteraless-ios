import AccountContext
import Display
import Foundation
import PluginHooks
import PluginHost

/// Application composition root. Shared frameworks may be loaded by extensions,
/// but Python starts explicitly and only in the main application after an account
/// context is available. The interpreter work itself stays on native workers.
@MainActor
public final class ExteralessPluginRuntime: PluginHostDelegate {
    public static let shared = ExteralessPluginRuntime()
    public static let didChange = Notification.Name("ExteralessPluginRuntimeDidChange")

    public private(set) var host: PluginHost?
    public private(set) var status = "Waiting for an account"
    private let services = TelegramPluginServices()
    private var binding: NativeBridgeBinding?
    private var registration: PluginHookRegistration?
    private var startup: Task<Void, Never>?
    private var startupError: String?
    private var hasAccount = false
    private var callbackTasks: [UUID: (owner: PluginHost.CallbackOwner, task: Task<Void, Never>)] = [:]

    private init() {}

    public func update(context: AccountContext) {
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        services.update(context: context)
        hasAccount = true
        ExteralessPluginEntry.setControllerFactory { context in
            MainActor.assumeIsolated { exteralessPluginManagerController(context: context) }
        }
        start()
        refreshSubscriptions()
    }

    public func clearContext() {
        hasAccount = false
        services.clearContext()
        registration?.updateSubscriptions([])
        changed()
    }

    public func start() {
        guard startup == nil, hasAccount, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        status = "Starting Python runtime"
        changed()
        startup = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let root = try self.services.serviceStorage.rootDirectory()
                var runtime = PythonRuntimeConfiguration.standard(bundle: .main)
                runtime.pluginRootDirectory = try self.services.serviceStorage.pluginsDirectory().path
                let logs = self.services.serviceLogs
                let host = try PluginHost(
                    engine: CPythonXCFrameworkEngine(),
                    configuration: .init(runtime: runtime, storageDirectory: root),
                    services: .init(messages: self.services, settings: self.services, ui: self.services),
                    log: { logs.append(pluginId: "host", message: $0) }, delegate: self)
                let binding = NativeBridgeBinding(services: host.bridge)
                try binding.install()
                self.binding = binding
                self.host = host
                host.bridge.onCallback = { [weak self, weak host] pluginId, handle, method, json, delayMs in
                    // Capture the generation on the C worker, before the main
                    // actor hop: Python handle numbers may recur after reload.
                    guard let host, let owner = host.callbackOwner(id: pluginId) else { return }
                    Task { @MainActor [weak self] in
                        self?.enqueueCallback(host: host, owner: owner, handle: handle,
                                              method: method, json: json, delayMs: delayMs)
                    }
                }
                try await host.start()
                self.installHooks()
                self.status = "Python runtime ready"
                self.refreshSubscriptions()
                host.events.emitAppEvent("app_start")
                self.changed()
            } catch {
                self.startupError = String(describing: error)
                self.status = "Runtime error: \(error)"
                self.services.serviceLogs.append(pluginId: "host", level: .error, message: self.status)
                self.changed()
            }
        }
    }

    private func ready() async throws -> PluginHost {
        start()
        _ = await startup?.value
        guard let host, host.isRunning else {
            throw PluginHostError.runtimeFailure(startupError ?? status)
        }
        return host
    }

    public func snapshot() -> [Plugin] { host?.pluginList() ?? [] }

    public func importPlugin(url: URL) async throws {
        let host = try await ready()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let plugin = try await host.importPlugin(sourceURL: url)
        refreshSubscriptions()
        changed()
        if let error = plugin.loadError { throw PluginHostError.runtimeFailure(error) }
    }

    public func setEnabled(id: String, enabled: Bool) async throws {
        let host = try await ready()
        try await host.setPluginEnabled(id: id, enabled)
        refreshSubscriptions()
        changed()
        if enabled, let error = host.pluginList().first(where: { $0.id == id })?.loadError {
            throw PluginHostError.runtimeFailure(error)
        }
    }

    public func remove(id: String) async throws {
        let host = try await ready()
        try await host.uninstallPlugin(id: id)
        refreshSubscriptions()
        changed()
    }

    public func settings(id: String) async throws -> String {
        let host = try await ready()
        return try await host.settingsJSON(id: id, account: services.selectedAccount())
    }

    public func updateSetting(id: String, key: String, jsonValue: String) async throws {
        let host = try await ready()
        try await host.updateSetting(id: id, key: key, valueJSON: jsonValue)
        changed()
    }

    public func click(id: String, callbackId: String) async throws {
        let host = try await ready()
        try await host.clickSetting(id: id, callbackId: callbackId)
        changed()
    }

    public func logs() -> [String] {
        services.logEntries.map { "[\($0.pluginId)] \($0.level.rawValue): \($0.message)" }
    }

    public func grantedPermissions(id: String) -> [PluginPermission] {
        host?.grantedPermissions(id: id) ?? [.ui]
    }

    public func setPermissions(id: String, permissions: [PluginPermission]) async throws {
        let host = try await ready()
        try host.setGrantedPermissions(id: id, permissions: permissions)
        refreshSubscriptions()
        changed()
    }

    public func emitAppEvent(_ name: String) {
        guard let host, host.isRunning else { return }
        host.events.emitAppEvent(name)
    }

    public func terminate() async {
        for callback in callbackTasks.values { callback.task.cancel() }
        callbackTasks.removeAll()
        registration?.detach()
        registration = nil
        if let host {
            try? await host.deliverAppEvent("app_stop")
            await host.stop()
            host.bridge.onCallback = nil
        }
        binding?.uninstall()
        binding = nil
        status = "Python runtime stopped"
        changed()
    }

    public func pluginHostDidReloadPlugins(_ host: PluginHost) {
        refreshSubscriptions()
        changed()
    }

    public func pluginHost(_ host: PluginHost, didMarkNotResponding pluginId: String) {
        refreshSubscriptions()
        changed()
    }

    public func pluginHost(_ host: PluginHost, didRecover pluginId: String) {
        refreshSubscriptions()
        changed()
    }

    public func pluginHost(_ host: PluginHost, pluginId: String, didFailWithError message: String) {
        services.serviceLogs.append(pluginId: pluginId, level: .error, message: message)
        refreshSubscriptions()
        changed()
    }

    private func changed() {
        pruneCallbacks()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func enqueueCallback(host: PluginHost, owner: PluginHost.CallbackOwner, handle: Int64,
                                 method: String, json: String, delayMs: Int) {
        pruneCallbacks()
        guard self.host === host, host.callbackOwner(id: owner.pluginId) == owner else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.callbackTasks.removeValue(forKey: id) }
            do {
                if delayMs > 0 { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
                try Task.checkCancellation()
                try await host.invokeCallback(id: owner.pluginId, handle: handle, method: method,
                                              argumentsJSON: json, expectedOwner: owner)
                self.changed()
            } catch is CancellationError {
            } catch PluginHostError.superseded {
                // The retired owner has already released its native accounting.
            } catch {
                self.services.serviceLogs.append(pluginId: owner.pluginId, level: .error, message: "Callback: \(error)")
                self.changed()
            }
        }
        callbackTasks[id] = (owner, task)
    }

    private func pruneCallbacks() {
        let retired = callbackTasks.filter { host?.callbackOwner(id: $0.value.owner.pluginId) != $0.value.owner }
        for (id, callback) in retired {
            callback.task.cancel()
            callbackTasks.removeValue(forKey: id)
        }
    }

    private func installHooks() {
        guard registration == nil else { return }
        let logs = services.serviceLogs
        registration = PluginHookRouter.attach(PluginHookHandlers(
            sendMessage: { [weak self] payload, completion in
                let task = Task { @MainActor [weak self] in
                    guard let self, let host = self.host, host.isRunning,
                          let account = self.services.accountIndex(recordId: payload.accountRecordId),
                          !Task.isCancelled else {
                        completion(.keepOriginal)
                        return
                    }
                    do {
                        let decision = try await host.events.preSendMessageResult(SendMessagePayload(
                            account: account, paramsJSON: payload.jsonString()))
                        var json: [String: Any] = ["strategy": decision.strategy.rawValue]
                        if let params = decision.paramsJSON {
                            json["params"] = try JSONSerialization.jsonObject(with: Data(params.utf8))
                        }
                        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
                        let result = PluginSendResultCodec.decodeOrKeepOriginal(encoded, original: payload)
                        if !Task.isCancelled { completion(result) }
                    } catch {
                        logs.append(pluginId: "host", level: .error, message: "Send hook: \(error)")
                        if !Task.isCancelled { completion(.keepOriginal) }
                    }
                }
                return PluginHookCancellation { task.cancel() }
            },
            observe: { [weak self] event in
                do {
                    let json = try event.jsonString()
                    Task { @MainActor [weak self] in self?.forward(event, json: json) }
                } catch {
                    logs.append(pluginId: "host", level: .error, message: "Hook observation encoding: \(error)")
                }
            },
            diagnostic: { value in
                logs.append(pluginId: "host", level: .warning, message: "\(value.code.rawValue): \(value.detail)")
            }))
    }

    private func forward(_ event: PluginHookObservation, json: String) {
        guard let host, host.isRunning else { return }
        switch event {
        case .preRequest(let value):
            guard let account = services.accountIndex(recordId: value.metadata.accountRecordId) else { return }
            host.events.emitPreRequest(RequestPayload(requestName: value.metadata.requestName, account: account, requestJSON: json))
        case .postRequest(let value):
            guard let account = services.accountIndex(recordId: value.metadata.accountRecordId) else { return }
            host.events.emitPostRequest(RequestResponsePayload(requestName: value.metadata.requestName, account: account,
                                                               responseJSON: json, errorMessage: value.error?.message))
        case .update(let value):
            guard let account = services.accountIndex(recordId: value.accountRecordId) else { return }
            host.events.emitUpdate(name: value.name, account: account, updateJSON: json)
        case .updates(let value):
            guard let account = services.accountIndex(recordId: value.accountRecordId) else { return }
            host.events.emitUpdates(container: value.name, account: account, updatesJSON: [json])
        }
    }

    private func refreshSubscriptions() {
        guard let registration else { return }
        guard hasAccount, let host, host.isRunning else {
            registration.updateSubscriptions([])
            return
        }
        let mapping: [(ExtensionPointKind, PluginHookKind)] = [
            (.sendMessage, .sendMessage), (.preRequest, .preRequest),
            (.postRequest, .postRequest), (.update, .update), (.updates, .updates),
        ]
        registration.updateSubscriptions(Set(mapping.compactMap { host.events.subscribers.hasSubscribers($0.0) ? $0.1 : nil }))
    }
}
