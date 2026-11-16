import AccountContext
import ContextUI
import Display
import ExteralessCore
import Foundation
import PluginHooks
import PluginHost
import UIKit

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
    private var startupContinuation: PluginRuntimeStartupContinuation?
    private var startupScope = UUID()
    private var hasAccount = false
    private weak var currentContext: AccountContext?
    private var nativeCallbacks: PluginCallbackDispatcher?
    private var tlServices: PluginTLBridgeExtension?
    private var tlTransforms: PluginTLTransformIntegration?
    private var nativeServices: PluginNativeServicesBridgeExtension?
    private var pillServices: PluginPillBridgeExtension?
    public private(set) var pluginUI: PluginUIBridgeExtension?
    private var settingsActionAuthority: PluginUISettingsActionAuthority?
    private var managerPreferences: PluginManagerPreferences?
    private var managerPreferencesError: String?
    private var watchdogAlert: UIAlertController?
    private var warnedPlugins = Set<String>()
    private var changingRuntimeMode = false
    private var terminating = false
    private var activeOperations = 0
    private var settingsMaintenanceID: UUID?
    private var toolsRecoveryRequired = false
    private let settingsSchemaCache = PluginUIUnprovenSchemaCache()
    private var cachedSettingsOwners: [String: (owner: PluginHost.CallbackOwner, account: Int64)] = [:]
    private var frozenSettingsLocation: ToolsBackupPluginLocation?
    private var runtimeRecovery: PluginRuntimeRecovery?
    private var recoveryHealthyTask: Task<Void, Never>?
    private lazy var developerServer = PluginDeveloperServer { [weak self] request, session in
        guard let self else { throw PluginHostError.notRunning }
        return try await self.handleDeveloperRequest(request, session: session)
    }
    // The same public Host activation API is used by production and native probes.
    private var elyxDeveloperFiles: (any PluginElyxDeveloperFileAuthority)?
    private var elyxDeveloperService: PluginElyxDeveloperService?
    private var elyxDeveloperActivation: PluginElyxDeveloperActivationScope?
    private var callbackTasks: [UUID: (owner: PluginHost.CallbackOwner, task: Task<Void, Never>)] = [:]

    private init() {}

    public func update(context: AccountContext) {
        guard !terminating, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        if currentContext !== context {
            PluginUIManagerSettingsLifetimes.closeAll()
            startupScope = UUID()
            stopDeveloperServices()
        }
        settingsActionAuthority?.prepareContextChange(to: context)
        services.update(context: context)
        if currentContext !== context {
            watchdogAlert?.dismiss(animated: false)
            watchdogAlert = nil
            settingsSchemaCache.clear()
            cachedSettingsOwners.removeAll()
        }
        currentContext = context
        settingsActionAuthority?.update(context: context)
        configureManagerPreferences()
        tlServices?.update(context: context)
        nativeServices?.update(context: context)
        pillServices?.update(context: context)
        pluginUI?.update(context: context)
        hasAccount = true
        ExteralessPluginEntry.setControllerFactory { context in
            MainActor.assumeIsolated { exteralessPluginManagerController(context: context) }
        }
        start()
        updateDeveloperServer()
        refreshSubscriptions()
    }

    public func clearContext() {
        PluginUIManagerSettingsLifetimes.closeAll()
        startupScope = UUID()
        stopDeveloperServices()
        settingsActionAuthority?.clearContext()
        clearEarlyStartupMarker()
        tlTransforms?.updateSubscriptions(active: false)
        hasAccount = false
        currentContext = nil
        settingsSchemaCache.clear()
        cachedSettingsOwners.removeAll()
        watchdogAlert?.dismiss(animated: false)
        watchdogAlert = nil
        tlServices?.clearContext()
        nativeServices?.clearContext()
        pillServices?.clearContext()
        pluginUI?.clearContext()
        services.clearContext()
        registration?.updateSubscriptions([])
        changed()
    }

    public func start() {
        guard !terminating, settingsMaintenanceID == nil, !toolsRecoveryRequired,
              startup == nil, hasAccount, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        guard let preferences = managerPreferences?.snapshot else {
            status = managerPreferencesError ?? "Manager preferences unavailable"
            changed()
            return
        }
        guard preferences.engineEnabled else {
            status = "Plugin engine disabled"
            changed()
            return
        }
        if let continuation = startupContinuation {
            guard continuation.canContinue else { return }
            let scope = startupScope
            status = "Continuing Python runtime startup"
            changed()
            startup = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.startup = nil }
                do { try await self.continueColdStartup(continuation, scope: scope) }
                catch { self.publishStartupFailure(error) }
            }
            return
        }
        guard host == nil, startupError == nil else { return }
        let scope = startupScope
        status = "Starting Python runtime"
        changed()
        startup = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startup = nil }
            guard !self.terminating, self.currentContext != nil, self.startupScope == scope else {
                self.status = "Waiting for an account"
                self.changed()
                return
            }
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
                self.retireElyxDeveloperService()
                self.host = host
                let callbacks = PluginCallbackDispatcher(host: host, log: { logs.append(pluginId: "host", message: $0) })
                self.nativeCallbacks = callbacks
                let services = self.services
                let settingsActions = PluginUISettingsActionAuthority(captureOwner: { callbacks.captureOwner($0) },
                    accountIndex: { services.accountIndex(recordId: $0) })
                self.settingsActionAuthority = settingsActions
                PluginUISettingsActionRegistry.install(settingsActions)
                if let context = self.currentContext { settingsActions.update(context: context) }
                let tl = PluginTLBridgeExtension(
                    storage: services.serviceStorage,
                    hasPermission: { callbacks.hasPermission($0, $1) },
                    captureOwner: { callbacks.captureOwner($0) },
                    callback: { callbacks.callback($0, $1, $2, $3, shouldExecute: $4) },
                    release: { callbacks.release($0, $1) },
                    accountLookup: { index in try services.platformSnapshot.account(at: index).recordId },
                    resolveAccount: { recordId in services.context(recordId: recordId) },
                    diagnostic: { logs.append(pluginId: "host", level: .warning, message: $0) },
                    permissionAdmission: { callbacks.permissionPredicate($0, requiring: $1) })
                if let context = self.currentContext { tl.update(context: context) }
                self.tlServices = tl
                let native = PluginNativeServicesBridgeExtension(services: services, callbacks: callbacks,
                    interceptionSites: [.chatDocument, .externalURL, .applicationURL],
                    publisherSites: [.committedMessages, .mediaFetch])
                NativeServiceOpenHooks.shared.install(provider: native)
                if let context = self.currentContext { native.update(context: context) }
                self.nativeServices = native
                guard let pillContext = self.currentContext else { throw PluginHostError.notRunning }
                let pills = try PluginPillBridgeExtension(services: services, callbacks: callbacks,
                    identityURL: URL(fileURLWithPath: pillContext.sharedContext.basePath, isDirectory: true)
                        .appendingPathComponent("exteraless/pills/plugin-identities.json"))
                pills.update(context: pillContext)
                self.pillServices = pills
                let uiGate = PluginUICallbackGate()
                let ui = PluginUIBridgeExtension(
                    captureOwner: { callbacks.captureOwner($0) },
                    callback: { owner, handle, method, json in
                        return callbacks.callback(owner, handle, method, json,
                            shouldExecute: { uiGate.permits(owner: owner, argumentsJSON: json) },
                            guaranteed: PluginUICallbackGate.isTerminal(argumentsJSON: json))
                    },
                    release: { callbacks.release($0, $1) },
                    hasPermission: { callbacks.hasPermission($0, $1) },
                    accountIndex: { services.accountIndex(recordId: $0) },
                    settingsController: { [weak self] context, id, title, path in
                        guard let self else { return nil }
                        return PluginSettingsController(context: context,
                            actions: self.pluginSettingsActions(context: context, pluginId: id),
                            pluginId: id, title: title, pagePath: path)
                    },
                    resolveShareFile: { id, path in
                        return try PluginUIShareFiles.resolve(path: path,
                            allowedRoots: [services.serviceStorage.filesDirectory(pluginId: id),
                                           services.serviceStorage.cacheDirectory(pluginId: id)],
                            allowExternal: callbacks.hasPermission(id, .files))
                    }, permissionAdmission: { callbacks.permissionPredicate($0, requiring: $1) },
                    controlledCallback: { owner, handle, method, json, permissionCurrent in
                        callbacks.callback(owner, handle, method, json,
                            shouldExecute: { permissionCurrent() && uiGate.permits(owner: owner, argumentsJSON: json) },
                            guaranteed: PluginUICallbackGate.isTerminal(argumentsJSON: json))
                    }, classifyShareFile: { id, path in
                        try PluginResourcePath(path: path,
                            allowedRoots: [services.serviceStorage.filesDirectory(pluginId: id),
                                           services.serviceStorage.cacheDirectory(pluginId: id)])
                    })
                uiGate.bind(ui)
                self.pluginUI = ui
                if let context = self.currentContext { ui.update(context: context) }
                ExteralessPluginMenuEntry.setFactory { [weak ui] context, placement, peer, message, source in
                    guard let ui, let placement = PluginUIMenuPlacement(rawValue: placement) else { return [] }
                    return ui.menuItems(context: context, placement: placement, peer: peer, message: message, source: source)
                }
                guard let managerStore = self.managerPreferences else {
                    throw PluginHostError.runtimeFailure("Plugin manager preferences unavailable")
                }
                let pluginConfig = PluginConfigBridgeExtension(
                    snapshot: { managerStore.snapshot },
                    installedIds: { [weak host] in Set(host?.pluginList().map(\.id) ?? []) },
                    captureOwner: { callbacks.captureOwner($0) },
                    permits: { callbacks.hasPermission($0, $1) },
                    apply: { [weak self] mutation, isCurrent in
                        guard let self else { throw PluginHostError.notRunning }
                        try await self.applyGlobalPluginConfig(mutation, isCurrent: isCurrent)
                    },
                    failed: { id, field, error in
                        logs.append(pluginId: id, level: .error, message: "Global plugin config \(field) failed: \(error)")
                    }, permissionAdmission: { callbacks.permissionPredicate($0, requiring: $1) })
                let developer = PluginDeveloperBridgeExtension(
                    snapshot: { [server = self.developerServer] in server.snapshot },
                    enabled: {
                        let state = managerStore.snapshot
                        return state.developerMode && state.permitsPluginExecution
                    },
                    captureOwner: { callbacks.captureOwner($0) },
                    permits: { callbacks.hasPermission($0, $1) },
                    apply: { [weak self] start, authority in
                        guard let self, !self.terminating else { throw PluginHostError.notRunning }
                        guard authority.isCurrent() else { throw PluginHostError.superseded("Developer control owner retired") }
                        if start {
                            try self.requirePluginExecution()
                            guard self.managerPreferences?.snapshot.developerMode == true,
                                  self.host?.isRunning == true else {
                                throw PluginHostError.runtimeFailure("Developer service is not active")
                            }
                            self.updateDeveloperServer()
                        } else {
                            try await self.updateManagerPreference(.developer(false), authority: authority)
                        }
                    },
                    failed: { id, error in
                        logs.append(pluginId: id, level: .error, message: "Native developer control failed: \(error)")
                    }, permissionAdmission: { callbacks.permissionPredicate($0, requiring: $1) })
                host.bridge.extensionProvider = CompositePluginBridgeExtension([
                    ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }), pluginConfig, developer, tl, native, pills,
                ])
                host.bridge.onOwnedCallback = { [weak self, weak host] pluginId, ownerToken, handle, method, json, delayMs in
                    // Capture the generation on the C worker, before the main
                    // actor hop: Python handle numbers may recur after reload.
                    guard let self, let host, let owner = host.callbackOwner(id: pluginId), owner.wireToken == ownerToken else { return false }
                    let tlOrigin: PluginTLInvocationOrigin?
                    do { tlOrigin = try PluginTLNativeOrigin.capture(owner: owner) }
                    catch { return false }
                    Task { @MainActor in
                        self.enqueueCallback(host: host, owner: owner, handle: handle,
                                             method: method, json: json, delayMs: delayMs, tlOrigin: tlOrigin)
                    }
                    return true
                }
                let continuation = PluginRuntimeStartupContinuation(host: host)
                self.startupContinuation = continuation
                try await self.continueColdStartup(continuation, scope: scope)
            } catch {
                self.publishStartupFailure(error)
            }
        }
    }

    private func continueColdStartup(_ continuation: PluginRuntimeStartupContinuation, scope: UUID) async throws {
        let host = continuation.host
        try await continuation.run(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.startupContinuation === continuation && self.host === host
                && self.startupScope == scope && self.hasAccount && self.currentContext != nil
                && !self.terminating && self.settingsMaintenanceID == nil && !self.toolsRecoveryRequired
        }, policy: { [weak self] in
            guard let preferences = self?.managerPreferences?.snapshot else {
                throw PluginHostError.runtimeFailure("Manager preferences unavailable")
            }
            return .init(engineEnabled: preferences.engineEnabled, safeMode: preferences.safeMode)
        }, recoverBeforeStart: { [services = self.services] in
            let directory = try services.serviceStorage.settingsDirectoryURL()
            try await ExteralessToolsHostMaintenance.recoverBeforeStart(host: host, settingsDirectory: directory)
        }, prepare: { [weak self] policy in
            guard let self else { throw PluginHostError.notRunning }
            try self.requireColdStartupScope(continuation, scope: scope)
            if let recovery = self.runtimeRecovery, let manager = self.managerPreferences {
                let root = try self.services.serviceStorage.rootDirectory()
                let known = Set(host.pluginList().map { $0.id })
                let automatic = try await Task.detached(priority: .utility) {
                    let attributed = PluginRuntimeRecovery.attributedPlugin(marker: root.appendingPathComponent(".watchdog"), knownPlugins: known)
                    return try recovery.beginStart(safeMode: policy.safeMode, hasAttributedPluginMarker: attributed != nil)
                }.value
                try self.requireColdStartupScope(continuation, scope: scope)
                if automatic {
                    try await Task.detached(priority: .utility) {
                        try manager.apply(.safeMode(true))
                        try recovery.confirmAutomaticSafeMode()
                    }.value
                }
            }
        }, complete: { [weak self] started in
            guard let self else { return }
            for pluginId in started.disabledPluginIds {
                do { try self.runtimeRecovery?.recordDisabledPlugin(pluginId) }
                catch { self.services.serviceLogs.append(pluginId: "host", level: .error, message: "Startup notice persistence: \(error)") }
            }
            if !started.safeMode, let recovery = self.runtimeRecovery {
                self.recoveryHealthyTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        try Task.checkCancellation()
                        try await Task.detached(priority: .utility) { try recovery.markHealthy() }.value
                        self?.changed()
                    } catch {}
                }
            }
            self.updateDeveloperServer()
            self.installHooks()
            self.status = started.safeMode ? "Safe mode · plugins not loaded" : "Python runtime ready"
            self.refreshSubscriptions()
            host.events.emitAppEvent("app_start")
        })
        startupError = nil
        updateRuntimeStatus()
        changed()
    }

    private func requireColdStartupScope(_ continuation: PluginRuntimeStartupContinuation, scope: UUID) throws {
        guard startupContinuation === continuation, host === continuation.host,
              startupScope == scope, hasAccount, currentContext != nil, !terminating else {
            throw PluginHostError.superseded("Startup account retired")
        }
    }

    private func publishStartupFailure(_ error: Error) {
        clearEarlyStartupMarker()
        startupError = String(describing: error)
        if startupContinuation?.phase == .recoveryBlocked { toolsRecoveryRequired = true }
        status = hasAccount ? "Runtime error: \(error)" : "Waiting for an account"
        services.serviceLogs.append(pluginId: "host", level: .error, message: "Runtime error: \(error)")
        changed()
    }

    private func ready() async throws -> PluginHost {
        start()
        _ = await startup?.value
        guard let host, host.isRunning else {
            throw PluginHostError.runtimeFailure(startupError ?? status)
        }
        return host
    }

    private func requirePluginExecution() throws {
        guard !terminating, hasAccount, currentContext != nil, pluginExecutionRequested,
              !changingRuntimeMode, settingsMaintenanceID == nil, !toolsRecoveryRequired else {
            throw PluginHostError.runtimeFailure("Plugin execution is suspended by the current runtime/account/maintenance mode")
        }
    }

    private func operationHost() async throws -> PluginHost {
        try requirePluginExecution()
        let host = try await ready()
        try requirePluginExecution()
        activeOperations += 1
        return host
    }

    public func snapshot() -> [Plugin] { host?.pluginList() ?? [] }

    public func importPlugin(url: URL) async throws {
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let plugin = try await host.importPlugin(sourceURL: url)
        refreshSubscriptions()
        changed()
        if let error = plugin.loadError { throw PluginHostError.runtimeFailure(error) }
    }

    public func setEnabled(id: String, enabled: Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer {
            ToolsToggleTraceBuffer.shared.record(pluginId: id, enabled: enabled,
                elapsed: ProcessInfo.processInfo.systemUptime - started, succeeded: succeeded)
        }
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        try await host.setPluginEnabled(id: id, enabled)
        refreshSubscriptions()
        changed()
        if enabled, let error = host.pluginList().first(where: { $0.id == id })?.loadError {
            throw PluginHostError.runtimeFailure(error)
        }
        succeeded = true
    }

    public func remove(id: String) async throws {
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        guard host.pluginList().contains(where: { $0.id == id }) else { throw PluginHostError.pluginNotFound(id) }
        invalidateSettingsSchema(id: id)
        try await host.uninstallPlugin(id: id)
        if let store = managerPreferences {
            try await Task.detached(priority: .utility) { try store.apply(.remove(id)) }.value
        }
        refreshSubscriptions()
        changed()
    }

    public func settings(id: String) async throws -> String {
        let read = try PluginUISettingsReadExecution.require(pluginId: id)
        guard let capturedHost = self.host, let context = currentContext,
              context.account.id.int64 == read.accountRecordId else { throw PluginHostError.superseded("Settings read account expired") }
        let owner = read.owner
        let account = read.account
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        guard read.isCurrent, host === capturedHost, self.currentContext === context, host.callbackOwner(id: id) == owner else {
            throw PluginHostError.superseded("Settings read scope expired before admission")
        }
        let fileName = try ToolsPluginSchemaCache.settingsFileName(pluginId: id)
        let json: String
        do {
            json = try await host.settingsJSON(id: id, account: account, expectedOwner: owner,
                shouldExecute: { read.isCurrent }, page: PluginSettingsPageExecution.current)
        }
        catch {
            if cachedSettingsOwners[fileName]?.owner == owner { invalidateSettingsSchema(id: id) }
            throw error
        }
        guard read.isCurrent, self.host === host, self.currentContext === context, host.callbackOwner(id: id) == owner else {
            throw PluginHostError.superseded("Settings schema belongs to an expired account/interpreter")
        }
        do {
            // Arbitrary create_settings() has no native immutable-schema proof.
            // Core receives nil evidence; this cache key grants no backup fields.
            try settingsSchemaCache.recordDynamic(fileName: fileName, owner: settingsSchemaObservationKey(owner: owner, account: context.account.id.int64), cachedNativeSettingsJSON: Data(json.utf8))
            cachedSettingsOwners[fileName] = (owner, context.account.id.int64)
        } catch {
            invalidateSettingsSchema(id: id)
            services.serviceLogs.append(pluginId: id, level: .warning, message: "Settings schema is not exportable: \(error)")
        }
        return json
    }

    public func updateSetting(id: String, key: String, jsonValue: String) async throws {
        let invocation = try PluginUISettingsActionExecution.require(pluginId: id)
        guard let capturedHost = self.host else { throw PluginHostError.notRunning }
        invalidateSettingsSchema(id: id)
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        guard host === capturedHost else { throw PluginHostError.superseded("Settings Host changed before admission") }
        try await host.updateSetting(id: id, key: key, valueJSON: jsonValue,
            expectedOwner: invocation.owner, account: invocation.account,
            shouldExecute: { invocation.isCurrent })
        changed()
    }

    public func click(id: String, callbackId: String) async throws {
        let invocation = try PluginUISettingsActionExecution.require(pluginId: id)
        guard let capturedHost = self.host else { throw PluginHostError.notRunning }
        invalidateSettingsSchema(id: id)
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        guard host === capturedHost else { throw PluginHostError.superseded("Settings Host changed before admission") }
        try await host.clickSetting(id: id, callbackId: callbackId,
            expectedOwner: invocation.owner, account: invocation.account,
            shouldExecute: { invocation.isCurrent })
        changed()
    }

    public func logs() -> [String] {
        services.logEntries.map { "[\($0.pluginId)] \($0.level.rawValue): \($0.message)" }
    }

    public func grantedPermissions(id: String) -> [PluginPermission] {
        host?.grantedPermissions(id: id) ?? [.ui]
    }

    public func setPermissions(id: String, permissions: [PluginPermission]) async throws {
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        try host.setGrantedPermissions(id: id, permissions: permissions)
        refreshSubscriptions()
        changed()
    }

    public func managerTrustActions(context: AccountContext) -> PluginManagerTrustActions {
        PluginManagerTrustActions(snapshot: { [weak self] id in
            self?.host?.permissionSnapshot(id: id) ?? PluginPermissionSnapshot(record: nil, unsafeMode: false)
        }, captureEdit: { [weak self, weak context] id, expected, page in
            guard let self, let context else { throw PluginHostError.notRunning }
            let (host, authority) = try self.captureConsentAuthority(context: context, pluginId: id, page: page)
            guard host.pluginList().contains(where: { $0.id == id }), host.permissionSnapshot(id: id) == expected else {
                throw PluginPermissionStoreError.authorityExpired
            }
            return PluginManagerTrustActions.Edit(setLevel: { [weak self] level in
                guard let self else { throw PluginHostError.notRunning }
                try await self.applyConsent(id: id, expected: expected, level: level, grants: nil,
                    capturedHost: host, authority: authority)
            }, setGrants: { [weak self] grants in
                guard let self else { throw PluginHostError.notRunning }
                try await self.applyConsent(id: id, expected: expected, level: expected.level, grants: grants,
                    capturedHost: host, authority: authority)
            })
        }, readMetadata: { [weak self, weak context] url in
            guard let self, let context, self.currentContext === context else { throw PluginHostError.notRunning }
            let host = try await self.operationHost()
            defer { self.activeOperations -= 1 }
            let result = try await host.readPluginMetadata(sourceURL: url)
            guard self.host === host, self.currentContext === context else { throw PluginPermissionStoreError.authorityExpired }
            return result
        }, captureInstall: { [weak self, weak context] url, metadata, selection, page in
            guard let self, let context else { throw PluginHostError.notRunning }
            let (host, authority) = try self.captureConsentAuthority(context: context, pluginId: nil, page: page)
            let owner = host.callbackOwner(id: metadata.id)
            let oldPlugin = host.pluginList().first { $0.id == metadata.id }
            let oldConsent = host.permissionSnapshot(id: metadata.id)
            let admission: @Sendable () -> Bool = {
                authority.isCurrent() && host.callbackOwner(id: metadata.id) == owner
                    && host.pluginList().first(where: { $0.id == metadata.id }) == oldPlugin
                    && host.permissionSnapshot(id: metadata.id) == oldConsent
            }
            return { [weak self] in
                guard let self, authority.isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
                let activeHost = try await self.operationHost()
                defer { self.activeOperations -= 1; self.refreshSubscriptions(); self.changed() }
                guard activeHost === host else { throw PluginPermissionStoreError.authorityExpired }
                let installed = try await host.installPlugin(sourceURL: url, metadata: metadata, selection: selection,
                    admission: admission, shouldExecute: authority.isCurrent)
                if let error = installed.loadError { throw PluginHostError.runtimeFailure(error) }
            }
        })
    }

    private func captureConsentAuthority(context: AccountContext, pluginId: String?, page: @escaping @Sendable () -> Bool) throws -> (PluginHost, PluginConfigAuthority) {
        try requirePluginExecution()
        guard let host, currentContext === context,
              let accountOwner = settingsActionAuthority?.captureManagerAuthority(context: context, pluginId: pluginId) else {
            throw PluginPermissionStoreError.authorityExpired
        }
        let permission: @Sendable () -> Bool = pluginId.map { host.permissions.futurePredicate($0, requiring: [.ui]) } ?? { true }
        let authority = PluginConfigAuthority(isCurrent: { page() && accountOwner.isCurrent() && permission() })
        guard authority.isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
        return (host, authority)
    }

    private func applyConsent(id: String, expected: PluginPermissionSnapshot, level: PluginTrustLevel,
                              grants: [PluginPermission]?, capturedHost: PluginHost, authority: PluginConfigAuthority) async throws {
        guard authority.isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
        let host = try await operationHost()
        defer { activeOperations -= 1; refreshSubscriptions(); changed() }
        guard host === capturedHost, authority.isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
        try await Task.detached(priority: .userInitiated) {
            if let grants {
                try host.setGrantedPermissions(id: id, permissions: grants, atLevel: level, expected: expected,
                    shouldExecute: authority.isCurrent)
            } else {
                try host.setPluginTrustLevel(id: id, level: level, expected: expected, shouldExecute: authority.isCurrent)
            }
        }.value
        // The writer's returned result is the commit result. Do not turn a
        // committed change into a failure because the page disappeared afterward.
    }

    public func emitAppEvent(_ name: String) {
        if name == "app_pause" { clearEarlyStartupMarker() }
        guard let host, host.isRunning else { return }
        host.events.emitAppEvent(name)
        if name == "app_resume" {
            for plugin in host.pluginList() where plugin.notResponding { presentWatchdogWarning(pluginId: plugin.id) }
        }
    }

    public func terminate() async {
        guard !terminating else { return }
        terminating = true
        startupScope = UUID()
        stopDeveloperServices()
        startupContinuation?.retire()
        PluginUIManagerSettingsLifetimes.closeAll()
        settingsActionAuthority?.clearContext()
        PluginUISettingsActionRegistry.install(nil)
        recoveryHealthyTask?.cancel()
        recoveryHealthyTask = nil
        if let recovery = runtimeRecovery { try? await Task.detached(priority: .utility) { try recovery.markHealthy() }.value }
        tlTransforms?.detach()
        tlTransforms = nil
        watchdogAlert?.dismiss(animated: false)
        watchdogAlert = nil
        pluginUI?.clearContext()
        tlServices?.clearContext()
        nativeServices?.clearContext()
        pillServices?.clearContext()
        settingsSchemaCache.clear()
        cachedSettingsOwners.removeAll()
        ExteralessPluginMenuEntry.setFactory(nil)
        for callback in callbackTasks.values { callback.task.cancel() }
        callbackTasks.removeAll()
        registration?.detach()
        registration = nil
        if let startup { await startup.value }
        if let host {
            try? await host.deliverAppEvent("app_stop")
            await host.stop()
            host.bridge.onCallback = nil
            host.bridge.onOwnedCallback = nil
        }
        binding?.uninstall()
        binding = nil
        status = "Python runtime stopped"
        changed()
    }

    /// A settings page pins both account and interpreter lifetime. Refresh is a
    /// new read within that lifetime, never permission to enter a replacement.
    func settingsScope(context: AccountContext, pluginId: String) -> @MainActor () -> Bool {
        let capturedHost = self.host
        let owner = capturedHost?.callbackOwner(id: pluginId)
        return { [weak self, weak context, weak capturedHost] in
            guard let self, let context, let capturedHost, let owner else { return false }
            return self.currentContext === context && self.host === capturedHost && capturedHost.callbackOwner(id: pluginId) == owner
        }
    }

    private func pluginSettingsActions(context: AccountContext, pluginId: String) -> PluginManagerActions {
        let current = self.settingsScope(context: context, pluginId: pluginId)
        return PluginManagerActions(
            status: { self.status }, snapshot: { self.snapshot() },
            importPlugin: { try await self.importPlugin(url: $0) },
            setEnabled: { try await self.setEnabled(id: $0, enabled: $1) },
            remove: { try await self.remove(id: $0) },
            settings: { id in
                try await requirePluginSettingsScope(current)
                let result = try await self.settings(id: id)
                try await requirePluginSettingsScope(current)
                return result
            },
            updateSetting: { id, key, json in
                try await requirePluginSettingsScope(current)
                try await self.updateSetting(id: id, key: key, jsonValue: json)
            },
            click: { id, callbackId in
                try await requirePluginSettingsScope(current)
                try await self.click(id: id, callbackId: callbackId)
            },
            logs: { self.logs() }, permissions: { self.grantedPermissions(id: $0) },
            setPermissions: { try await self.setPermissions(id: $0, permissions: $1) })
    }

    public func pluginHostDidReloadPlugins(_ host: PluginHost) {
        refreshSubscriptions()
        changed()
    }

    public func pluginHost(_ host: PluginHost, didMarkNotResponding pluginId: String) {
        refreshSubscriptions()
        changed()
        presentWatchdogWarning(pluginId: pluginId)
    }

    public func pluginHost(_ host: PluginHost, didRecover pluginId: String) {
        warnedPlugins.remove(pluginId)
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
        pruneSettingsSchemas()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func configureManagerPreferences() {
        guard managerPreferences == nil else { return }
        do {
            let url = try services.serviceStorage.rootDirectory().appendingPathComponent("manager-presentation.json")
            let legacyPlugins = try PluginStore(directory: url.deletingLastPathComponent()).loadPlugins()
            let preferences = try PluginManagerPreferences(url: url, legacyEngineEnabled: legacyPlugins.contains(where: { $0.enabled }))
            let recovery = try PluginRuntimeRecovery(url: url.deletingLastPathComponent().appendingPathComponent("runtime-recovery.json"))
            managerPreferences = preferences
            runtimeRecovery = recovery
            managerPreferencesError = nil
        } catch {
            managerPreferencesError = String(describing: error)
            services.serviceLogs.append(pluginId: "host", level: .error, message: "Manager preferences: \(error)")
        }
    }

    public func managerControls() -> PluginManagerControls {
        configureManagerPreferences()
        return PluginManagerControls(snapshot: { self.managerPreferences?.snapshot },
            compact: { try await self.updateManagerPreference(.compact($0)) },
            developer: { try await self.updateManagerPreference(.developer($0)) },
            pin: { try await self.updateManagerPreference(.pinned($0, $1)) },
            muteWarning: { try await self.updateManagerPreference(.warningMuted($0, $1)) },
            reload: { try await self.reloadPlugin(id: $0) },
            engine: { try await self.setRuntimeMode(.engine($0)) },
            safeMode: { try await self.setRuntimeMode(.safeMode($0)) },
            recovery: { self.runtimeRecovery?.snapshot },
            acknowledgeRecovery: { try await self.acknowledgeRuntimeRecovery() },
            developerConnection: { self.developerServer.snapshot })
    }

    /// SDK global-manager projection only. Existing controls own persistence,
    /// developer-server effects, nonterminal Host maintenance and hook gates.
    private func applyGlobalPluginConfig(_ mutation: PluginConfigMutation, isCurrent authority: PluginConfigAuthority) async throws {
        do {
            guard !terminating else { throw PluginHostError.notRunning }
            switch mutation {
            case .engine, .safeMode:
                // A settings/menu callback can still own a root operation when
                // its C setter returns admission. Wait asynchronously for that
                // operation to finish; never wait from the Python/C worker.
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while activeOperations > 0 || changingRuntimeMode || settingsMaintenanceID != nil {
                    guard !terminating, authority.isCurrent() else { throw PluginHostError.superseded("Plugin config caller retired") }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw PluginHostError.runtimeFailure("Global plugin config admission timed out while Runtime was busy") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            default: break
            }
            guard authority.isCurrent() else { throw PluginHostError.superseded("Plugin config caller or settings grant expired") }
            switch mutation {
            case let .engine(value): try await setRuntimeMode(.engine(value))
            case let .safeMode(value): try await setRuntimeMode(.safeMode(value))
            case let .developer(value): try await updateManagerPreference(.developer(value), authority: authority)
            case let .compact(value): try await updateManagerPreference(.compact(value), authority: authority)
            case let .pinned(wanted):
                guard let host else { throw PluginHostError.notRunning }
                try await updateManagerPreference(.pinnedSet(wanted: wanted, installed: Set(host.pluginList().map(\.id))),
                    authority: authority)
            }
        } catch {
            status = "Global plugin config \(mutation.field) failed: \(error)"
            changed()
            throw error
        }
    }

    private func acknowledgeRuntimeRecovery() async throws {
        guard let recovery = runtimeRecovery else { throw PluginHostError.runtimeFailure("Runtime recovery storage unavailable") }
        try await Task.detached(priority: .utility) { try recovery.acknowledgeNotice() }.value
        changed()
    }

    private func clearEarlyStartupMarker() {
        recoveryHealthyTask?.cancel()
        recoveryHealthyTask = nil
        guard let recovery = runtimeRecovery else { return }
        Task { try? await Task.detached(priority: .utility) { try recovery.markHealthy() }.value }
    }

    /// Tools must finish its native lease through this policy: a successful
    /// backup/restore must not override the user's master-off/safe-mode choice.
    public func beginManagerAwareSettingsMaintenance(timeout: TimeInterval = 10) async throws -> ExteralessToolsMaintenanceLease {
        guard !terminating, !changingRuntimeMode, settingsMaintenanceID == nil, activeOperations == 0 else {
            throw PluginHostError.runtimeFailure("A runtime operation or settings maintenance is in progress")
        }
        // Reserve before the first await, including the no-Host case. Enabling
        // the engine while Tools owns files cannot create a worker behind it.
        let id = UUID()
        let scope = startupScope
        settingsMaintenanceID = id
        stopDeveloperServices()
        let lease: PluginSettingsMaintenanceLease?
        var coldMaintenance: (PluginRuntimeStartupContinuation, PluginRuntimeStartupContinuation.Maintenance)?
        do {
            if let startup { await startup.value }
            guard !terminating else { throw PluginHostError.notRunning }
            // Pre-drain UI schemas are not evidence about unload's final writes.
            settingsSchemaCache.clear()
            cachedSettingsOwners.removeAll()
            if let host {
                let acquired = try await host.beginSettingsMaintenance(timeout: timeout)
                do { frozenSettingsLocation = try liveSettingsLocation() }
                catch { try await acquired.finish(resume: false); throw error }
                lease = acquired
                if let continuation = startupContinuation, continuation.host === host,
                   let receipt = continuation.captureMaintenance() {
                    coldMaintenance = (continuation, receipt)
                }
            } else {
                guard startup == nil else { throw PluginHostError.runtimeFailure("Runtime initialization did not establish a maintenance owner") }
                frozenSettingsLocation = try liveSettingsLocation()
                lease = nil // Root proves that no Host or worker was ever created.
            }
        } catch {
            settingsMaintenanceID = nil
            frozenSettingsLocation = nil
            if host?.isSettingsMaintenanceActive == true { toolsRecoveryRequired = true }
            status = "Settings maintenance failed: \(error)"
            changed()
            throw error
        }
        let completion = PluginRuntimeMaintenanceCompletion()
        let cold = coldMaintenance
        return ExteralessToolsMaintenanceLease { [weak self] outcome in
            let recovered: Bool
            switch outcome {
            case .committed, .rolledBack: recovered = true
            case .needsRecovery: recovered = false
            }
            try await completion.finish(recovered: recovered) {
                guard let self else { try await lease?.finish(resume: false); return }
                try await self.finishManagerMaintenance(id: id, lease: lease, recovered: recovered, cold: cold, scope: scope)
            }
        }
    }

    private func finishManagerMaintenance(id: UUID, lease: PluginSettingsMaintenanceLease?, recovered: Bool,
        cold: (PluginRuntimeStartupContinuation, PluginRuntimeStartupContinuation.Maintenance)?, scope: UUID) async throws {
        guard settingsMaintenanceID == id else { throw PluginHostError.superseded("Settings maintenance owner changed") }
        defer {
            if settingsMaintenanceID == id {
                settingsMaintenanceID = nil
                frozenSettingsLocation = nil
            }
            updateDeveloperServer()
            refreshSubscriptions()
            changed()
        }
        do {
            if let cold {
                guard startupContinuation === cold.0, host === cold.0.host else {
                    try await lease?.finish(resume: false)
                    throw PluginHostError.superseded("Cold-start Host changed during maintenance")
                }
            }
            // Reopening a never-started Host is data-only, including master-off
            // and safe mode. The continuation checks current execution policy.
            let resume = recovered && !terminating && (cold != nil
                || (pluginExecutionRequested && hasAccount && startupScope == scope))
            try await lease?.finish(resume: resume)
            guard settingsMaintenanceID == id else { throw PluginHostError.superseded("Settings maintenance owner changed") }
            toolsRecoveryRequired = !recovered
            if let cold, !terminating {
                try cold.0.acknowledgeMaintenance(cold.1, recovered: recovered)
                if recovered { startupError = nil }
            }
        } catch {
            toolsRecoveryRequired = true
            status = "Settings recovery required: \(error)"
            throw error
        }
        // Release this root's file-maintenance gate before scheduling startup.
        // A later maintenance owner must survive the await and this defer.
        settingsMaintenanceID = nil
        frozenSettingsLocation = nil
        if recovered, cold != nil, !terminating, hasAccount, startupScope == scope {
            start()
            if let startup { await startup.value }
        }
        // A startup error is distinct from an unresolved journal. Its actual
        // result was published by the startup Task; never recreate Tools debt.
        updateRuntimeStatus()
    }

    /// Root Tools bindings read only schemas already returned to the native
    /// settings UI. They never start Python or call get_settings for inspection.
    public func toolsBackupBindings(context: AccountContext) -> ExteralessToolsBackupBindings {
        return ExteralessToolsBackupBindings(settings: ToolsBackupSettingsAccess.clientSettings(ClientSettings.shared),
            pluginLocation: { [weak self, weak context] in
                guard let self, let context, self.currentContext === context else { throw PluginHostError.superseded("Tools account changed") }
                return try self.frozenSettingsLocation ?? self.liveSettingsLocation()
            }, beginMaintenance: { [weak self, weak context] in
                guard let self, let context, self.currentContext === context else { throw PluginHostError.superseded("Tools account changed") }
                return try await self.beginManagerAwareSettingsMaintenance(timeout: 10)
            })
    }

    private func settingsSchemaObservationKey(owner: PluginHost.CallbackOwner, account: Int64) -> String {
        return "account:\(account):epoch:\(owner.wireToken)"
    }

    private func liveSettingsLocation() throws -> ToolsBackupPluginLocation {
        pruneSettingsSchemas()
        let owners = cachedSettingsOwners.mapValues { settingsSchemaObservationKey(owner: $0.owner, account: $0.account) }
        return try settingsSchemaCache.location(directory: services.serviceStorage.settingsDirectoryURL(), activeOwners: owners)
    }

    private func invalidateSettingsSchema(id: String) {
        guard let fileName = try? ToolsPluginSchemaCache.settingsFileName(pluginId: id) else { return }
        settingsSchemaCache.invalidate(fileName: fileName)
        cachedSettingsOwners.removeValue(forKey: fileName)
    }

    private func pruneSettingsSchemas() {
        for (fileName, value) in Array(cachedSettingsOwners) where currentContext?.account.id.int64 != value.account || host?.callbackOwner(id: value.owner.pluginId) != value.owner {
            settingsSchemaCache.invalidate(fileName: fileName)
            cachedSettingsOwners.removeValue(forKey: fileName)
        }
    }

    public var pluginExecutionRequested: Bool {
        return managerPreferences?.snapshot.permitsPluginExecution ?? false
    }

    private func setRuntimeMode(_ change: PluginManagerPreferenceChange) async throws {
        guard !terminating, !changingRuntimeMode, settingsMaintenanceID == nil, activeOperations == 0,
              !toolsRecoveryRequired, let store = managerPreferences else {
            throw PluginHostError.runtimeFailure(managerPreferencesError ?? "Runtime is busy or Tools settings recovery is required")
        }
        changingRuntimeMode = true
        defer { changingRuntimeMode = false; updateDeveloperServer(); refreshSubscriptions(); changed() }
        stopDeveloperServices()
        if let startup { await startup.value }
        guard !terminating else { throw PluginHostError.notRunning }
        if let startupError, startupContinuation?.canContinue != true {
            throw PluginHostError.runtimeFailure("Runtime initialization failed; restart the application: \(startupError)")
        }
        let old = store.snapshot
        var engine = old.engineEnabled
        var safe = old.safeMode
        switch change {
        case let .engine(value): engine = value
        case let .safeMode(value): safe = value
        default: throw PluginHostError.runtimeFailure("Expected a runtime-mode change")
        }
        do {
            if host == nil || (startupContinuation?.canContinue == true && startupContinuation?.hasAttemptedStart == false) {
                try await Task.detached(priority: .utility) { try store.apply(change) }.value
                if engine {
                    start()
                    if let startup { await startup.value }
                    guard host?.isRunning == true else { throw PluginHostError.runtimeFailure(startupError ?? status) }
                }
            } else if let host {
                status = "Applying native runtime mode…"
                changed()
                // Nonterminal quiescence: CPython stays initialized and the
                // individual enabled set is preserved by the actual Host lease.
                let lease = try await host.beginSettingsMaintenance(timeout: 10)
                do { try await Task.detached(priority: .utility) { try store.apply(change) }.value }
                catch {
                    try await lease.finish(resume: old.permitsPluginExecution && !terminating)
                    throw error
                }
                let resume = engine && !safe && !terminating
                try await lease.finish(resume: resume)
                if resume {
                    guard host.isRunning else { throw PluginHostError.runtimeFailure("Native runtime did not resume; restart the application") }
                    // Explicitly leaving initial safe mode loads enabled plugins
                    // which that startup deliberately kept inactive.
                    for plugin in host.pluginList() where plugin.enabled && !plugin.loaded {
                        guard !terminating else { throw PluginHostError.notRunning }
                        try await host.reloadPlugin(id: plugin.id)
                    }
                } else { clearEarlyStartupMarker() }
            }
            updateRuntimeStatus()
        } catch {
            status = "Runtime mode failed: \(error)"
            throw error
        }
    }

    private func updateRuntimeStatus() {
        guard let preferences = managerPreferences?.snapshot else { status = managerPreferencesError ?? "Manager preferences unavailable"; return }
        if terminating { status = "Python runtime stopped" }
        else if !hasAccount || currentContext == nil { status = "Waiting for an account" }
        else if toolsRecoveryRequired { status = "Settings recovery required · plugin execution suspended" }
        else if let startupError, host?.isRunning != true { status = "Runtime error: \(startupError)" }
        else if !preferences.engineEnabled { status = "Plugin engine disabled" }
        else if preferences.safeMode { status = "Safe mode · plugin execution suspended" }
        else if host?.isRunning == true { status = "Python runtime ready" }
        else { status = startupError ?? "Plugin runtime is not running" }
    }

    private func updateDeveloperServer() {
        guard !terminating, !changingRuntimeMode, settingsMaintenanceID == nil, !toolsRecoveryRequired,
              pluginExecutionRequested, let store = managerPreferences, store.snapshot.developerMode,
              let capturedHost = host, capturedHost.isRunning, let context = currentContext else { stopDeveloperServices(); return }
        let scope = startupScope
        let activation = elyxActivationScope()
        // Probe and filesystem setup use the Host's detached native activation;
        // the main actor only publishes a fully prepared, still-current service.
        Task { @MainActor [weak self, weak context, weak capturedHost] in
            guard let self, let context, let capturedHost, self.host === capturedHost,
                  self.currentContext === context, self.startupScope == scope, activation.isCurrent else { return }
            do {
                let service = try await capturedHost.activateElyxDeveloper(scope: activation.id, isCurrent: {
                    let state = store.snapshot
                    return activation.isCurrent && state.developerMode && state.permitsPluginExecution
                })
                guard self.host === capturedHost, self.currentContext === context, self.startupScope == scope,
                      !self.terminating, service.isActive else { service.invalidate(); return }
                self.elyxDeveloperService = service
                self.elyxDeveloperFiles = try service.fileAuthority()
            } catch {
                if self.host === capturedHost, self.currentContext === context, self.startupScope == scope {
                    self.services.serviceLogs.append(pluginId: "host", level: .error, message: "Elyx developer activation unavailable (retry allowed): \(error)")
                }
            }
        }
        do { developerServer.start(tokenDirectory: try services.serviceStorage.pluginsDirectory()) }
        catch { services.serviceLogs.append(pluginId: "host", level: .error, message: "Developer server storage unavailable: \(error)") }
    }

    private func retireElyxDeveloperService() {
        elyxDeveloperActivation?.invalidate()
        elyxDeveloperActivation = nil
        elyxDeveloperFiles = nil
        elyxDeveloperService?.invalidate()
        elyxDeveloperService = nil
        host?.deactivateElyxDeveloper()
    }

    private func elyxActivationScope() -> PluginElyxDeveloperActivationScope {
        if let elyxDeveloperActivation, elyxDeveloperActivation.isCurrent { return elyxDeveloperActivation }
        let activation = PluginElyxDeveloperActivationScope()
        elyxDeveloperActivation = activation
        return activation
    }

    private func stopDeveloperServices() {
        developerServer.stop()
        retireElyxDeveloperService()
    }

    private func updateManagerPreference(_ change: PluginManagerPreferenceChange, authority: PluginConfigAuthority? = nil) async throws {
        guard let store = managerPreferences else { throw PluginHostError.runtimeFailure(managerPreferencesError ?? "Manager preferences unavailable") }
        if case .developer = change {
            try Task.checkCancellation()
            guard !terminating, hasAccount, currentContext != nil else { throw PluginHostError.notRunning }
            guard authority?.isCurrent() ?? true else { throw PluginHostError.superseded("Developer preference caller or settings grant expired") }
            if case .developer(false) = change {
                // Retirement is the irreversible part of accepting an off command,
                // before its writer/actor hop. A later on write cannot hide it.
                // Persistence may still fail: propagate that error and retain the
                // store's truthful snapshot; a subsequent start gets fresh authority.
                stopDeveloperServices()
            }
        }
        try await Task.detached(priority: .utility) {
            try store.apply(change, isCurrent: { authority?.isCurrent() ?? true })
        }.value
        if case let .warningMuted(id, value) = change, !value {
            warnedPlugins.remove(id)
            if host?.pluginList().contains(where: { $0.id == id && $0.notResponding }) == true { presentWatchdogWarning(pluginId: id) }
        }
        if case .developer = change { updateDeveloperServer() }
        changed()
    }

    private func handleDeveloperRequest(_ request: [String: PluginUIJSON], session: PluginDeveloperSession) async throws -> [String: PluginUIJSON] {
        if let command = request["@"]?.string, PluginElyxDeveloperRequest.recognizes(command) {
            var capturedRequest: PluginElyxDeveloperRequest?
            var publication = command == "elyx_changes" ? PluginElyxDeveloperPublicationState(pluginId: request["plugin_id"]?.string) : nil
            do {
                try Task.checkCancellation()
                guard session.isActive, managerPreferences?.snapshot.developerMode == true, let context = currentContext else {
                    throw PluginElyxDeveloperError.stale("Developer service is not active")
                }
                try requirePluginExecution()
                guard let capturedHost = self.host, capturedHost.isRunning, let store = managerPreferences,
                      let account = services.accountIndex(recordId: context.account.id.int64) else {
                    throw PluginHostError.notRunning
                }
                // ID, owner and consent are captured before ANY await, including
                // operationHost/startup. Only the selected owners can be read.
                let plan = try PluginElyxDeveloperIngress.capture(request, host: capturedHost, account: account,
                    targets: { try capturedHost.elyxDeveloperTargets($0) })
                capturedRequest = plan.request
                publication = plan.publication
                let services = self.services
                let accountRecord = context.account.id.int64
                let scope = startupScope
                let activation = elyxActivationScope()
                activeOperations += 1
                defer { activeOperations -= 1 }
                let service = try await capturedHost.activateElyxDeveloper(scope: activation.id, isCurrent: {
                    let state = store.snapshot
                    return activation.isCurrent && state.developerMode && state.permitsPluginExecution
                })
                guard self.host === capturedHost, currentContext === context, startupScope == scope,
                      services.accountIndex(recordId: accountRecord) == account,
                      session.isActive, service.isActive else { throw PluginElyxDeveloperError.stale("Elyx captured account/Host/session retired during readiness") }
                elyxDeveloperService = service
                let files = try service.fileAuthority()
                elyxDeveloperFiles = files
                let result = await PluginElyxDeveloperIngress.run(plan, session: session, files: files,
                    nativeCurrent: {
                        let state = store.snapshot
                        return activation.isCurrent && service.isActive && state.developerMode && state.permitsPluginExecution
                            && services.accountIndex(recordId: accountRecord) == account
                    }, execute: { call in
                        try await capturedHost.elyxDeveloper(call.request, targets: call.targets, account: call.account,
                            files: call.files, deadline: call.deadline, shouldExecute: call.isCurrent, publication: call.publication)
                    }, actorCurrent: { [weak self, weak context, weak capturedHost] in
                        guard let self, let context, let capturedHost else { return false }
                        return self.currentContext === context && self.host === capturedHost
                            && self.startupScope == scope && activation.isCurrent && service.isActive
                            && services.accountIndex(recordId: accountRecord) == account
                            && !self.terminating && !self.changingRuntimeMode && self.settingsMaintenanceID == nil
                            && !self.toolsRecoveryRequired
                    })
                if plan.request.kind == .changes {
                    if let target = plan.targets.first, capturedHost.callbackOwner(id: target.plugin.id) != target.owner {
                        invalidateSettingsSchema(id: target.plugin.id)
                    }
                    refreshSubscriptions()
                    changed()
                }
                return result
            } catch { return PluginElyxDeveloperIngress.failure(error, request: capturedRequest, publication: publication) }
        }
        try Task.checkCancellation()
        guard session.isActive, managerPreferences?.snapshot.developerMode == true, let context = currentContext else {
            throw PluginHostError.runtimeFailure("Developer service is not active")
        }
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        func requireSession() throws {
            try Task.checkCancellation()
            try self.requirePluginExecution()
            guard session.isActive, self.currentContext === context, self.host === host,
                  self.managerPreferences?.snapshot.developerMode == true else {
                throw PluginHostError.superseded("Developer request belongs to a retired session/account")
            }
        }
        try requireSession()
        switch request["@"]?.string {
        case "ping": return ["pong": .bool(true)]
        case "get_plugins":
            return ["plugins": .array(host.pluginList().map { plugin in .object([
                "id": .string(plugin.id), "name": plugin.name.map(PluginUIJSON.string) ?? .null,
                "version": .string(plugin.version),
                "author": plugin.author.map(PluginUIJSON.string) ?? .null,
                "enabled": .bool(plugin.enabled), "loaded": .bool(plugin.loaded),
                "has_settings": .bool(plugin.hasSettings), "error": plugin.loadError.map(PluginUIJSON.string) ?? .null
            ]) })]
        case "enable_plugin", "disable_plugin":
            try await self.setEnabled(id: PluginDeveloperProtocol.pluginId(request), enabled: request["@"] == .string("enable_plugin"))
            return [:]
        case "reload_plugin":
            try await self.reloadPlugin(id: PluginDeveloperProtocol.pluginId(request))
            return [:]
        case "remove_plugin":
            try await self.remove(id: PluginDeveloperProtocol.pluginId(request))
            return [:]
        case "write_plugin":
            let upload = try PluginDeveloperProtocol.source(request)
            let directory = try services.serviceStorage.rootDirectory().appendingPathComponent("developer-incoming", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = directory.appendingPathComponent(upload.filename)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try upload.data.write(to: file, options: .atomic)
            }.value
            try requireSession()
            let metadata = try await host.readPluginMetadata(sourceURL: file)
            guard metadata.id == upload.pluginId else { throw PluginHostError.invalidPlugin("Uploaded metadata id does not match plugin_id") }
            try requireSession()
            invalidateSettingsSchema(id: upload.pluginId)
            let installed = try await host.installPlugin(sourceURL: file, metadata: metadata)
            refreshSubscriptions()
            changed()
            if let error = installed.loadError { throw PluginHostError.runtimeFailure(error) }
            return [:]
        case "start_debugger", "stop_debugger":
            throw PluginUIFailure.unsupported("debugpy attach to native isolated owner interpreters is unavailable; no debugger listener was started")
        default:
            throw PluginUIFailure.unsupported("Unknown native developer command: \(request["@"]?.string ?? "missing")")
        }
    }

    private func reloadPlugin(id: String) async throws {
        let host = try await operationHost()
        defer { activeOperations -= 1 }
        guard host.pluginList().contains(where: { $0.id == id }) else { throw PluginHostError.pluginNotFound(id) }
        invalidateSettingsSchema(id: id)
        try await host.reloadPlugin(id: id)
        refreshSubscriptions()
        changed()
        if let error = host.pluginList().first(where: { $0.id == id })?.loadError { throw PluginHostError.runtimeFailure(error) }
    }

    private func presentWatchdogWarning(pluginId: String) {
        guard managerPreferences?.snapshot.warningMuted.contains(pluginId) != true,
              !warnedPlugins.contains(pluginId), watchdogAlert == nil,
              UIApplication.shared.applicationState == .active, let context = currentContext,
              let presenter = pluginUI?.currentPresenter(context), presenter.viewIfLoaded?.window != nil else { return }
        let name = host?.pluginList().first(where: { $0.id == pluginId })?.displayName ?? pluginId
        let alert = UIAlertController(title: pluginText("Plugin.NotResponding", "Plugin not responding"),
            message: "\(name) was isolated by the native watchdog. Disable it to prevent loading on the next launch.", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = context.sharedContext.currentPresentationData.with { $0.theme.overallDarkAppearance } ? .dark : .light
        alert.addAction(UIAlertAction(title: pluginText("Plugin.Disable", "Disable plugin"), style: .destructive, handler: { [weak self] _ in
            self?.watchdogAlert = nil
            Task { @MainActor [weak self] in
                do { try await self?.setEnabled(id: pluginId, enabled: false) }
                catch { self?.services.serviceLogs.append(pluginId: pluginId, level: .error, message: "Disable after watchdog: \(error)") }
            }
        }))
        alert.addAction(UIAlertAction(title: pluginText("Plugin.MuteWarnings", "Mute warnings"), style: .default, handler: { [weak self] _ in
            self?.watchdogAlert = nil
            Task { @MainActor [weak self] in
                do { try await self?.updateManagerPreference(.warningMuted(pluginId, true)) }
                catch { self?.services.serviceLogs.append(pluginId: pluginId, level: .error, message: "Mute watchdog warning: \(error)") }
            }
        }))
        alert.addAction(UIAlertAction(title: pluginText("Common.Close", "Close"), style: .cancel, handler: { [weak self] _ in self?.watchdogAlert = nil }))
        warnedPlugins.insert(pluginId)
        watchdogAlert = alert
        presenter.present(alert, animated: true)
    }

    private func enqueueCallback(host: PluginHost, owner: PluginHost.CallbackOwner, handle: Int64,
                                 method: String, json: String, delayMs: Int, tlOrigin: PluginTLInvocationOrigin?) {
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
                                              argumentsJSON: json, expectedOwner: owner, tlOrigin: tlOrigin)
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
                let shouldExecute = PluginHookRouter.currentSendExecutionPredicate()
                let task = Task { @MainActor [weak self] in
                    guard let self, let host = self.host, host.isRunning,
                          let account = self.services.accountIndex(recordId: payload.accountRecordId),
                          !Task.isCancelled, shouldExecute() else {
                        completion(.keepOriginal)
                        return
                    }
                    do {
                        let decision = try await host.events.preSendMessageResult(SendMessagePayload(
                            account: account, paramsJSON: payload.jsonString()), shouldExecute: shouldExecute)
                        var json: [String: Any] = ["strategy": decision.strategy.rawValue]
                        if let params = decision.paramsJSON {
                            json["params"] = try JSONSerialization.jsonObject(with: Data(params.utf8))
                        }
                        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
                        let result = PluginSendResultCodec.decodeOrKeepOriginal(encoded, original: payload)
                        if !Task.isCancelled, shouldExecute() { completion(result) }
                    } catch {
                        logs.append(pluginId: "host", level: .error, message: "Send hook: \(error)")
                        if !Task.isCancelled, shouldExecute() { completion(.keepOriginal) }
                    }
                }
                return PluginHookCancellation { task.cancel() }
            },
            observe: { [weak self] event in
                do {
                    let json = try PluginTLObservationCodec.jsonString(event)
                    guard event.reserveDeliveryBytes(json.utf8.count) else { return }
                    Task { @MainActor [weak self] in self?.forward(event, json: json) }
                } catch {
                    logs.append(pluginId: "host", level: .error, message: "Hook observation encoding: \(error)")
                }
            },
            diagnostic: { value in
                logs.append(pluginId: "host", level: .warning, message: "\(value.code.rawValue): \(value.detail)")
            }))
        if let host {
            let services = self.services
            tlTransforms = PluginTLTransformIntegration(host: host,
                accountIndex: { services.accountIndex(recordId: $0) },
                diagnostic: { logs.append(pluginId: "host", level: .warning, message: $0) })
        }
    }

    private func forward(_ event: PluginHookObservation, json: String) {
        guard let host, host.isRunning else { return }
        switch event {
        case .preRequest(let value):
            guard let account = services.accountIndex(recordId: value.metadata.accountRecordId) else { return }
            host.events.emitPreRequest(RequestPayload(requestName: PluginTLObservationCodec.hookName(value.metadata.requestName), account: account, requestJSON: json))
        case .postRequest(let value):
            guard let account = services.accountIndex(recordId: value.metadata.accountRecordId) else { return }
            host.events.emitPostRequest(RequestResponsePayload(requestName: PluginTLObservationCodec.hookName(value.metadata.requestName), account: account,
                                                               responseJSON: json, errorMessage: value.error?.message))
        case .update(let value):
            guard let account = services.accountIndex(recordId: value.accountRecordId) else { return }
            host.events.emitUpdate(name: PluginTLObservationCodec.hookName(value.name), account: account, updateJSON: json)
        case .updates(let value):
            guard let account = services.accountIndex(recordId: value.accountRecordId) else { return }
            host.events.emitUpdates(container: PluginTLObservationCodec.hookName(value.name), account: account, updatesJSON: [json])
        }
    }

    private func refreshSubscriptions() {
        tlTransforms?.updateSubscriptions(active: hasAccount)
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
