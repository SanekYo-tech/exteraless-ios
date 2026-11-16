import ExteralessCore
import Foundation
import PluginHost

/// UI/context and transport boundaries only. The driver inserts byte-exact
/// shipping Root methods/bridge initializers at the markers below. No listener,
/// AccountContext, UIKit, alternate preference writer or alternate queue runs.
final class ModeFixtureContext {}

final class ModeFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ModeFixtureTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginDeveloperSession?
    private var starts = 0
    private var calls = 0
    var session: PluginDeveloperSession? { lock.lock(); defer { lock.unlock() }; return current }
    var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var snapshot: PluginDeveloperConnectionState { .init(status: "owned no-network transport boundary", token: nil) }
    func start(tokenDirectory: URL) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if current == nil { current = PluginDeveloperSession(); starts += 1 }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        current?.cancel(); current = nil
    }
}

final class ModeFixtureServices: @unchecked Sendable {
    let serviceStorage: PluginServiceStorage
    let serviceLogs = PluginServiceLogBuffer()
    init(root: URL) { serviceStorage = PluginServiceStorage(rootDirectory: root) }
}

@MainActor
final class NativeElyxModeRootFixture {
    var host: PluginHost?
    var managerPreferences: PluginManagerPreferences?
    var managerPreferencesError: String?
    var currentContext: ModeFixtureContext? = ModeFixtureContext()
    var hasAccount = true
    var terminating = false
    var changingRuntimeMode = false
    var settingsMaintenanceID: UUID?
    var toolsRecoveryRequired = false
    var activeOperations = 0
    var startupScope = UUID()
    var warnedPlugins = Set<String>()
    var status = "fixture"
    let services: ModeFixtureServices
    let developerServer = ModeFixtureTransport()
    let completions = ModeFixtureCounter()
    var elyxDeveloperFiles: (any PluginElyxDeveloperFileAuthority)?
    var elyxDeveloperService: PluginElyxDeveloperService?
    var elyxDeveloperActivation: PluginElyxDeveloperActivationScope?
    var config: PluginConfigBridgeExtension!
    var developer: PluginDeveloperBridgeExtension!

    init(host: PluginHost, store: PluginManagerPreferences, root: URL) {
        self.host = host; managerPreferences = store; services = ModeFixtureServices(root: root)
        let managerStore = store
        let callbacks = PluginCallbackDispatcher(host: host)
        let logs = services.serviceLogs
        // PRODUCTION_BRIDGE_INITIALIZERS
        config = pluginConfig
        self.developer = developer
    }

    func managerDeveloper(_ value: Bool, authority: PluginConfigAuthority? = nil) async throws {
        try await updateManagerPreference(.developer(value), authority: authority)
    }
    func refreshDeveloper() { updateDeveloperServer() }
    func close() { terminating = true; stopDeveloperServices() }
    private func changed() { completions.increment() }
    private func presentWatchdogWarning(pluginId: String) { preconditionFailure("fixture did not request watchdog UI") }
    private func setRuntimeMode(_ change: PluginManagerPreferenceChange) async throws {
        throw PluginUIFailure.unsupported("fixture never changes engine/safe mode")
    }

    // PRODUCTION_ROOT_METHODS
}
