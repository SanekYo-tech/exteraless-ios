import Foundation

private struct SDKHNSFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}
private func hnsCheck(_ condition: Bool, _ message: String) throws {
    if !condition { throw SDKHNSFailure(description: message) }
}

private struct SDKHNSReport: Encodable {
    let probe = "swift-sdk-hns-remediation"
    let boundary = "Real NativeServices/Host/C/SDK lifecycle; Foundation UI DTO recorder; no UIKit/network"
    var ok = false
    var permissionRevocation = false
    var accountRevocation = false
    var terminalDelivery = false
    var settingsAccountScope = false
    var notificationRegistry = false
    var fifoReleases = false
    var nonterminalMaintenance = false
    var sdkUnload = false
    var retiringNoAdmission = false
    var storedTokenCleanup = false
    var replacementOwner = false
    var exactCleanup = false
    var idempotentRetiringCleanup = false
    var retiredOwnerSecurity = false
    var staleOwnerSecurity = false
    var nativeBridge = false
    var cleanup = false
    var initializations = 0
    var finalizations = 0
    var traces: [SDKTLTrace] = []
    var releaseIdentities: [String] = []
    var cleanupCalls: [String] = []
    var hiddenOwnerAtUnload: [Bool] = []
    var retiringDuplicateCleanups: [String] = []
    var error: String?

    func write(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum SDKHNSNativeProbe {
    static func run(_ arguments: [String]) async -> Int32 {
        let reportURL = URL(fileURLWithPath: arguments[1])
        let work = URL(fileURLWithPath: arguments[7], isDirectory: true)
        let services = NativeSDKFixtureServices(root: work.appendingPathComponent("native-storage", isDirectory: true),
            additionalAccounts: [PluginServiceAccount(index: 41, recordId: 9000, userId: 901)])
        let engine = SDKTLObservedEngine(helper: arguments[8])
        var report = SDKHNSReport()
        var host: PluginHost?
        var binding: NativeBridgeBinding?
        var provider: SDKHNSFixture?
        let hidden = SDKHNSBox<[Bool]>([])
        do {
            try report.write(reportURL)
            let plugins = try services.serviceStorage.pluginsDirectory()
            let configuration = PythonRuntimeConfiguration(programName: "exteraless-sdk-hns-probe", frameworkHome: arguments[2],
                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
                pluginRootDirectory: plugins.path, writeBytecode: false, installSignalHandlers: false,
                manifestPath: work.appendingPathComponent("manifest.json").path,
                executablePath: URL(fileURLWithPath: arguments[0]).standardizedFileURL.path)
            let current = try PluginHost(engine: engine, configuration: .init(runtime: configuration,
                interpreters: .init(maxInterpreters: 3, callTimeout: 5), storageDirectory: plugins),
                services: .init(messages: services, settings: services, ui: services))
            host = current
            let callbacks = PluginCallbackDispatcher(host: current)
            let fixture = SDKHNSFixture(callbacks: callbacks)
            provider = fixture
            current.bridge.extensionProvider = fixture
            let nativeBinding = NativeBridgeBinding(services: current.bridge)
            binding = nativeBinding; try nativeBinding.install()
            try await current.start()
            let source = URL(fileURLWithPath: arguments[6])
            var metadata = try await current.readPluginMetadata(sourceURL: source)
            metadata.enabled = false
            _ = try await current.installPlugin(sourceURL: source, metadata: metadata)
            let grants: [PluginPermission] = [.ui, .messagesRead, .network, .files]
            try current.setGrantedPermissions(id: "nativeHNSSdk", permissions: grants)
            try await current.setPluginEnabled(id: "nativeHNSSdk", true)
            guard let owner = callbacks.captureOwner("nativeHNSSdk") else { throw SDKHNSFailure(description: "HNS SDK plugin did not load") }
            let checks = try engine.checks(owner.pluginId)
            let latestOwner = SDKHNSBox(owner)
            let latestChecks = SDKHNSBox(checks)
            engine.observeSources { source in
                if source.hasPrefix("_exteraless_runtime.unload(") {
                    let retired = latestOwner.value
                    fixture.unloadingOwner.change { $0 = retired }
                    let hiddenOwner = callbacks.captureOwner(retired.pluginId) == nil
                    hidden.change { $0.append(hiddenOwner) }
                    try hnsCheck(hiddenOwner && !callbacks.callback(retired, latestChecks.value, "barrier", "[]"), "retiring owner gained callback admission")
                }
            }
            func check(_ owner: PluginHost.CallbackOwner, _ handle: Int64, _ method: String, _ arguments: String = "[]") async throws -> PluginJSONValue {
                let json = try await callbacks.result(owner, handle, method, arguments)
                return try NativeServiceWire.decode(json)
            }
            let notificationIds = try await check(owner, checks, "notifications_table")
            try hnsCheck(notificationIds == .array(NativeServiceNotification.allCases.map { .integer(Int64($0.rawValue)) }),
                "SDK discovery rejected the full actual native notification table")
            report.notificationRegistry = true
            // HNS-04: a declared native SDK slot distinct from the selected slot
            // and from its record id traverses the actual Host -> C -> SDK seam.
            let settingsAccount = try services.platformSnapshot.account(at: 41)
            let readScope = fixture.scopes.begin(recordId: settingsAccount.recordId, userId: settingsAccount.userId)
            let readPermit = SDKHNSBox(true)
            let settingsJSON = try await current.settingsJSON(id: owner.pluginId, account: settingsAccount.index,
                expectedOwner: owner, shouldExecute: {
                    readPermit.value && callbacks.captureOwner(owner.pluginId) == owner && fixture.scopes.isCurrent(readScope)
                })
            readPermit.change { $0 = false }
            fixture.scopes.end(readScope)
            let rows = try JSONDecoder().decode([[String: PluginJSONValue]].self, from: Data(settingsJSON.utf8))
            guard rows.count == 2, case let .string(clickId)? = rows[1]["callback_id"] else { throw SDKHNSFailure(description: "HNS SDK settings callback missing") }
            try await current.updateSetting(id: owner.pluginId, key: "enabled", valueJSON: "false", expectedOwner: owner,
                account: 41, shouldExecute: { callbacks.captureOwner(owner.pluginId) == owner })
            try await current.clickSetting(id: owner.pluginId, callbackId: clickId, expectedOwner: owner,
                account: 41, shouldExecute: { callbacks.captureOwner(owner.pluginId) == owner })
            try hnsCheck(try services.serviceStorage.getSetting(pluginId: owner.pluginId, key: "enabled", defaultValue: .null) == .bool(false)
                && services.serviceStorage.getSetting(pluginId: owner.pluginId, key: "change_account", defaultValue: .null) == .integer(41)
                && services.serviceStorage.getSetting(pluginId: owner.pluginId, key: "click_account", defaultValue: .null) == .integer(41), "settings action lost its captured SDK account slot")
            report.settingsAccountScope = true
            func cleanupJSON(_ member: String, id: String, token: String) throws -> String {
                try NativeServiceWire.json(.object(["op": .string("call"), "fqcn": .string("exteraless.ios.Runtime"),
                    "member": .string(member), "args": .array([.string(id)]), "kwargs": .object([:]), "ownerToken": .string(token)]))
            }
            func requireSecurityDenial(_ reply: PluginJSONValue) throws {
                guard case let .object(envelope) = reply, envelope["ok"] == .bool(false),
                      case let .object(error)? = envelope["error"], error["kind"] == .string("SecurityError") else {
                    throw SDKHNSFailure(description: "Retired C owner must receive typed SecurityError before the provider")
                }
            }
            func releaseHandles(_ source: String) throws -> [Int64] {
                let prefix = "_exteraless_runtime.release_handles_json("
                guard source.hasPrefix(prefix) else { return [] }
                let arguments = "[" + String(source.dropFirst(prefix.count).dropLast()) + "]"
                let strings = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                return try JSONDecoder().decode([Int64].self, from: Data(strings[0].utf8))
            }
            func verifyWorker(_ handles: [Int64], positive: Bool) throws {
                guard let trace = engine.snapshot.records.first(where: { !$0.destroyed && $0.checks?.pluginId == owner.pluginId }) else {
                    throw SDKHNSFailure(description: "missing real HNS interpreter trace")
                }
                for handle in handles {
                    let invokes = trace.sources.indices.filter { trace.sources[$0].hasPrefix("_exteraless_runtime.invoke_handle_json(\(handle),") }
                    let releases = try trace.sources.indices.filter { try releaseHandles(trace.sources[$0]).contains(handle) }
                    try hnsCheck(invokes.count == (positive ? 1 : 0) && releases.count == 1, "revoked callback entered Python or C release was not exactly once")
                    if positive { try hnsCheck(invokes[0] < releases[0], "terminal release overtook Python callback") }
                }
            }
            func delivery(accountSwap: Bool, positive: Bool) async throws {
                try current.setGrantedPermissions(id: owner.pluginId, permissions: grants)
                guard case let .object(description) = try await check(owner, checks, "callbacks", positive ? "[true]" : "[false]"),
                      case let .array(rawIds)? = description["ids"], case let .array(rawHandles)? = description["handles"] else {
                    throw SDKHNSFailure(description: "SDK callback setup returned no native ids")
                }
                let ids = try rawIds.map { try NativeServiceWire.string($0, name: "id") }
                let handles = try rawHandles.map { try NativeServiceWire.integer($0, name: "handle", range: 1...Int64.max) }
                let gate = SDKHNSWorkerGate()
                fixture.workerGate.change { $0 = gate }
                defer { gate.open(); fixture.workerGate.change { $0 = nil } }
                // Direct Host invocation occupies the actual interpreter worker;
                // the NativeServices dispatcher remains free to admit callbacks.
                let blocker = Task { try await current.invokeCallback(id: owner.pluginId, handle: checks, method: "block", expectedOwner: owner) }
                try await withDispatchTimeout(2) { try await gate.entered.awaitValue() }
                let persistent = try fixture.emitCallbacks(ids)
                if !positive {
                    if accountSwap { _ = fixture.scopes.begin(recordId: fixture.accountRecordId, userId: 101) }
                    else { try current.setGrantedPermissions(id: owner.pluginId, permissions: [.ui]) }
                }
                gate.open()
                try await withDispatchTimeout(2) { try await blocker.value }
                _ = try await check(owner, checks, "barrier")
                // Leave the persistent lease alive until its worker predicate ran:
                // cancellation is not being used to imitate account/grant rejection.
                for id in persistent {
                    let json = try cleanupJSON("nativeServiceCancel", id: id, token: owner.wireToken)
                    let reply = try NativeServiceWire.decode(current.bridge.dispatchJSON(json, pluginId: owner.pluginId))
                    try hnsCheck(reply == .object(["ok": .bool(true), "value": .bool(true)]), "native persistent cleanup failed")
                }
                try hnsCheck(try await check(owner, checks, "after_callbacks", positive ? "[[\"user\"]]" : "[[]]") == .bool(true), "HNS SDK body/handle check failed")
                try verifyWorker(handles, positive: positive)
                try hnsCheck(fixture.pool.count == 0 && fixture.operations.count == 0, "HNS callback native lease survived FIFO release")
            }
            try await delivery(accountSwap: false, positive: false)
            report.permissionRevocation = true
            try await delivery(accountSwap: true, positive: false)
            report.accountRevocation = true
            try await delivery(accountSwap: false, positive: true)
            report.terminalDelivery = true; report.fifoReleases = true
            try current.setGrantedPermissions(id: owner.pluginId, permissions: grants)

            guard case let .object(firstResources) = try await check(owner, checks, "pending") else { throw SDKHNSFailure(description: "SDK long leases missing") }
            try hnsCheck(fixture.scheduler.pendingCount == 1 && fixture.operations.count == 2 && fixture.liveUI == 1, "native long task/observer/UI leases missing")
            guard case let .array(rawFirstHandles)? = firstResources["handles"] else { throw SDKHNSFailure(description: "missing SDK persistent handles") }
            let firstHandles = try rawFirstHandles.map { try NativeServiceWire.integer($0, name: "handle") }
            try hnsCheck(firstHandles.count == 12, "unexpected SDK persistent callback count")
            let maintenance = try await current.beginSettingsMaintenance(timeout: 5)
            try hnsCheck(engine.isProcessInitialized && engine.snapshot.initializations == 1 && engine.snapshot.finalizations == 0,
                "settings maintenance finalized/reinitialized CPython")
            try hnsCheck(fixture.scheduler.pendingCount == 0 && fixture.operations.count == 0 && fixture.pool.count == 0 && fixture.liveUI == 0 && fixture.residualSweeps.value == 0,
                "real CallbackLeases.end did not clean all native resources")
            try hnsCheck(try services.serviceStorage.getSetting(pluginId: owner.pluginId, key: "unloads", defaultValue: .null) == .integer(1)
                && services.serviceStorage.getSetting(pluginId: owner.pluginId, key: "retiring_admission_rejected", defaultValue: .null) == .bool(true), "real SDK unload did not finish")
            try hnsCheck(fixture.retiringDuplicates.value.count == 4, "Retiring SDK cleanup did not exercise idempotent production-route removal")
            report.idempotentRetiringCleanup = true
            let cleanupMembers = [("task", "cancelOwnerTask"), ("observer", "nativeServiceCancel"), ("notification", "notificationUnsubscribe"), ("ui", "uiDismiss")]
            let cleanupCount = fixture.cleanups.value.count
            let releaseCount = fixture.released.value.count
            for (key, member) in cleanupMembers {
                let id = try NativeServiceWire.string(firstResources[key], name: key)
                let json = try cleanupJSON(member, id: id, token: owner.wireToken)
                let reply = try NativeServiceWire.decode(current.bridge.dispatchJSON(json, pluginId: owner.pluginId))
                try requireSecurityDenial(reply)
            }
            try hnsCheck(fixture.cleanups.value.count == cleanupCount && fixture.released.value.count == releaseCount,
                "Destroyed-owner denial reached the provider or released a second handle")
            report.retiredOwnerSecurity = true
            report.nonterminalMaintenance = true; report.sdkUnload = true; report.storedTokenCleanup = true
            fixture.unloadingOwner.change { $0 = nil }
            try await maintenance.finish(resume: true)
            guard let replacement = callbacks.captureOwner(owner.pluginId), replacement != owner, replacement.wireToken != owner.wireToken else {
                throw SDKHNSFailure(description: "maintenance reused an old C epoch")
            }
            latestOwner.change { $0 = replacement }
            let nextChecks = try engine.checks(replacement.pluginId)
            latestChecks.change { $0 = nextChecks }
            guard case let .object(nextResources) = try await check(replacement, nextChecks, "pending") else { throw SDKHNSFailure(description: "replacement SDK leases missing") }
            // Native replay of an old captured C token against the replacement id.
            // The replacement interpreter cannot author that token through C.
            for (key, member) in cleanupMembers {
                let id = try NativeServiceWire.string(nextResources[key], name: key)
                let json = try cleanupJSON(member, id: id, token: owner.wireToken)
                let reply = try NativeServiceWire.decode(current.bridge.dispatchJSON(json, pluginId: owner.pluginId))
                try requireSecurityDenial(reply)
            }
            try hnsCheck(fixture.scheduler.pendingCount == 1 && fixture.operations.count == 2 && fixture.liveUI == 1
                && fixture.cleanups.value.count == cleanupCount && fixture.released.value.count == releaseCount,
                "old token reached the replacement provider or changed its leases")
            report.staleOwnerSecurity = true
            report.replacementOwner = true
            await current.stop(); nativeBinding.uninstall()
            let snapshot = engine.snapshot
            report.initializations = snapshot.initializations; report.finalizations = snapshot.finalizations; report.traces = snapshot.records
            report.releaseIdentities = fixture.released.value; report.cleanupCalls = fixture.cleanups.value
            report.hiddenOwnerAtUnload = hidden.value
            report.retiringDuplicateCleanups = fixture.retiringDuplicates.value
            try hnsCheck(hidden.value == [true, true], "SDK unload ran with an active owner")
            try hnsCheck(fixture.retiringDuplicates.value.count == 8, "Both retiring epochs must verify duplicate cleanup without a second release")
            report.retiringNoAdmission = true
            let observations = snapshot.records.compactMap(\.observation).filter { $0.pluginId == owner.pluginId }
            try hnsCheck(snapshot.records.count == 3 && observations.count == 2 && snapshot.initializations == 1 && snapshot.finalizations == 1,
                "HNS native interpreter/process lifetime changed")
            try hnsCheck(observations.allSatisfy { $0.bridgeBuiltin && $0.backendInstalled && $0.mockCalls == 0 && $0.legacyServiceCount == 0 }, "HNS used a substituted C backend")
            report.nativeBridge = true
            try hnsCheck(fixture.released.value.count == 31 && Set(fixture.released.value).count == 31,
                "native cleanup/release was not exactly once per owner/handle")
            report.exactCleanup = true
            try hnsCheck(observations.allSatisfy { $0.handleCount == 0 && $0.callbackLeases == 0 && $0.loadedPlugins.isEmpty }
                && snapshot.records.allSatisfy { $0.destroyed && $0.ownGIL } && fixture.residualSweeps.value == 0
                && fixture.pool.count == 0 && fixture.liveUI == 0 && services.unexpectedEffects.isEmpty, "HNS native SDK cleanup failed")
            report.cleanup = true; report.ok = true
            try report.write(reportURL)
            print("EXTERALESS_SWIFT_SDK_HNS_PROBE_OK")
            return 0
        } catch {
            provider?.workerGate.value?.open()
            if let host { await host.stop() }
            binding?.uninstall()
            let snapshot = engine.snapshot
            report.traces = snapshot.records; report.initializations = snapshot.initializations; report.finalizations = snapshot.finalizations
            report.releaseIdentities = provider?.released.value ?? []; report.cleanupCalls = provider?.cleanups.value ?? []
            report.hiddenOwnerAtUnload = hidden.value; report.error = String(describing: error)
            report.retiringDuplicateCleanups = provider?.retiringDuplicates.value ?? []
            try? report.write(reportURL)
            return 1
        }
    }
}
