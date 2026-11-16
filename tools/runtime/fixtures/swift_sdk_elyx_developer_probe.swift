import Foundation
import Darwin

private struct ElyxDeveloperProbeFailure: Error, CustomStringConvertible, Sendable { let description: String }
private func elyxProbeCheck(_ value: Bool, _ message: String) throws {
    if !value { throw ElyxDeveloperProbeFailure(description: message) }
}
private func elyxProbeThread() -> UInt64 { var value: UInt64 = 0; pthread_threadid_np(nil, &value); return value }

/// Forwarding instrumentation only. Every production script runs unchanged in
/// CPythonXCFrameworkEngine. Negative readiness tests remove a real attribute in
/// their own fresh metadata interpreter, never substitute a gate/reader result.
private final class ElyxDeveloperNativeEngine: CPythonEngine, @unchecked Sendable {
    enum Refusal: Sendable { case gate, hook, abi }
    struct Record: Encodable, Sendable {
        let reference: Int64
        let thread: UInt64
        let ownGIL: Bool
        let allowThreads: Bool
        var helper = false
        var destroyed = false
        var pluginId: String?
        var handle: Int64?
        var scripts: [String] = []
        var observation: [String: PluginJSONValue]?
        var observationError: String?
    }
    private let engine = CPythonXCFrameworkEngine()
    private let helper: String
    private let lock = NSLock()
    private var records: [Int64: Record] = [:]
    private var initializations = 0, finalizations = 0
    private var refusal: Refusal?
    private var lastLoadProof: String?
    init(helper: String) { self.helper = helper }
    var apiVersion: String { engine.apiVersion }
    var isProcessInitialized: Bool { engine.isProcessInitialized }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        try engine.initializeProcess(configuration: configuration)
        lock.lock(); initializations += 1; lock.unlock()
    }
    func finalizeProcess() throws { try engine.finalizeProcess(); lock.lock(); finalizations += 1; lock.unlock() }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        try elyxProbeCheck(configuration.ownsGIL && !configuration.useMainObmalloc && configuration.checkMultiInterpExtensions
            && !configuration.allowDaemonThreads && !Thread.isMainThread, "fifth child lost actual OWN_GIL/non-daemon native worker policy")
        let reference = try engine.createInterpreter(configuration)
        lock.lock()
        records[reference.raw] = Record(reference: reference.raw, thread: elyxProbeThread(), ownGIL: configuration.ownsGIL,
                                        allowThreads: configuration.allowThreads)
        lock.unlock()
        return reference
    }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        lock.lock(); let before = records[reference.raw]; lock.unlock()
        guard let before else { throw ElyxDeveloperProbeFailure(description: "unrecorded native worker") }
        try elyxProbeCheck(!Thread.isMainThread && before.thread == elyxProbeThread(), "fifth child script left its native owner")
        if Self.tag(source) == "metadata-bootstrap" { try elyxProbeCheck(!before.allowThreads, "trusted inspector allowed Python threads") }
        if !before.helper {
            _ = try engine.runScript(reference, "import importlib.util as _ep_import\n_ep_spec = _ep_import.spec_from_file_location('_native_elyx_developer_probe', \(PluginRuntimeScript.quote(helper)))\n_native_elyx_developer_probe = _ep_import.module_from_spec(_ep_spec)\n_ep_spec.loader.exec_module(_native_elyx_developer_probe)\n")
            lock.lock(); records[reference.raw]?.helper = true; lock.unlock()
        }
        lock.lock(); records[reference.raw]?.scripts.append(Self.tag(source)); lock.unlock()
        if source.contains("_elyx_readiness"), source.contains(".probe_json(") {
            lock.lock(); let refusal = self.refusal; self.refusal = nil; lock.unlock()
            if let refusal {
                try elyxProbeCheck(before.scripts == ["metadata-bootstrap"], "readiness negative escaped the fresh inspector")
                let mutation: String
                switch refusal {
                case .gate: mutation = "import _exteraless_bridge\ndel _exteraless_bridge.xt_elyx_source"
                case .hook: mutation = "del _exteraless_runtime._archives.verified_developer_load"
                case .abi: mutation = "_exteraless_runtime._archives.SOURCE_ABI = 'owned-incompatible-abi'"
                }
                _ = try engine.runScript(reference, mutation)
            }
        }
        let output = try engine.runScript(reference, source)
        let ordinary = "_exteraless_runtime.load_json("
        let verified = "_exteraless_runtime._elyx_developer.load_verified_json("
        if source.hasPrefix(ordinary) || source.hasPrefix(verified) {
            let identity = try JSONDecoder().decode(SDKTLCheckIdentity.self,
                from: Data(engine.runScript(reference, "_native_elyx_developer_probe.loaded()").utf8))
            lock.lock(); records[reference.raw]?.pluginId = identity.pluginId; records[reference.raw]?.handle = identity.handle; lock.unlock()
            if source.hasPrefix(verified) {
                let arguments = "[" + source.dropFirst(verified.count).dropLast() + "]"
                let values = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                lock.lock(); lastLoadProof = values[1]; lock.unlock()
            }
        }
        return output
    }
    func destroyInterpreter(_ reference: InterpRef) throws {
        lock.lock(); let record = records[reference.raw]; lock.unlock()
        try elyxProbeCheck(record?.thread == elyxProbeThread() && !Thread.isMainThread, "fifth child destruction left owner thread")
        var observation: [String: PluginJSONValue]?
        var observationError: String?
        do {
            let output = try engine.runScript(reference, "_native_elyx_developer_probe.observation()")
            observation = try JSONDecoder().decode([String: PluginJSONValue].self, from: Data(output.utf8))
        } catch { observationError = PluginElyxDeveloperOperationFailure.publicMessage(String(describing: error)) }
        try engine.destroyInterpreter(reference)
        lock.lock()
        records[reference.raw]?.observation = observation; records[reference.raw]?.observationError = observationError
        records[reference.raw]?.destroyed = true
        lock.unlock()
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { engine.interpreterFootprintKB(reference) }
    func refuseNext(_ value: Refusal) { lock.lock(); refusal = value; lock.unlock() }
    func handle(_ id: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let value = records.values.first(where: { !$0.destroyed && $0.pluginId == id })?.handle else { throw ElyxDeveloperProbeFailure(description: "missing own native observer handle") }
        return value
    }
    var proof: String? { lock.lock(); defer { lock.unlock() }; return lastLoadProof }
    var snapshot: (initialized: Int, finalized: Int, records: [Record]) {
        lock.lock(); defer { lock.unlock() }; return (initializations, finalizations, records.values.sorted { $0.reference < $1.reference })
    }
    private static func tag(_ source: String) -> String {
        if source.contains("_exteraless_runtime.configure(") { return "owner-bootstrap" }
        if source.hasPrefix("import sys\n") { return "metadata-bootstrap" }
        if source.contains("_elyx_readiness"), source.contains(".probe_json(") { return "readiness" }
        if source.contains(".inspect_fd_json(") { return "fd-inspection" }
        if source.hasPrefix("_exteraless_bridge.xt_set_owner_token(") { return "bind-owner" }
        for name in ["load_json", "metadata_json", "unload", "invoke_handle_json", "_elyx_developer.load_verified_json", "_elyx_developer.manifest_json"] {
            if source.hasPrefix("_exteraless_runtime." + name + "(") { return name }
        }
        return "host-call"
    }
}

private struct ElyxDeveloperProbeReport: Encodable {
    let probe = "swift-sdk-elyx-developer"
    let boundary = "Real public Host activation/FD registry/C/CPython Elyx SDK; owned local fixtures; no UIKit/network"
    var ok = false
    var phase = "initializing"
    var actualReadiness = false, missingReadinessRejected = false, verifiedInspection = false
    var nativeChangesPersisted = false, newOwnerVerifiedLoad = false, cleanCompare = false
    var staleOwnerSessionEpochRejected = false, oldCapabilityRejected = false, cleanup = false
    var loadPolicyRefusedBeforeRetirement = false, zeroOldRetirement = false, consentPreserved = false
    var staleSourceRejected = false
    var initializations = 0, finalizations = 0
    var gateOperations: [String: Int] = [:]
    var gateBytes = 0
    var sourceReceipts = -1, stages = -1, readTickets = -1, capabilities = -1, fileAuthorities = -1
    var snapshots: [String: PluginJSONValue] = [:]
    var refusals: [String: PluginJSONValue] = [:]
    var unexpectedEffects: [String] = []
    var traces: [ElyxDeveloperNativeEngine.Record] = []
    var error: String?
    func write(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try elyxProbeCheck(data.count < 32768, "fifth-child report exceeded 32 KiB")
        try data.write(to: url, options: .atomic)
    }
}

/// Fifth child of the existing compiled executable; delegate before helper
/// startup. Uses the SAME public Host activation API as ProductionRuntime.
enum SDKElyxDeveloperNativeProbe {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 10 else { return 2 }
        let reportURL = URL(fileURLWithPath: arguments[1])
        let work = URL(fileURLWithPath: arguments[7], isDirectory: true)
        let input = URL(fileURLWithPath: arguments[6], isDirectory: true)
        let engine = ElyxDeveloperNativeEngine(helper: arguments[8])
        let services = NativeSDKFixtureServices(root: work.appendingPathComponent("native-storage", isDirectory: true))
        var report = ElyxDeveloperProbeReport()
        var host: PluginHost?
        var binding: NativeBridgeBinding?
        var active: PluginElyxDeveloperService?
        let scope = PluginElyxDeveloperActivationScope()
        do {
            try report.write(reportURL)
            let plugins = try services.serviceStorage.pluginsDirectory()
            let configuration = PythonRuntimeConfiguration(programName: "exteraless-native-elyx-developer-probe", frameworkHome: arguments[2],
                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
                pluginRootDirectory: plugins.path, writeBytecode: false, installSignalHandlers: false,
                manifestPath: work.appendingPathComponent("manifest.json").path, executablePath: arguments[0])
            let current = try PluginHost(engine: engine, configuration: .init(runtime: configuration,
                interpreters: .init(maxInterpreters: 4, callTimeout: 5), storageDirectory: services.serviceStorage.rootDirectory()),
                services: .init(messages: services, settings: services, ui: services))
            host = current
            let nativeBinding = NativeBridgeBinding(services: current.bridge); binding = nativeBinding
            try nativeBinding.install()
            try await current.start(safeMode: true)
            try elyxProbeCheck(engine.apiVersion.hasPrefix("3.12.") && engine.snapshot.initialized == 1,
                               "fifth child did not start the real CPython 3.12 exactly once")

            report.phase = "actual-readiness-and-retry"
            for (mode, message) in [(ElyxDeveloperNativeEngine.Refusal.gate, "built-in gate"), (.hook, "missing archive hooks"), (.abi, "SOURCE_ABI mismatch")] {
                engine.refuseNext(mode)
                var failure: String?
                do {
                    _ = try await current.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
                } catch { failure = String(describing: error) }
                try elyxProbeCheck(failure?.contains(message) == true, "readiness accepted absent gate/hook/ABI or returned the wrong refusal")
            }
            report.missingReadinessRejected = true
            let service = try await current.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
            active = service
            var files: PluginElyxDeveloperFiles? = try service.fileAuthority()
            try elyxProbeCheck(service.readyReceipt != nil && service.probeAttempts == 4 && service.registry.metrics.challengesObserved == 1,
                               "public activation did not use its fresh native/C challenge")
            report.actualReadiness = true

            report.phase = "install-enable-captured-source"
            let id = "native_elyx_dev"
            let archive = input.appendingPathComponent("owned.elyx")
            var metadata = try await current.readPluginMetadata(sourceURL: archive)
            metadata.enabled = false
            let installed = try await current.installPlugin(sourceURL: archive, metadata: metadata,
                selection: PluginPermissionRecord(level: .isolated, grants: []))
            try elyxProbeCheck(!installed.loaded && installed.fileFormat == .elyx, "disabled native archive install executed code")
            try elyxProbeCheck(try services.serviceStorage.getSetting(pluginId: id, key: "loads", defaultValue: .null) == .null,
                               "data-only inspection or disabled install executed the archive")
            try await current.setPluginEnabled(id: id, true)
            guard let firstOwner = current.callbackOwner(id: id), let path = installed.path else { throw ElyxDeveloperProbeFailure(description: "own archive did not load") }
            func snapshot(_ owner: PluginHost.CallbackOwner, _ label: String) async throws -> [String: PluginJSONValue] {
                let output = try await current.invokeCallbackResult(id: id, handle: engine.handle(id), method: "snapshot",
                    argumentsJSON: PluginRuntimeScript.encodeJSON([label]), expectedOwner: owner)
                return try JSONDecoder().decode([String: PluginJSONValue].self, from: Data(output.utf8))
            }
            let first = try await snapshot(firstOwner, "first")
            try elyxProbeCheck(first["owner"] == .string(firstOwner.wireToken) && first["class_name"] == .string("NativeElyxDeveloperProbe"),
                               "initial Python snapshot differs from the real native owner/entry")
            report.snapshots["first"] = .object(first)
            let compare = try PluginElyxDeveloperRequest(json: String(contentsOf: input.appendingPathComponent("compare-next.json"), encoding: .utf8))
            let change = try PluginElyxDeveloperRequest(json: String(contentsOf: input.appendingPathComponent("changes.json"), encoding: .utf8))
            let oldTargets = try current.elyxDeveloperTargets(change) // before any command await
            let before = try await current.elyxDeveloper(compare, targets: current.elyxDeveloperTargets(compare), account: 2, files: files,
                deadline: ProcessInfo.processInfo.systemUptime + 10, shouldExecute: { scope.isCurrent })
            try elyxProbeCheck(before["created_or_modified"] == .array([.string("assets/value.txt"), .string("helpers.py"), .string("main.py"),
                .string("meta.json"), .string("wheels/elyxprobe-1.0-py3-none-any.whl")]), "verified native manifest compared the wrong source")
            let oldBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let originalConsent = current.permissionSnapshot(id: id)

            func response(_ command: PluginElyxDeveloperRequest, targets: [PluginElyxDeveloperTarget],
                          files: PluginElyxDeveloperFiles?,
                          allowed: @escaping @Sendable () -> Bool) async -> [String: PluginJSONValue] {
                do {
                    return try await current.elyxDeveloper(command, targets: targets, account: 2, files: files,
                        deadline: ProcessInfo.processInfo.systemUptime + 10, shouldExecute: allowed)
                } catch { return PluginElyxDeveloperError.response(error, request: command) }
            }
            func stored(_ key: String) throws -> PluginJSONValue {
                try services.serviceStorage.getSetting(pluginId: id, key: key, defaultValue: .null)
            }

            report.phase = "actual-fd-load-policy-refusal-before-retirement"
            for (name, message) in [("requires", "cross-owner module provider"), ("python", "requires Python >=99")] {
                let command = try PluginElyxDeveloperRequest(json: String(contentsOf: input.appendingPathComponent("reject-" + name + ".json"), encoding: .utf8))
                let captured = try current.elyxDeveloperTargets(command)
                let observed = service.registry.metrics
                let loaderCalls = engine.snapshot.records.flatMap(\.scripts).filter { $0 == "load_json" || $0 == "_elyx_developer.load_verified_json" }.count
                let refusal = await response(command, targets: captured, files: files, allowed: { scope.isCurrent })
                try elyxProbeCheck(refusal["ok"] == .bool(false) && refusal["reloaded"] == .bool(false)
                    && refusal["publication_outcome"] == .string("refused") && refusal["source_changed"] == .bool(false),
                    "known unsupported candidate was not refused before publication")
                guard case let .string(error)? = refusal["error"] else { throw ElyxDeveloperProbeFailure(description: "load-policy refusal omitted its error") }
                try elyxProbeCheck(error.contains(message), "candidate failed outside the actual known-load-policy preflight")
                let after = service.registry.metrics
                try elyxProbeCheck((after.operations["claim"] ?? 0) > (observed.operations["claim"] ?? 0) && after.bytesRead > observed.bytesRead,
                                   "load-policy refusal bypassed actual native FD inspection")
                try elyxProbeCheck(current.callbackOwner(id: id) == firstOwner
                    && current.pluginList().contains(where: { captured[0].matches($0) })
                    && current.permissionSnapshot(id: id) == originalConsent
                    && (try Data(contentsOf: URL(fileURLWithPath: path))) == oldBytes,
                    "unsupported candidate changed source, model, consent or old owner")
                try elyxProbeCheck(try stored("loads") == .integer(1) && stored("unloads") == .null,
                                   "unsupported candidate retired the old SDK generation")
                try elyxProbeCheck(engine.snapshot.records.flatMap(\.scripts).filter { $0 == "load_json" || $0 == "_elyx_developer.load_verified_json" }.count == loaderCalls,
                                   "unsupported candidate reached a new loader entry")
                try elyxProbeCheck(after.capabilities == 0 && after.readTickets == 0 && after.sourceReceipts == 0
                    && service.fileActivity.sources == 0 && service.fileActivity.stages == 0, "refused candidate leaked native custody")
                report.refusals[name] = .object(refusal)
            }
            report.loadPolicyRefusedBeforeRetirement = true
            report.zeroOldRetirement = true

            report.phase = "native-fd-inspect-publish-verified-load"
            let result = try await current.elyxDeveloper(change, targets: oldTargets, account: 2, files: files,
                deadline: ProcessInfo.processInfo.systemUptime + 10, shouldExecute: { scope.isCurrent })
            try elyxProbeCheck(result["ok"] == .bool(true) && result["reloaded"] == .bool(true), "native FD changes failed: \(result)")
            try elyxProbeCheck(result["publication_outcome"] == .string("committed") && result["source_changed"] == .bool(true),
                               "native success omitted its actual publication outcome")
            guard let nextOwner = current.callbackOwner(id: id), nextOwner != firstOwner else { throw ElyxDeveloperProbeFailure(description: "changes reused the old native owner") }
            let next = try await snapshot(nextOwner, "next")
            report.snapshots["next"] = .object(next)
            try elyxProbeCheck(next["digest"] != first["digest"] && next["helper"] != first["helper"] && next["wheel"] != first["wheel"], "code/same-filename wheel reused the old image")
            try elyxProbeCheck(next["owner"] == .string(nextOwner.wireToken) && next["class_name"] == .string("NativeElyxDeveloperProbeNext")
                && next["seen"] == .array([.string("next"), .string("asset-next"), .string("wheel-next")]), "changed entry/helper/asset/wheel was not executed")
            if case let .string(directory)? = first["extract"] { try elyxProbeCheck(!FileManager.default.fileExists(atPath: directory), "old extraction survived native reload") }
            let newBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try elyxProbeCheck(newBytes != oldBytes && current.pluginList().first(where: { $0.id == id })?.path == path, "changes did not persist native archive bytes/path")
            report.nativeChangesPersisted = true
            report.newOwnerVerifiedLoad = engine.proof != nil
            try elyxProbeCheck(current.permissionSnapshot(id: id) == originalConsent
                && !current.permissionSnapshot(id: id).effective.contains(.network), "candidate metadata granted unselected native consent")
            try elyxProbeCheck(current.pluginList().first(where: { $0.id == id })?.version == "2.0"
                && (try stored("loads")) == .integer(2) && (try stored("unloads")) == .integer(1), "actual model or reload lifecycle differs")
            report.consentPreserved = true
            let after = try await current.elyxDeveloper(compare, targets: current.elyxDeveloperTargets(compare), account: 2, files: files,
                deadline: ProcessInfo.processInfo.systemUptime + 10, shouldExecute: { scope.isCurrent })
            try elyxProbeCheck(after["created_or_modified"] == .array([]) && after["deleted"] == .array([]), "post-reload native source comparison is not clean")
            report.cleanCompare = true
            let metrics = service.registry.metrics
            for name in ["claim", "manifest", "read", "check", "release"] {
                try elyxProbeCheck((metrics.operations[name] ?? 0) > 0, "real native registry did not observe \(name)")
            }
            report.verifiedInspection = metrics.bytesRead > 0

            report.phase = "stale-owner-session-epoch-and-capability"
            let staleOwner = await response(change, targets: oldTargets, files: files, allowed: { scope.isCurrent })
            try elyxProbeCheck(staleOwner["ok"] == .bool(false) && staleOwner["source_changed"] == .bool(false)
                && staleOwner["publication_outcome"] == .string("refused") && current.callbackOwner(id: id) == nextOwner, "stale owner was accepted")
            let cancelled = PluginElyxDeveloperActivationScope()
            let freshTargets = try current.elyxDeveloperTargets(change)
            cancelled.invalidate()
            let sessionRefusal = await response(change, targets: freshTargets, files: files, allowed: { cancelled.isCurrent })
            try elyxProbeCheck(sessionRefusal["ok"] == .bool(false) && sessionRefusal["source_changed"] == .bool(false)
                && current.callbackOwner(id: id) == nextOwner, "retired native session was accepted")
            guard let proof = engine.proof else { throw ElyxDeveloperProbeFailure(description: "verified-load Host script did not carry a native descriptor") }
            let replay = try await current.invokeCallbackResult(id: id, handle: engine.handle(id), method: "replay",
                argumentsJSON: PluginRuntimeScript.encodeJSON([proof]), expectedOwner: nextOwner)
            guard case let .object(replayed) = try NativeServiceWire.decode(replay) else { throw ElyxDeveloperProbeFailure(description: "capability replay returned no structured observation") }
            try elyxProbeCheck(replayed["rejected"] == .bool(true), "old capability replay was not rejected through C")
            report.oldCapabilityRejected = true

            var staleSource: (any PluginElyxDeveloperSource)? = try files?.open(freshTargets[0])
            try newBytes.write(to: URL(fileURLWithPath: path), options: .atomic)
            var sourceRejected = false
            do { try staleSource?.checkCurrent() } catch { sourceRejected = true }
            withExtendedLifetime(staleSource) {}; staleSource = nil
            try elyxProbeCheck(sourceRejected, "same-byte replacement revived a captured native source")
            report.staleSourceRejected = true
            guard let dispatcher = current.bridge.elyxSourceDispatcher else { throw ElyxDeveloperProbeFailure(description: "public activation did not install a dispatcher") }
            current.bridge.elyxSourceDispatcher = nil
            current.bridge.elyxSourceDispatcher = dispatcher
            var epochRejected = false
            do { _ = try files?.open(freshTargets[0]) } catch { epochRejected = true }
            try elyxProbeCheck(epochRejected && !service.isActive, "dispatcher ABA revived old readiness/provider")
            scope.invalidate()
            current.deactivateElyxDeveloper(scope: scope.id)
            files = nil
            try elyxProbeCheck(try Data(contentsOf: URL(fileURLWithPath: path)) == newBytes, "refusal changed installed archive bytes")
            let replacementScope = PluginElyxDeveloperActivationScope()
            let replacement = try await current.activateElyxDeveloper(scope: replacementScope.id, isCurrent: { replacementScope.isCurrent })
            active = replacement
            try elyxProbeCheck(replacement.registry.identifier != service.registry.identifier && replacement.readyReceipt != nil, "replacement activation reused registry readiness")
            let replacementEpoch = current.bridge.elyxSourceDispatcherBindingEpoch
            var scopeRejected = false
            do { _ = try await current.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent }) } catch { scopeRejected = true }
            service.invalidate(); current.deactivateElyxDeveloper(scope: scope.id)
            try elyxProbeCheck(scopeRejected && replacement.isActive && current.bridge.elyxSourceDispatcherBindingEpoch == replacementEpoch,
                               "obsolete activation replaced/removed the new installed registry")
            report.staleOwnerSessionEpochRejected = true
            report.gateOperations = service.registry.metrics.operations
            report.gateBytes = service.registry.metrics.bytesRead

            report.phase = "cleanup"
            try await current.uninstallPlugin(id: id)
            replacementScope.invalidate(); current.deactivateElyxDeveloper()
            await current.stop(); nativeBinding.uninstall()
            let oldMetrics = service.registry.metrics, newMetrics = replacement.registry.metrics
            report.sourceReceipts = oldMetrics.sourceReceipts + newMetrics.sourceReceipts
            report.readTickets = oldMetrics.readTickets + newMetrics.readTickets
            report.capabilities = oldMetrics.capabilities + newMetrics.capabilities
            report.stages = service.fileActivity.stages + replacement.fileActivity.stages
            report.fileAuthorities = service.fileAuthorityCount + replacement.fileAuthorityCount
            let trace = engine.snapshot
            report.initializations = trace.initialized; report.finalizations = trace.finalized; report.traces = trace.records
            report.unexpectedEffects = services.unexpectedEffects
            try elyxProbeCheck(trace.initialized == 1 && trace.finalized == 1 && services.unexpectedEffects.isEmpty, "fifth child changed global CPython lifecycle or performed an external effect")
            try elyxProbeCheck(report.sourceReceipts == 0 && report.readTickets == 0 && report.capabilities == 0 && report.stages == 0
                && report.fileAuthorities == 0 && service.fileActivity.sources == 0 && replacement.fileActivity.sources == 0,
                "native provider/ticket/source/stage cleanup is not empty")
            try elyxProbeCheck(trace.records.count == 12 && trace.records.allSatisfy { $0.destroyed && $0.ownGIL && $0.observationError == nil
                && $0.observation?["handles"] == .integer(0) && $0.observation?["builtin"] == .bool(true)
                && $0.observation?["legacy_services"] == .integer(0) && $0.observation?["mock_calls"] == .integer(0)
                && $0.observation?["leases"] == .integer(0) && $0.observation?["plugins"] == .array([]) && $0.observation?["network"] == .array([]) }, "native worker/SDK cleanup is incomplete")
            let owners = trace.records.filter { $0.pluginId == id }
            try elyxProbeCheck(owners.count == 2 && owners.allSatisfy { $0.observation?["entry_calls"] == .integer(1)
                && $0.observation?["load_calls"] == .integer(1) && $0.observation?["unload_calls"] == .integer(1)
                && $0.observation?["backend_installed"] == .bool(true) }, "native load/unload/entry counts are not exact")
            for record in trace.records where record.pluginId == nil {
                try elyxProbeCheck(record.observation?["entry_calls"] == .integer(0) && record.observation?["load_calls"] == .integer(0),
                                   "trusted metadata/readiness worker executed plugin entry")
            }
            let hookCounts = trace.records.compactMap { $0.observation?["hooks"] }.compactMap { value -> [String: PluginJSONValue]? in
                if case let .object(result) = value { return result }; return nil
            }
            for name in ["developer_manifest", "inspect_developer_descriptor", "verified_developer_load"] {
                try elyxProbeCheck(hookCounts.contains { if case let .integer(count)? = $0[name] { return count > 0 }; return false }, "actual Python FD hook never executed: \(name)")
            }
            let staging = try services.serviceStorage.rootDirectory().appendingPathComponent(".elyx-developer-staging")
            try elyxProbeCheck(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty,
                               "native stage directory is not empty after real completion")
            if case let .string(directory)? = next["extract"] { try elyxProbeCheck(!FileManager.default.fileExists(atPath: directory), "final extraction survived Host uninstall") }
            try elyxProbeCheck(!FileManager.default.fileExists(atPath: path) && current.pluginList().isEmpty
                && current.permissionSnapshot(id: id).record == nil && current.bridge.elyxSourceDispatcher == nil, "Host uninstall/activation cleanup left owned state")
            report.cleanup = true; report.phase = "complete"; report.ok = true
            try report.write(reportURL)
            print("EXTERALESS_SWIFT_SDK_ELYX_DEVELOPER_PROBE_OK")
            return 0
        } catch {
            scope.invalidate(); active?.invalidate(); host?.deactivateElyxDeveloper()
            if let host { await host.stop() }; binding?.uninstall()
            let trace = engine.snapshot
            report.initializations = trace.initialized; report.finalizations = trace.finalized; report.traces = trace.records
            report.error = String(describing: error)
            try? report.write(reportURL)
            return 1
        }
    }
}
