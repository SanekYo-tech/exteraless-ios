import Foundation
import Darwin

// Compile alongside every Sources/PluginHost/*.swift file, with the actual C
// engine/bridge linked. A parent process enforces the 30-second hard deadline.
#if !canImport(CExteralessPythonBridge)
#error("swift_plugin_probe requires the real CExteralessPythonBridge module")
#endif
import CExteralessPythonBridge

private let fixtureID = "nativeWaveProbe"
private let fixtureAccount: Int32 = 2

private struct IntegrationFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw IntegrationFailure(description: message) }
}

private func quote(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
}

private func threadID() -> UInt64 {
    var value: UInt64 = 0
    _ = pthread_threadid_np(nil, &value)
    return value
}

private struct FixtureEvent: Codable, Sendable {
    let method: String
    let pluginId: String?
    let account: Int32?
    let event: String?
}

private struct PythonObservation: Codable, Sendable {
    let nativeReference: Int64
    let threadId: UInt64
    let pluginId: String?
    let profileActive: Bool
    let sdkLoaderPresent: Bool
    let metadataCalls: Int
    let sdkCalls: [String: Int]
    let fixtureCalls: [String: Int]
    let transportCalls: Int
    let transportErrors: Int
    let bridgeBackendCalls: Int
    let nativeMembers: [String: Int]
    let sources: [String: String]
    let modulePaths: [String: String]
    let events: [FixtureEvent]
    let problems: [String]
    let bridgeBuiltin: Bool
    let backendInstalled: Bool
    let legacyServiceCount: Int
    let mockCalls: Int
    let handleCount: Int
    let loadedPlugins: [String]
    let checksHandle: Int64?
    let servicesVerified: Bool
    let unknownRejected: Bool
    let directories: [String: String]
    let ownerToken: String?
    let sdkChecks: [String: Bool]
    let callbackLeases: Int
}

private struct InterpreterTrace: Encodable, Sendable {
    let nativeReference: Int64
    let ownGIL: Bool
    let ownerThreadId: UInt64
    let ownerThreadName: String
    var profilerInstalled = false
    var hostSources: [String] = []
    var probeSourceCalls = 0
    var destroyed = false
    var observation: PythonObservation?
    var errors: [String] = []
}

private struct NativeTrace: Encodable, Sendable {
    var initializations = 0
    var finalizations = 0
    var interpreters: [InterpreterTrace] = []

    var hostSourceCalls: Int { interpreters.reduce(0) { $0 + $1.hostSources.count } }
}

/// Recording forwarder, not an engine substitute: every host source is passed
/// unchanged, exactly once, to CPythonXCFrameworkEngine. Separate, counted probe
/// sources install/read sys.setprofile on the same native owner worker. No SDK
/// function, native service, return value or Python backend is replaced.
private final class ObservedNativeEngine: CPythonEngine, @unchecked Sendable {
    private let native = CPythonXCFrameworkEngine()
    private let lock = NSLock()
    private let helper: String
    private let pythonRoot: String
    private let installedPlugin: String
    private var records: [Int64: InterpreterTrace] = [:]
    private var initializations = 0
    private var finalizations = 0

    init(helper: String, pythonRoot: String, installedPlugin: String) {
        self.helper = helper
        self.pythonRoot = pythonRoot
        self.installedPlugin = installedPlugin
    }

    var apiVersion: String { native.apiVersion }
    var isProcessInitialized: Bool { native.isProcessInitialized }

    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        try native.initializeProcess(configuration: configuration)
        lock.lock(); initializations += 1; lock.unlock()
    }

    func finalizeProcess() throws {
        try native.finalizeProcess()
        lock.lock(); finalizations += 1; lock.unlock()
    }

    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        try require(!Thread.isMainThread && threadID() != 0, "interpreter creation reached the main/unknown thread")
        try require(configuration.ownsGIL && !configuration.useMainObmalloc && configuration.checkMultiInterpExtensions,
                    "the host did not request an isolated OWN_GIL interpreter")
        let reference = try native.createInterpreter(configuration)
        let record = InterpreterTrace(nativeReference: reference.raw, ownGIL: configuration.ownsGIL,
            ownerThreadId: threadID(), ownerThreadName: Thread.current.name ?? "unnamed")
        lock.lock(); records[reference.raw] = record; lock.unlock()
        return reference
    }

    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        let before = try record(reference)
        try require(!Thread.isMainThread && before.ownerThreadId == threadID(), "host source left its native owner worker")
        do {
            if !before.profilerInstalled {
                _ = try probeSource(reference, """
                import importlib.util as _probe_import
                import sys as _probe_sys
                _probe_spec = _probe_import.spec_from_file_location('_native_plugin_probe', \(quote(helper)))
                _native_plugin_probe = _probe_import.module_from_spec(_probe_spec)
                _probe_sys.modules['_native_plugin_probe'] = _native_plugin_probe
                _probe_spec.loader.exec_module(_native_plugin_probe)
                _native_plugin_probe.install(\(quote(pythonRoot)), \(quote(installedPlugin)), \(reference.raw))
                """)
                update(reference) { $0.profilerInstalled = true }
            }
            update(reference) { $0.hostSources.append(source) }
            let result = try native.runScript(reference, source)
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                _ = try probeSource(reference, "_native_plugin_probe.export_checks()")
            }
            try capture(reference)
            return result
        } catch {
            update(reference) { $0.errors.append(String(describing: error)) }
            try? capture(reference)
            throw error
        }
    }

    func destroyInterpreter(_ reference: InterpRef) throws {
        let before = try record(reference)
        try require(!Thread.isMainThread && before.ownerThreadId == threadID(), "destroy left its native owner worker")
        if before.profilerInstalled {
            do { try capture(reference, finishing: true) }
            catch { update(reference) { $0.errors.append("final observation: \(error)") } }
        }
        try native.destroyInterpreter(reference)
        update(reference) { $0.destroyed = true }
    }

    func interpreterFootprintKB(_ reference: InterpRef) -> Int { native.interpreterFootprintKB(reference) }

    var trace: NativeTrace {
        lock.lock(); defer { lock.unlock() }
        return NativeTrace(initializations: initializations, finalizations: finalizations,
                           interpreters: records.values.sorted { $0.nativeReference < $1.nativeReference })
    }

    private func probeSource(_ reference: InterpRef, _ source: String) throws -> String {
        update(reference) { $0.probeSourceCalls += 1 }
        return try native.runScript(reference, source)
    }

    private func capture(_ reference: InterpRef, finishing: Bool = false) throws {
        let method = finishing ? "finish_json" : "snapshot_json"
        let json = try probeSource(reference, "_native_plugin_probe.\(method)()")
        let observation = try JSONDecoder().decode(PythonObservation.self, from: Data(json.utf8))
        try require(observation.nativeReference == reference.raw, "profiler snapshot belongs to another native interpreter")
        update(reference) { $0.observation = observation }
    }

    private func record(_ reference: InterpRef) throws -> InterpreterTrace {
        lock.lock(); defer { lock.unlock() }
        guard let value = records[reference.raw] else {
            throw IntegrationFailure(description: "unknown observed native interpreter \(reference.raw)")
        }
        return value
    }

    private func update(_ reference: InterpRef, _ change: (inout InterpreterTrace) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[reference.raw] else { return }
        change(&record)
        records[reference.raw] = record
    }
}

/// Headless test fixture for the Telegram messages/account service and UIKit/UI
/// service. Core BridgeServices, PluginServiceStorage and log storage are real.
/// Only the declared account snapshot exists. The dedicated TL child can install
/// its narrow legacy-text DTO recorder; the baseline rejects every native effect.
final class NativeSDKFixtureServices: PluginMessagesService, PluginSettingsService,
    PluginUIService, PluginPlatformService, @unchecked Sendable {
    let platformSnapshot: PluginPlatformSnapshot
    let serviceStorage: PluginServiceStorage
    let serviceLogs = PluginServiceLogBuffer(capacity: 128)
    let runtimeVersion = "native-swift-sdk-fixture/1"
    private let lock = NSLock()
    private var rejectedEffects: [String] = []
    private let textRecorder: (@Sendable (PluginTextMessageRequest) throws -> String)?

    init(root: URL, textRecorder: (@Sendable (PluginTextMessageRequest) throws -> String)? = nil,
         additionalAccounts: [PluginServiceAccount] = []) {
        serviceStorage = PluginServiceStorage(rootDirectory: root)
        self.textRecorder = textRecorder
        platformSnapshot = PluginPlatformSnapshot(accounts: [
            PluginServiceAccount(index: fixtureAccount, recordId: 9_007_199_254_740_993, userId: 101)
        ] + additionalAccounts, selectedAccountIndex: fixtureAccount)
    }
    func selectedAccount() throws -> Int32 { try platformSnapshot.selectedAccount() }
    func instanceHandle(fqcn: String, account: Int32) throws -> Int64 { throw reject("instanceHandle: \(fqcn)") }
    func themeKey(_ name: String) throws -> String { try platformSnapshot.themeKey(name) }
    func themeColor(forKey key: String) throws -> Int32 { try platformSnapshot.themeColor(forKey: key) }
    func dp(_ value: Double) throws -> Double { throw reject("dp") }
    func constructUI(fqcn: String, arguments: [Any]) throws -> Int64 { throw reject("constructUI: \(fqcn)") }
    func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void) {
        // Nonthrowing protocol requirement: record a hard probe failure. Python
        // callbacks must instead use BridgeServices.onOwnedCallback and the host queue.
        _ = reject("runOnUIThread bypassed the owner callback scheduler")
    }
    func addToClipboard(_ text: String, pluginId: String, lease: PluginNativeCallLease) throws {
        try lease.check()
        throw reject("addToClipboard")
    }
    func openURL(_ url: URL, pluginId: String, lease: PluginNativeCallLease) throws {
        try lease.check()
        throw reject("openURL")
    }
    func sendMessage(_ request: PluginTextMessageRequest, lease: PluginNativeCallLease) throws -> String {
        try lease.check()
        if let textRecorder { return try textRecorder(request) }
        throw reject("sendMessage")
    }

    var unexpectedEffects: [String] {
        lock.lock(); defer { lock.unlock() }
        return rejectedEffects
    }

    private func reject(_ name: String) -> BridgeFailure {
        lock.lock(); rejectedEffects.append(name); lock.unlock()
        return .unimplemented("NativeSDKFixtureServices has no effect implementation for \(name)")
    }
}

private struct CallbackRequest: Encodable, Sendable {
    let pluginId: String
    let handle: Int64
    let method: String
    let argumentsJSON: String
    let delayMs: Int
    let arrivedOnMainThread: Bool
    let ownerToken: String
}

private final class OwnerCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatcher: PluginCallbackDispatcher?
    private var owner: PluginHost.CallbackOwner?
    private var requests: [CallbackRequest] = []
    private var completed = 0

    func bind(host: PluginHost) {
        lock.lock(); defer { lock.unlock() }
        dispatcher = PluginCallbackDispatcher(host: host)
    }

    func enqueue(host: PluginHost, id: String, epoch: String?, handle: Int64, method: String, arguments: String, delay: Int) -> Bool {
        guard let owner = host.callbackOwner(id: id), owner.wireToken == epoch else { return false }
        guard !Thread.isMainThread, id == fixtureID, handle > 0,
              method == "run", arguments == "[]", delay == 0, let dispatcher = currentDispatcher() else { return false }
        let request = CallbackRequest(pluginId: id, handle: handle, method: method,
            argumentsJSON: arguments, delayMs: delay, arrivedOnMainThread: Thread.isMainThread, ownerToken: owner.wireToken)
        guard dispatcher.callback(owner, handle, method, arguments) else { return false }
        lock.lock()
        self.owner = owner
        requests.append(request)
        lock.unlock()
        return true
    }

    func drain(checks: Int64? = nil) async throws {
        guard let pending = pendingBarrier() else { return }
        guard let checks else { throw IntegrationFailure(description: "owner callback fence requires its SDK checks handle") }
        let result = try await pending.dispatcher.result(pending.owner, checks, "barrier", "[]")
        try require(result == "null", "owner callback FIFO fence returned a non-void result")
        noteCompletion(pending.count)
    }

    var snapshot: (requests: [CallbackRequest], completed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, completed)
    }

    private func currentDispatcher() -> PluginCallbackDispatcher? {
        lock.lock(); defer { lock.unlock() }
        return dispatcher
    }

    private func pendingBarrier() -> (dispatcher: PluginCallbackDispatcher, owner: PluginHost.CallbackOwner, count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard completed < requests.count, let dispatcher, let owner else { return nil }
        return (dispatcher, owner, requests.count)
    }

    private func noteCompletion(_ count: Int) { lock.lock(); completed = count; lock.unlock() }
}

private struct IntegrationReport: Encodable, Sendable {
    var ok = false
    let probe = "swift-plugin-embedding"
    let executionPlatform = "macOS host CPython"
    let messagesService = "strict Foundation NativeSDKFixtureServices test fixture (Telegram service substitute)"
    let uiService = "strict Foundation NativeSDKFixtureServices test fixture (UIKit service substitute)"
    let storageImplementation = "PluginServiceStorage (core implementation, isolated disk root)"
    let uikitExecuted = false
    let telegramServicesExecuted = false
    var phase = "initializing"
    var python: String?
    var metadataASTOnly = false
    var disabledInstall = false
    var nativeBridge = false
    var sdkLoaderAndSerializer = false
    var settingsUnicodeAndNul = false
    var settingsClick = false
    var ownerCallback = false
    var runtimeServices = false
    var providedDependencies = false
    var appResume = false
    var modifyWithParams = false
    var cancelSend = false
    var permissionGate = false
    var disabledGate = false
    var unload = false
    var reloadPersistence = false
    var freshReloadInterpreter = false
    var finalized = false
    var bindingUninstalled = false
    var pluginInterpreterIds: [Int64] = []
    var nativeTrace = NativeTrace()
    var callbackRequests: [CallbackRequest] = []
    var completedCallbacks = 0
    var unexpectedEffects: [String] = []
    var nativeLogMessages: [String] = []
    var sdkDTOBoundary = "Foundation DTO recorders; no UIKit/network/server acceptance"
    var immutableCOwner = false
    var bulkOpaqueSettings = false
    var terminalUILease = false
    var uiLiveModels = false
    var ownerTaskResult = false
    var asyncCallbackResult = false
    var requestResponseDTO = false
    var extensionReflection = false
    var removedExtensionUnknown = false
    var staleOwnerRejected = false
    var transientHandlesReleased = false
    var sdkDTOObservation: PluginJSONValue = .null
    var error: String?

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

@main
struct SwiftPluginProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 10 && arguments.last == "--tl-phase2" {
            exit(await SDKTLNativeProbe.run(Array(arguments.dropLast())))
        }
        if arguments.count == 10 && arguments.last == "--hns-remediation" {
            exit(await SDKHNSNativeProbe.run(Array(arguments.dropLast())))
        }
        guard arguments.count == 9 else {
            log("usage: swift-plugin-probe report.json python-home stdlib dynload python-root plugin workdir probe-helper.py")
            exit(2)
        }
        let reportURL = URL(fileURLWithPath: arguments[1])
        let work = URL(fileURLWithPath: arguments[7], isDirectory: true).standardizedFileURL
        let services = NativeSDKFixtureServices(root: work.appendingPathComponent("native-storage", isDirectory: true))
        let callbacks = OwnerCallbackQueue()
        var report = IntegrationReport()
        var engine: ObservedNativeEngine?
        var host: PluginHost?
        var binding: NativeBridgeBinding?
        var sdkFixture: SDKDTOFixture?

        do {
            try report.write(to: reportURL)
            let pluginDirectory = try services.serviceStorage.pluginsDirectory()
            let observed = ObservedNativeEngine(helper: arguments[8], pythonRoot: arguments[5],
                installedPlugin: pluginDirectory.appendingPathComponent(fixtureID + ".plugin").path)
            engine = observed
            try require(!observed.isProcessInitialized, "probe must start in a fresh process")
            let configuration = PythonRuntimeConfiguration(
                programName: "exteraless-swift-plugin-probe", frameworkHome: arguments[2],
                stdlibDirectories: [arguments[3], arguments[4]],
                compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
                pluginRootDirectory: pluginDirectory.path, writeBytecode: false, installSignalHandlers: false,
                manifestPath: work.appendingPathComponent("manifest.json").path,
                executablePath: URL(fileURLWithPath: arguments[0]).standardizedFileURL.path)
            let current = try PluginHost(engine: observed,
                configuration: PluginHost.Configuration(runtime: configuration,
                    interpreters: PythonInterpreterLimits(maxInterpreters: 4, callTimeout: 5),
                    storageDirectory: pluginDirectory),
                services: PluginHost.BridgeServiceSet(messages: services, settings: services, ui: services),
                log: { SwiftPluginProbe.log("HOST " + $0) })
            host = current
            callbacks.bind(host: current)
            current.bridge.onOwnedCallback = { [weak current, callbacks] id, epoch, handle, method, args, delay in
                guard let current else { return false }
                return callbacks.enqueue(host: current, id: id, epoch: epoch, handle: handle, method: method, arguments: args, delay: delay)
            }
            let nativeBinding = NativeBridgeBinding(services: current.bridge)
            binding = nativeBinding
            try nativeBinding.install()
            try await current.start()
            try require(current.isRunning && observed.isProcessInitialized, "host.start did not start the real native runtime")
            report.python = observed.apiVersion
            try require(observed.apiVersion.hasPrefix("3.12."), "expected CPython 3.12")
            try require(current.pluginList().isEmpty && current.events.subscribers.isIdle, "isolated host was not empty")

            report.phase = "metadata-and-disabled-install"
            try report.write(to: reportURL)
            let input = URL(fileURLWithPath: arguments[6])
            var metadata = try await current.readPluginMetadata(sourceURL: input)
            try require(metadata.id == fixtureID && metadata.name == "Native Wave Probe" && metadata.version == "1.0",
                        "unexpected native fixture metadata")
            try require(Set(metadata.permissions) == Set(["ui", "messages.send", "network"]), "SDK metadata permissions were lost")
            let inspection = observed.trace.interpreters
            try require(inspection.count == 1 && inspection[0].destroyed, "metadata inspector leaked or created extra interpreters")
            guard let ast = inspection[0].observation else { throw IntegrationFailure(description: "missing AST observations") }
            try require(ast.metadataCalls > 0 && !ast.sdkLoaderPresent && ast.transportCalls == 0 && ast.fixtureCalls.isEmpty,
                        "metadata inspection imported/executed the plugin or entered native services")
            try require(try stored(services, "loads") == .null, "metadata inspection ran on_plugin_load")
            report.metadataASTOnly = true
            metadata.enabled = false
            let installed = try await current.installPlugin(sourceURL: input, metadata: metadata)
            try require(!installed.enabled && !installed.loaded && current.events.subscribers.isIdle, "disabled install loaded the plugin")
            try require(observed.trace.interpreters.count == 1, "disabled install created a plugin interpreter")
            guard let copied = installed.path else { throw IntegrationFailure(description: "installed path is missing") }
            try require(try Data(contentsOf: URL(fileURLWithPath: copied)) == Data(contentsOf: input), "installed source differs from the fixture")
            report.disabledInstall = true
            try require(Set(current.grantedPermissions(id: fixtureID)) == Set([.ui]), "unexpected default grants")
            try current.setGrantedPermissions(id: fixtureID, permissions: [.messagesSend, .network])
            try require(Set(current.grantedPermissions(id: fixtureID)) == Set([.ui, .messagesSend, .network]), "grant API did not preserve messages.send/network")

            report.phase = "load-and-native-settings"
            try report.write(to: reportURL)
            try await current.setPluginEnabled(id: fixtureID, true)
            try checkLoaded(current)
            try require(try stored(services, "loads") == .integer(1), "SDK on_plugin_load did not persist exactly one load")
            guard case .object(let dependencies) = try stored(services, "provided_dependencies") else {
                throw IntegrationFailure(description: "fixture did not import its provided dependencies")
            }
            try require(dependencies["requests_from_vendor"] == .bool(true)
                && dependencies["certifi_from_vendor"] == .bool(true)
                && string(dependencies["requests"])?.hasPrefix("2.") == true
                && string(dependencies["cachetools"])?.hasPrefix("8.") == true,
                "requirements resolved outside the sealed vendor directory")
            report.providedDependencies = true
            let first = try activeTrace(observed)
            report.pluginInterpreterIds.append(first.nativeReference)
            try checkNative(first)
            report.nativeBridge = true
            let initialRows = try await settingsRows(current)
            try checkRows(initialRows, prefix: "native:", cancel: false)
            let prefix = "Привет, 雪 😀\u{0} → "
            try await current.updateSetting(id: fixtureID, key: "prefix", valueJSON: quote(prefix))
            try require(try stored(services, "prefix") == .string(prefix), "native disk storage truncated Unicode/NUL")
            let editedRows = try await settingsRows(current)
            try checkRows(editedRows, prefix: prefix, cancel: false)
            report.settingsUnicodeAndNul = true
            guard let clickId = string(editedRows[3]["callback_id"]), !clickId.isEmpty else {
                throw IntegrationFailure(description: "SDK Text row omitted its current callback_id")
            }
            try await current.clickSetting(id: fixtureID, callbackId: clickId)
            try require(try stored(services, "clicks") == .integer(1), "SDK Text callback did not run exactly once")
            report.settingsClick = true

            guard let checks = try activeTrace(observed).observation?.checksHandle, checks > 0 else {
                throw IntegrationFailure(description: "native probe callback handle was not exported")
            }
            try await current.invokeCallback(id: fixtureID, handle: checks, method: "verify_services")
            let verified = try activeTrace(observed).observation
            try require(verified?.servicesVerified == true && verified?.unknownRejected == true,
                        "Runtime directory/version/remove/error calls did not complete through Swift")
            report.runtimeServices = true
            try await current.invokeCallback(id: fixtureID, handle: checks, method: "queue_click")
            try require(callbacks.snapshot.requests.count == 1, "SDK runnable did not reach Swift BridgeServices.onOwnedCallback")
            try await callbacks.drain(checks: checks)
            try require(callbacks.snapshot.completed == 1 && (try stored(services, "clicks")) == .integer(2),
                        "queued callback did not reenter the real plugin on its owner")
            report.ownerCallback = true

            report.phase = "sdk-native-dto-and-owner-epoch"
            try report.write(to: reportURL)
            guard let firstOwner = current.callbackOwner(id: fixtureID) else {
                throw IntegrationFailure(description: "SDK fixture has no native CallbackOwner")
            }
            try require(first.observation?.ownerToken == firstOwner.wireToken, "Host did not bind the C/SDK owner epoch before load")
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "reflection", argumentsJSON: "[false]", expectedOwner: firstOwner)
            let dtoFixture = SDKDTOFixture(host: current)
            sdkFixture = dtoFixture
            current.bridge.extensionProvider = dtoFixture
            let ownerJSON = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "verify_owner", expectedOwner: firstOwner)
            try require(try JSONDecoder().decode(String.self, from: Data(ownerJSON.utf8)) == firstOwner.wireToken, "native C owner echo differs from Host")
            report.immutableCOwner = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "reflection", argumentsJSON: "[true]", expectedOwner: firstOwner)
            report.extensionReflection = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "bulk_settings", expectedOwner: firstOwner)
            report.bulkOpaqueSettings = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "begin_ui", expectedOwner: firstOwner)
            try await dtoFixture.completeUI(checks: checks)
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "after_ui", expectedOwner: firstOwner)
            report.terminalUILease = true
            report.uiLiveModels = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "begin_task", expectedOwner: firstOwner)
            let taskResult = try await dtoFixture.completeTask(checks: checks)
            try require(taskResult == .null, "Runnable exported an ignored Python result")
            report.ownerTaskResult = true
            let callbackJSON = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "async_result", expectedOwner: firstOwner)
            let callbackValue = try JSONDecoder().decode(PluginJSONValue.self, from: Data(callbackJSON.utf8))
            try require(callbackValue == .object(["value": .integer(42), "text": .string("result 雪\u{0}π"), "taskDone": .bool(true)]), "Host async result did not return actual callback JSON")
            report.asyncCallbackResult = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "begin_request", expectedOwner: firstOwner)
            try await dtoFixture.completeRequest(checks: checks)
            try require(try stored(services, "sdk_request_done") == .bool(true), "native DTO reply did not reach the SDK request callback")
            report.requestResponseDTO = true
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "after_transients", expectedOwner: firstOwner)
            report.transientHandlesReleased = true
            current.bridge.extensionProvider = nil
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "reflection", argumentsJSON: "[false]", expectedOwner: firstOwner)
            report.removedExtensionUnknown = true
            current.bridge.extensionProvider = dtoFixture

            report.phase = "events-and-send-decisions"
            try report.write(to: reportURL)
            try await current.deliverAppEvent("app_resume")
            try require(try stored(services, "last_event") == .string("RESUME"), "SDK app_resume -> RESUME mapping did not execute")
            report.appResume = true
            let params: PluginJSONValue = .object([
                "text": .string("hello"), "peerId": .integer(9_007_199_254_740_993),
                "extra": .object(["empty": .null, "flag": .bool(true)])
            ])
            let paramsJSON = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
            let payload = SendMessagePayload(account: fixtureAccount, paramsJSON: paramsJSON)
            let modified = try await current.events.preSendMessageResult(payload)
            try require(modified.strategy == .modify, "send hook did not return MODIFY")
            guard let replacement = modified.paramsJSON else { throw IntegrationFailure(description: "MODIFY lost replacement params") }
            let expected: PluginJSONValue = .object([
                "text": .string(prefix + "hello"), "peerId": .integer(9_007_199_254_740_993),
                "extra": .object(["empty": .null, "flag": .bool(true)])
            ])
            try require(try JSONDecoder().decode(PluginJSONValue.self, from: Data(replacement.utf8)) == expected,
                        "MODIFY lost text, NUL, Int64 peerId or nested params")
            report.modifyWithParams = true
            try current.setGrantedPermissions(id: fixtureID, permissions: [])
            try require(!current.events.subscribers.hasSubscribers(.sendMessage)
                && current.events.subscribers.hasSubscribers(.appEvent), "permission change did not update subscriber gates")
            let callsBeforeGate = observed.trace.hostSourceCalls
            let gated = try await current.events.preSendMessageResult(payload)
            try require(gated.strategy == .default && gated.paramsJSON == nil && observed.trace.hostSourceCalls == callsBeforeGate,
                        "permission-gated send still entered Python")
            try current.setGrantedPermissions(id: fixtureID, permissions: [.messagesSend, .network])
            report.permissionGate = true
            try await current.updateSetting(id: fixtureID, key: "cancel", valueJSON: "true")
            let cancelled = try await current.events.preSendMessageResult(payload)
            try require(cancelled.strategy == .cancel, "cancel setting did not produce SDK CANCEL")
            report.cancelSend = true

            report.phase = "disable-and-reload"
            try report.write(to: reportURL)
            try await current.setPluginEnabled(id: fixtureID, false)
            let disabledPlugin = try plugin(current)
            try require(!disabledPlugin.loaded && current.events.subscribers.isIdle, "disable retained loaded state or subscribers")
            try require(try stored(services, "unloads") == .integer(1), "disable omitted SDK on_plugin_unload")
            let callsBeforeDisable = observed.trace.hostSourceCalls
            let disabled = try await current.events.preSendMessageResult(payload)
            try require(disabled.strategy == .default && observed.trace.hostSourceCalls == callsBeforeDisable,
                        "disabled plugin still received a send hook")
            report.disabledGate = true
            report.unload = true
            try await current.setPluginEnabled(id: fixtureID, true)
            try checkLoaded(current)
            let second = try activeTrace(observed)
            report.pluginInterpreterIds.append(second.nativeReference)
            try require(second.nativeReference != first.nativeReference, "reload reused its old C interpreter")
            try require(observed.trace.interpreters.first(where: { $0.nativeReference == first.nativeReference })?.destroyed == true,
                        "previous C interpreter survived disable")
            try checkNative(second)
            guard let secondOwner = current.callbackOwner(id: fixtureID),
                  let secondChecks = second.observation?.checksHandle else {
                throw IntegrationFailure(description: "reloaded SDK fixture has no owner/checks handle")
            }
            try require(secondOwner.wireToken != firstOwner.wireToken, "reload reused its random native owner epoch")
            _ = try await current.invokeCallbackResult(id: fixtureID, handle: secondChecks, method: "verify_owner", expectedOwner: secondOwner)
            do {
                _ = try await current.invokeCallbackResult(id: fixtureID, handle: checks, method: "verify_services", expectedOwner: firstOwner)
                throw IntegrationFailure(description: "retired owner entered the replacement interpreter")
            } catch PluginHostError.superseded {
                report.staleOwnerRejected = true
            }
            try require(try stored(services, "loads") == .integer(2), "reload did not execute SDK on_plugin_load again")
            try require(try stored(services, "unloads") == .integer(1), "reload duplicated unload")
            let reloadedRows = try await settingsRows(current)
            try checkRows(reloadedRows, prefix: prefix, cancel: true)
            try require(try stored(services, "clicks") == .integer(2), "reload lost native callback settings")
            // A fresh storage reader proves persistence is on disk, not a Python/Swift cache.
            let reopened = PluginServiceStorage(rootDirectory: try services.serviceStorage.rootDirectory())
            try require(try reopened.getSetting(pluginId: fixtureID, key: "prefix", defaultValue: .null) == .string(prefix),
                        "new native storage reader lost the persisted value")
            report.reloadPersistence = true
            report.freshReloadInterpreter = true

            report.phase = "stop-and-finalize"
            try report.write(to: reportURL)
            try await callbacks.drain()
            await current.stop()
            try require(!current.isRunning && !observed.isProcessInitialized && current.events.subscribers.isIdle,
                        "host.stop did not finalize the real CPython process")
            try require(try stored(services, "unloads") == .integer(2), "stop omitted SDK on_plugin_unload")
            try checkFinalTrace(observed.trace)
            report.sdkLoaderAndSerializer = true
            report.finalized = true
            current.bridge.onOwnedCallback = nil
            nativeBinding.uninstall()
            report.bindingUninstalled = true
            report.nativeTrace = observed.trace
            report.callbackRequests = callbacks.snapshot.requests
            report.completedCallbacks = callbacks.snapshot.completed
            report.unexpectedEffects = services.unexpectedEffects
            report.nativeLogMessages = services.serviceLogs.entries(pluginId: fixtureID).map(\.message)
            report.sdkDTOObservation = dtoFixture.observation
            try require(report.unexpectedEffects.isEmpty, "fixture attempted a native UI/account effect: \(report.unexpectedEffects)")
            try require(report.nativeLogMessages.filter { $0 == "native fixture loaded" }.count == 2,
                        "plugin logs did not cross the native Swift dispatcher twice")
            report.phase = "complete"
            report.ok = true
            try report.write(to: reportURL)
            print("EXTERALESS_SWIFT_PLUGIN_PROBE_OK")
        } catch {
            report.ok = false
            report.error = String(describing: error)
            log("SWIFT_PLUGIN_PROBE \(report.phase): \(error)")
            if let engine { report.nativeTrace = engine.trace }
            try? report.write(to: reportURL)
            try? await callbacks.drain()
            if let host { await host.stop(); host.bridge.onOwnedCallback = nil }
            binding?.uninstall()
            report.bindingUninstalled = binding != nil
            if let engine {
                report.nativeTrace = engine.trace
                report.finalized = engine.trace.finalizations == 1 && !engine.isProcessInitialized
            }
            report.callbackRequests = callbacks.snapshot.requests
            report.completedCallbacks = callbacks.snapshot.completed
            report.unexpectedEffects = services.unexpectedEffects
            report.nativeLogMessages = services.serviceLogs.entries(pluginId: fixtureID).map(\.message)
            report.sdkDTOObservation = sdkFixture?.observation ?? .null
            try? report.write(to: reportURL)
            exit(1)
        }
    }

    private static func plugin(_ host: PluginHost) throws -> Plugin {
        guard let plugin = host.pluginList().first(where: { $0.id == fixtureID }) else {
            throw IntegrationFailure(description: "host lost the installed fixture")
        }
        return plugin
    }

    private static func checkLoaded(_ host: PluginHost) throws {
        let value = try plugin(host)
        try require(value.enabled && value.loaded && value.hasSettings && !value.notResponding && value.loadError == nil,
                    "fixture did not load: \(value.loadDebug ?? value.loadError ?? "missing loaded/hasSettings flags")")
        try require(value.handlesAppEvent && value.handlesSendMessage && !value.handlesPreRequest && !value.handlesPostRequest
            && !value.handlesUpdate && !value.handlesUpdates, "host did not apply the SDK handled-hook flags")
        let handled: Set<ExtensionPointKind> = [.appEvent, .sendMessage, .createSettings]
        for kind in ExtensionPointKind.allCases {
            let expected: Int32 = handled.contains(kind) ? 1 : 0
            try require(host.events.subscribers.subscriberCount(kind) == expected, "wrong subscriber count for \(kind)")
        }
    }

    private static func stored(_ services: NativeSDKFixtureServices, _ key: String) throws -> PluginJSONValue {
        try services.serviceStorage.getSetting(pluginId: fixtureID, key: key, defaultValue: .null)
    }

    private static func settingsRows(_ host: PluginHost) async throws -> [[String: PluginJSONValue]] {
        let json = try await host.settingsJSON(id: fixtureID, account: fixtureAccount)
        return try JSONDecoder().decode([[String: PluginJSONValue]].self, from: Data(json.utf8))
    }

    private static func string(_ value: PluginJSONValue?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private static func checkRows(_ rows: [[String: PluginJSONValue]], prefix: String, cancel: Bool) throws {
        try require(rows.map { string($0["type"]) } == ["header", "switch", "input", "text", "text"],
                    "SDK settings serializer returned missing/error/substitute rows")
        try require(rows.allSatisfy { string($0["row_id"])?.isEmpty == false }, "SDK row identities are missing")
        try require(rows[0]["text"] == .string("Native bridge") && rows[1]["key"] == .string("cancel")
            && rows[1]["value"] == .bool(cancel) && rows[2]["key"] == .string("prefix")
            && rows[2]["value"] == .string(prefix) && rows[3]["text"] == .string("Click counter"),
                    "SDK settings values differ from the native persisted state")
    }

    private static func activeTrace(_ engine: ObservedNativeEngine) throws -> InterpreterTrace {
        let matches = engine.trace.interpreters.filter { !$0.destroyed && $0.observation?.pluginId == fixtureID }
        try require(matches.count == 1, "expected one live native plugin interpreter")
        return matches[0]
    }

    private static func checkNative(_ trace: InterpreterTrace) throws {
        guard let observation = trace.observation else { throw IntegrationFailure(description: "missing native observations") }
        try require(observation.bridgeBuiltin && observation.backendInstalled && observation.transportCalls > 0
            && observation.legacyServiceCount == 0 && observation.mockCalls == 0, "plugin did not use the real C/native bridge")
        try require(observation.fixtureCalls["on_plugin_load"] == 1 && observation.sdkCalls["load_plugin"] == 1,
                    "load_json did not execute the actual SDK/plugin exactly once")
        try require(observation.problems.isEmpty && observation.profileActive && trace.errors.isEmpty,
                    "native/SDK observation failed: \(observation.problems + trace.errors)")
    }

    private static func checkFinalTrace(_ trace: NativeTrace) throws {
        try require(trace.initializations == 1 && trace.finalizations == 1 && trace.interpreters.count == 3,
                    "expected one CPython lifetime, one AST interpreter and two plugin interpreters")
        try require(trace.interpreters.allSatisfy { $0.destroyed && $0.ownGIL && $0.errors.isEmpty },
                    "an interpreter leaked or native execution failed")
        let plugins = trace.interpreters.compactMap(\.observation).filter { $0.pluginId == fixtureID }
        try require(plugins.count == 2, "missing per-load Python observations")
        for observation in plugins {
            try require(observation.profileActive && observation.problems.isEmpty && observation.loadedPlugins.isEmpty
                    && observation.handleCount == 0 && observation.callbackLeases == 0 && observation.legacyServiceCount == 0 && observation.mockCalls == 0,
                        "SDK unload did not clear owner handles/registry, or a test mock was used")
            for name in ["load_plugin", "unload_plugin"] {
                try require(observation.sdkCalls[name] == 1, "SDK \(name) did not execute once per interpreter")
            }
            try require(observation.fixtureCalls["<module>"] == 1 && observation.fixtureCalls["on_plugin_load"] == 1
                && observation.fixtureCalls["on_plugin_unload"] == 1, "fixture source/lifecycle execution counts differ")
            try require((observation.sdkCalls["get_settings_json"] ?? 0) > 0
                && (observation.sdkCalls["_serialize_setting_item"] ?? 0) >= 5, "real SDK settings serializer did not run")
        }
        let first = plugins[0]
        try require(first.sdkCalls["notify_setting_changed"] == 2 && first.sdkCalls["dispatch_setting_click"] == 1
            && first.fixtureCalls["clicked"] == 2 && first.sdkCalls["run_on_ui_thread"] == 1,
                    "settings/native runnable callbacks were not executed by the SDK")
        try require(first.sdkCalls["call_app_event"] == 1 && first.sdkCalls["call_send_message_hook"] == 2,
                    "SDK app/send dispatch counts differ (gated sends must not execute)")
        let sends = first.events.filter { $0.method == "on_send_message_hook" }
        try require(first.events.contains { $0.method == "on_app_event" && $0.event == "RESUME" }
            && sends.count == 2 && sends.allSatisfy { $0.account == fixtureAccount },
                    "SDK event/account arguments were lost")
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
