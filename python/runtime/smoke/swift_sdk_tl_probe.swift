import Foundation
import Darwin

private struct SDKTLFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}
private func tlCheck(_ value: Bool, _ message: String) throws {
    if !value { throw SDKTLFailure(description: message) }
}
private func tlQuote(_ value: String) -> String {
    // This string is embedded in Python source, not decoded with json.loads.
    // Use the Host's Python-literal encoder; JSON's escaped slash is literal in Python.
    PluginRuntimeScript.quote(value)
}
private func tlThread() -> UInt64 { var id: UInt64 = 0; pthread_threadid_np(nil, &id); return id }

/// The real Foundation TL binary codec and generated native schema. No RPC,
/// AccountStateManager or UIKit service runs in this fixture.
private final class SDKTLFixtureSchema: @unchecked Sendable {
    private struct Metadata: Decodable {
        let schemaVersion: Int
        let sourceSHA256: String
        let nativeLayoutHash: String
        let hookNames: [String: [String]]
    }
    private let codec = ExteralessTLCodec()
    private let lock = NSLock()
    private var lengths: [Int] = []
    let hookNames: [String: [String]]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try tlCheck(data.count <= 16_777_216, "fixture schema exceeds bound")
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        try tlCheck(metadata.schemaVersion == 1, "fixture requires schema v1")
        try tlCheck(metadata.sourceSHA256 == codec.sourceSHA256 && UInt64(metadata.nativeLayoutHash, radix: 16) == codec.nativeLayoutHash,
            "SDK metadata and compiled native TL schema differ")
        self.hookNames = metadata.hookNames
    }

    var validatedRequestLengths: [Int] { lock.lock(); defer { lock.unlock() }; return lengths }

    func normalize(_ json: String, name: String, kind: ExtensionPointKind) throws -> String {
        try tlCheck(json.utf8.count <= 32_768, "canned TL input exceeds 32 KiB")
        let value = try ExteralessTLValue(jsonObject: JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
        let normalized: ExteralessTLValue
        if kind == .preRequest {
            let request = try codec.encodeRequest(value)
            try tlCheck(request.methodName == name, "fixture replacement changed the method")
            normalized = try codec.decodeRequest(request.body)
        } else if kind == .postRequest {
            normalized = try codec.normalize(value, as: codec.resultTypeOfMethod(name))
        } else {
            guard let type = codec.typeOfConstructor(name) else { throw SDKTLFailure(description: "unknown fixture update type") }
            normalized = try codec.normalize(value, as: type)
        }
        if kind == .preRequest, name == "users.getUsers", case let .array(ids)? = normalized["id"] {
            lock.lock(); lengths.append(ids.count); lock.unlock()
        }
        let result = try normalized.jsonString()
        try tlCheck(result.utf8.count <= 32_768, "canned TL output exceeds 32 KiB")
        return result
    }
}

struct SDKTLCheckIdentity: Codable, Sendable {
    let pluginId: String
    let handle: Int64
}

struct SDKTLObservation: Codable, Sendable {
    let threadId: UInt64
    let pluginId: String?
    let ownerToken: String?
    let pluginSource: String?
    let runtimeSource: String?
    let sdkSource: String?
    let handleCount: Int
    let callbackLeases: Int
    let loadedPlugins: [String]
    let bridgeBuiltin: Bool
    let backendInstalled: Bool
    let legacyServiceCount: Int
    let mockCalls: Int
}
struct SDKTLTrace: Encodable, Sendable {
    let nativeReference: Int64
    let thread: UInt64
    let ownGIL: Bool
    var destroyed = false
    var hostCalls = 0
    var initializedProbe = false
    var observation: SDKTLObservation?
    var checks: SDKTLCheckIdentity?
    var sources: [String] = []
    var dispatchErrors: [String] = []
}

/// Every source is forwarded unchanged to the actual CPython engine. Extra
/// read-only observations execute on the same owner before native destruction.
final class SDKTLObservedEngine: CPythonEngine, @unchecked Sendable {
    private let native = CPythonXCFrameworkEngine()
    private let helper: String
    private let lock = NSLock()
    private var records: [Int64: SDKTLTrace] = [:]
    private var initialized = 0
    private var finalized = 0
    private var sourceObserver: (@Sendable (String) throws -> Void)?
    init(helper: String) { self.helper = helper }
    var apiVersion: String { native.apiVersion }
    var isProcessInitialized: Bool { native.isProcessInitialized }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        try native.initializeProcess(configuration: configuration)
        lock.lock(); initialized += 1; lock.unlock()
    }
    func finalizeProcess() throws {
        try native.finalizeProcess()
        lock.lock(); finalized += 1; lock.unlock()
    }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        try tlCheck(!Thread.isMainThread && configuration.ownsGIL && !configuration.useMainObmalloc && configuration.checkMultiInterpExtensions, "TL fixture lost OWN_GIL worker isolation")
        let reference = try native.createInterpreter(configuration)
        lock.lock(); records[reference.raw] = SDKTLTrace(nativeReference: reference.raw, thread: tlThread(), ownGIL: configuration.ownsGIL); lock.unlock()
        return reference
    }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        let record = try current(reference)
        try tlCheck(!Thread.isMainThread && record.thread == tlThread(), "TL SDK call left its native owner")
        if !record.initializedProbe {
            _ = try native.runScript(reference, """
            import importlib.util as _tl_import
            _tl_spec = _tl_import.spec_from_file_location('_native_tl_probe', \(tlQuote(helper)))
            _native_tl_probe = _tl_import.module_from_spec(_tl_spec)
            _tl_spec.loader.exec_module(_native_tl_probe)
            """)
            lock.lock(); records[reference.raw]?.initializedProbe = true; lock.unlock()
        }
        lock.lock()
        records[reference.raw]?.hostCalls += 1
        records[reference.raw]?.sources.append(source)
        let observer = sourceObserver
        lock.unlock()
        try observer?(source)
        let value: String
        do {
            value = try native.runScript(reference, source)
        } catch {
            if source.hasPrefix("_exteraless_runtime.dispatch_json(") {
                lock.lock()
                if (records[reference.raw]?.dispatchErrors.count ?? 0) < 4 {
                    records[reference.raw]?.dispatchErrors.append(String(String(describing: error).suffix(1200)))
                }
                lock.unlock()
            }
            throw error
        }
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            let json = try native.runScript(reference, "_native_tl_probe.loaded()")
            let identity = try JSONDecoder().decode(SDKTLCheckIdentity.self, from: Data(json.utf8))
            lock.lock(); records[reference.raw]?.checks = identity; lock.unlock()
        }
        return value
    }
    func destroyInterpreter(_ reference: InterpRef) throws {
        let record = try current(reference)
        try tlCheck(record.thread == tlThread() && !Thread.isMainThread, "TL destruction left its native owner")
        if record.initializedProbe {
            let source = try native.runScript(reference, "_native_tl_probe.observation()")
            let observation = try JSONDecoder().decode(SDKTLObservation.self, from: Data(source.utf8))
            lock.lock(); records[reference.raw]?.observation = observation; lock.unlock()
        }
        try native.destroyInterpreter(reference)
        lock.lock(); records[reference.raw]?.destroyed = true; lock.unlock()
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { native.interpreterFootprintKB(reference) }
    private func current(_ reference: InterpRef) throws -> SDKTLTrace {
        lock.lock(); defer { lock.unlock() }
        guard let value = records[reference.raw] else { throw SDKTLFailure(description: "missing TL native interpreter record") }
        return value
    }
    var snapshot: (records: [SDKTLTrace], initializations: Int, finalizations: Int) {
        lock.lock(); defer { lock.unlock() }
        return (records.values.sorted { $0.nativeReference < $1.nativeReference }, initialized, finalized)
    }

    func checks(_ pluginId: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle = records.values.filter({ !$0.destroyed }).compactMap(\.checks).first(where: { $0.pluginId == pluginId })?.handle else {
            throw SDKTLFailure(description: "missing native SDK checks handle")
        }
        return handle
    }

    func observeSources(_ observer: @escaping @Sendable (String) throws -> Void) {
        lock.lock(); sourceObserver = observer; lock.unlock()
    }
}

private struct SDKTLReport: Encodable {
    let probe = "swift-sdk-tl-phase2"
    let boundary = "Foundation native TL codec and DTO recorders; no UIKit/network/state application"
    var ok = false
    var nameMatching = false
    var normalizedBetweenPlugins = false
    var modifyFinal = false
    var cancel = false
    var invalidReplacementKeptOriginal = false
    var updateKinds = false
    var postError = false
    var readonlyMetadata = false
    var nativeBridge = false
    var ownerEpochs = false
    var cleanup = false
    var nativeCodec = false
    var booleanFlags = false
    var sharedFlagCompanions = false
    var resultVectors = false
    var requestCancelWinner = false
    var nativeTextRoutes = false
    var legacyTextOrigin = false
    var rootConfigBindings = false
    var initializations = 0
    var finalizations = 0
    var traces: [SDKTLTrace] = []
    var validatedRequestLengths: [Int] = []
    var legacyTextRecords: [PluginJSONValue] = []
    var boundaryReleases: [Int64] = []
    var flags2Diagnostics: [String: PluginJSONValue] = [:]
    var error: String?
    func write(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum SDKTLNativeProbe {
    static func run(_ arguments: [String]) async -> Int32 {
        let reportURL = URL(fileURLWithPath: arguments[1])
        let work = URL(fileURLWithPath: arguments[7], isDirectory: true)
        let textRecorder = SDKTLTextRecorder()
        let services = NativeSDKFixtureServices(root: work.appendingPathComponent("native-storage", isDirectory: true), textRecorder: { try textRecorder.record($0) })
        let engine = SDKTLObservedEngine(helper: arguments[8])
        var report = SDKTLReport()
        var host: PluginHost?
        var binding: NativeBridgeBinding?
        do {
            try report.write(reportURL)
            let plugins = try services.serviceStorage.pluginsDirectory()
            let configuration = PythonRuntimeConfiguration(programName: "exteraless-sdk-tl-probe", frameworkHome: arguments[2],
                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
                pluginRootDirectory: plugins.path, writeBytecode: false, installSignalHandlers: false,
                manifestPath: work.appendingPathComponent("manifest.json").path,
                executablePath: URL(fileURLWithPath: arguments[0]).standardizedFileURL.path)
            let current = try PluginHost(engine: engine, configuration: .init(runtime: configuration,
                interpreters: PythonInterpreterLimits(maxInterpreters: 4, callTimeout: 5), storageDirectory: plugins),
                services: .init(messages: services, settings: services, ui: services))
            host = current
            let callbacks = PluginCallbackDispatcher(host: current)
            let fixture = SDKTLBoundaryFixture(callbacks: callbacks)
            let config = try SDKConfigRootFixture(directory: work.appendingPathComponent("global-client-settings", isDirectory: true))
            current.bridge.extensionProvider = CompositePluginBridgeExtension([config.provider(callbacks: callbacks), fixture])
            let nativeBinding = NativeBridgeBinding(services: current.bridge)
            binding = nativeBinding; try nativeBinding.install()
            try await current.start()
            for file in ["native_tl_first.plugin", "native_tl_second.plugin"] {
                let url = URL(fileURLWithPath: arguments[6], isDirectory: true).appendingPathComponent(file)
                var metadata = try await current.readPluginMetadata(sourceURL: url)
                metadata.enabled = false
                _ = try await current.installPlugin(sourceURL: url, metadata: metadata)
                try current.setGrantedPermissions(id: metadata.id, permissions: [.messagesRead, .messagesSend, .network, .settings])
                try await current.setPluginEnabled(id: metadata.id, true)
            }
            try tlCheck(current.pluginList().count == 2 && current.pluginList().allSatisfy { $0.loaded && !$0.notResponding }, "real SDK TL fixtures did not load")
            guard let configWriter = callbacks.captureOwner("nativeTLSdkZ"), let configReader = callbacks.captureOwner("nativeTLSdkA") else {
                throw SDKTLFailure(description: "Missing real Config SDK owners")
            }
            let writerChecks = try engine.checks(configWriter.pluginId), readerChecks = try engine.checks(configReader.pluginId)
            let written = try await callbacks.result(configWriter, writerChecks, "config", "[true]")
            try tlCheck(written == "44", "Not all root-registered compatibility getters/setters executed")
            try config.reopen()
            current.bridge.extensionProvider = CompositePluginBridgeExtension([config.provider(callbacks: callbacks), fixture])
            let read = try await callbacks.result(configReader, readerChecks, "config", "[false]")
            try tlCheck(read == "22", "Second plugin did not read reloaded global Config values")
            try tlCheck(try services.serviceStorage.getSetting(pluginId: configWriter.pluginId, key: "tabCounter", defaultValue: .null) == .string("writer-private")
                && services.serviceStorage.getSetting(pluginId: configWriter.pluginId, key: "readerPrivate", defaultValue: .null) == .null,
                "global Config aliased per-plugin settings")
            report.rootConfigBindings = true
            let root = URL(fileURLWithPath: arguments[5], isDirectory: true)
            let primarySchema = root.appendingPathComponent("tl-schema.json")
            let schema = try SDKTLFixtureSchema(url: FileManager.default.fileExists(atPath: primarySchema.path) ? primarySchema : root.appendingPathComponent("runtime/tl-schema.json"))
            func stored(_ id: String, _ key: String) throws -> PluginJSONValue {
                try services.serviceStorage.getSetting(pluginId: id, key: key, defaultValue: .null)
            }
            func mode(_ value: String) throws { try services.serviceStorage.setSetting(pluginId: "nativeTLSdkZ", key: "mode", value: .string(value)) }
            func payload(_ kind: ExtensionPointKind, _ name: String, _ json: String, error: String? = nil,
                         origin: PluginTLInvocationOrigin? = nil) throws -> PluginTLHostPayload {
                guard let hookName = schema.hookNames[name]?.first else { throw SDKTLFailure(description: "missing generated Android hook name") }
                let normalized = error == nil ? try schema.normalize(json, name: name, kind: kind) : json
                return PluginTLHostPayload(kind: kind, account: 2, name: hookName, canonicalName: name, valueJSON: normalized,
                    metadataJSON: "{\"requestName\":\(tlQuote(name)),\"fixture\":true}", errorJSON: error, canCancel: true,
                    originPluginIds: origin?.pluginIds ?? [], originRootId: origin?.rootId,
                    normalize: { replacement in
                        if kind == .postRequest {
                            try tlCheck(replacement.utf8.count <= 32_768, "canned TL input exceeds 32 KiB")
                            guard error == nil else { throw SDKTLFailure(description: "RPC errors are read-only") }
                            let codec = ExteralessTLCodec.shared
                            let original = try ExteralessTLValue(jsonObject: JSONSerialization.jsonObject(with: Data(normalized.utf8), options: .fragmentsAllowed))
                            let metadata = ExteralessTLValue.object(["requestName": .string(name), "fixture": .bool(true)])
                            let body = try ExteralessTLTransformCodec.response(replacement, original: original,
                                type: codec.resultTypeOfMethod(name), metadata: metadata)
                            let result = try codec.decodeMethodResponse(body, methodName: name).jsonString()
                            try tlCheck(result.utf8.count <= 32_768, "canned TL output exceeds 32 KiB")
                            return result
                        }
                        return try schema.normalize(replacement, name: name, kind: kind)
                    }, shouldExecute: { true })
            }
            let request = "{\"_\":\"users.getUsers\",\"id\":[{\"_\":\"inputUserSelf\"}]}"
            let modified = try await current.events.transformTL(payload(.preRequest, "users.getUsers", request))
            try tlCheck(modified.strategy == .modifyFinal && (try stored("nativeTLSdkA", "seen_count")) == .integer(2), "priority/name matching or request normalization failed")
            try tlCheck(Array(schema.validatedRequestLengths.suffix(2)) == [2, 3], "Host did not normalize between SDK plugins")
            report.nameMatching = true; report.normalizedBetweenPlugins = true
            let secondCalls = try stored("nativeTLSdkA", "pre_calls")
            try mode("final")
            let final = try await current.events.transformTL(payload(.preRequest, "users.getUsers", request))
            try tlCheck(final.strategy == .modifyFinal && (try stored("nativeTLSdkA", "pre_calls")) == secondCalls, "MODIFY_FINAL entered a lower-priority SDK plugin")
            report.modifyFinal = true
            try mode("cancel")
            let cancelled = try await current.events.transformTL(payload(.preRequest, "users.getUsers", request))
            try tlCheck(cancelled.strategy == .cancel && (try stored("nativeTLSdkA", "pre_calls")) == secondCalls, "CANCEL entered a lower-priority SDK plugin")
            report.cancel = true
            try mode("invalid")
            let invalid = try await current.events.transformTL(payload(.preRequest, "users.getUsers", request))
            try tlCheck(invalid.strategy == .modifyFinal && (try stored("nativeTLSdkA", "seen_count")) == .integer(1), "invalid replacement reached the next SDK plugin")
            report.invalidReplacementKeptOriginal = true
            let update = "{\"_\":\"updateUserName\",\"user_id\":7,\"first_name\":\"before\",\"last_name\":\"kept\",\"usernames\":[]}"
            let changed = try await current.events.transformTL(payload(.update, "updateUserName", update))
            guard let updatedJSON = changed.valueJSON,
                  case let .object(updated) = try JSONDecoder().decode(PluginJSONValue.self, from: Data(updatedJSON.utf8)) else { throw SDKTLFailure(description: "update hook returned no real TL value") }
            try tlCheck(changed.strategy == .modifyFinal && updated["first_name"] == .string("native TL 雪\u{0}π"), "update registration/protocol/value failed")
            let container = "{\"_\":\"updates\",\"updates\":[],\"users\":[],\"chats\":[],\"date\":1700000000,\"seq\":7}"
            let cancelledContainer = try await current.events.transformTL(payload(.updates, "updates", container))
            try tlCheck(cancelledContainer.strategy == .cancel, "container hook did not use its actual registration")
            report.updateKinds = true
            _ = try await current.events.transformTL(payload(.postRequest, "users.getUsers", "null", error: "{\"_\":\"error\",\"code\":400,\"text\":\"fixture RPC error\"}"))
            try tlCheck(try stored("nativeTLSdkZ", "post_error") == .integer(400), "native RPC error was not decoded by the SDK")
            report.postError = true
            try tlCheck(try stored("nativeTLSdkZ", "readonly_metadata") == .bool(true), "TL context was not read-only")
            report.readonlyMetadata = true

            // TLN-08: decoded flags pass through Python setters and the actual
            // native binary codec before the lower-priority plugin observes them.
            let textRequest = "{\"_\":\"messages.sendMessage\",\"flags\":0,\"peer\":{\"_\":\"inputPeerSelf\"},\"message\":\"fixture\",\"random_id\":1,\"silent\":false}"
            try mode("silent_on")
            let silent = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", textRequest))
            try tlCheck(try stored("nativeTLSdkA", "seen_silent") == .bool(true) && stored("nativeTLSdkA", "seen_flags") == .integer(32), "silent true did not survive the native mask validator")
            guard let silentJSON = silent.valueJSON else { throw SDKTLFailure(description: "silent mutation missing") }
            try mode("silent_off")
            _ = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", silentJSON))
            try tlCheck(try stored("nativeTLSdkA", "seen_silent") == .bool(false) && stored("nativeTLSdkA", "seen_flags") == .integer(0), "silent false did not clear the native bit")
            try mode("unknown_flags")
            _ = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", textRequest))
            try tlCheck(try stored("nativeTLSdkA", "seen_silent") == .bool(false) && stored("nativeTLSdkA", "seen_flags") == .integer(0), "SDK/native validator sanitized an unknown bit")
            report.booleanFlags = true
            let user = "[{\"_\":\"user\",\"id\":7,\"flags\":0,\"flags2\":1,\"usernames\":[]}]"
            try mode("flags2_on")
            let flagged = try await current.events.transformTL(payload(.postRequest, "users.getUsers", user))
            let seenCloseFriend = try stored("nativeTLSdkA", "seen_close_friend")
            let seenFlags2 = try stored("nativeTLSdkA", "seen_flags2")
            report.flags2Diagnostics = [
                "strategy": .string(String(describing: flagged.strategy)),
                "normalized_result": flagged.valueJSON.map { PluginJSONValue.string(String($0.prefix(2048))) } ?? .null,
                "seen_close_friend": seenCloseFriend, "seen_flags2": seenFlags2
            ]
            try tlCheck(seenCloseFriend == .bool(true) && seenFlags2 == .integer(5), "flags2 mutation or nested ArrayList lost")
            guard let flaggedJSON = flagged.valueJSON else { throw SDKTLFailure(description: "flags2 mutation missing") }
            try mode("flags2_off")
            _ = try await current.events.transformTL(payload(.postRequest, "users.getUsers", flaggedJSON))
            try tlCheck(try stored("nativeTLSdkA", "seen_close_friend") == .bool(false) && stored("nativeTLSdkA", "seen_flags2") == .integer(1), "flags2 false changed a value-optional bit")
            try mode("bot_missing")
            _ = try await current.events.transformTL(payload(.postRequest, "users.getUsers", user))
            try tlCheck(try stored("nativeTLSdkA", "seen_bot") == .bool(false), "missing shared-bit companion reached the next plugin")
            try mode("bot_on")
            let bot = try await current.events.transformTL(payload(.postRequest, "users.getUsers", user))
            try tlCheck(try stored("nativeTLSdkA", "seen_bot") == .bool(true) && stored("nativeTLSdkA", "seen_bot_version") == .integer(9), "valid shared-bit bot edit failed")
            guard let botJSON = bot.valueJSON else { throw SDKTLFailure(description: "bot mutation missing") }
            try mode("bot_off_inconsistent")
            _ = try await current.events.transformTL(payload(.postRequest, "users.getUsers", botJSON))
            try tlCheck(try stored("nativeTLSdkA", "seen_bot") == .bool(true), "value companion was silently removed on Bool mutation")
            do {
                _ = try schema.normalize("{\"_\":\"messages.sendMessage\",\"flags\":0,\"peer\":{\"_\":\"inputPeerSelf\"},\"message\":\"fixture\",\"random_id\":1,\"schedule_date\":1700000123}", name: "messages.sendMessage", kind: .preRequest)
                throw SDKTLFailure(description: "value-optional mask mismatch was accepted")
            } catch let error as ExteralessTLError { try tlCheck(error.kind == .malformed, "unexpected native optional error") }
            report.sharedFlagCompanions = true; report.nativeCodec = true

            // TLN-11: real declared method responses, primitive wrappers and
            // mutation back to arrays through the native method-result codec.
            try mode("vector_users")
            _ = try await current.events.transformTL(payload(.postRequest, "users.getUsers", "[{\"_\":\"userEmpty\",\"id\":7}]"))
            try tlCheck(try stored("nativeTLSdkA", "vector_user_ids") == .array([.integer(7), .integer(29)]), "Vector<User>.objects mutation lost")
            _ = try await current.events.transformTL(payload(.postRequest, "stories.readStories", "[7]"))
            try tlCheck(try stored("nativeTLSdkA", "vector_numbers") == .array([.integer(7), .integer(29)]), "Vector<Int> conversion/wire mutation lost")
            _ = try await current.events.transformTL(payload(.postRequest, "messages.receivedQueue", "[9007199254740993]"))
            try tlCheck(try stored("nativeTLSdkA", "vector_numbers") == .array([.integer(9_007_199_254_740_994)]), "Vector<Long> exact integer mutation lost")
            report.resultVectors = true

            // TLN-02: the legacy service gets the C-owned worker ancestry, then
            // an asynchronous native hop re-enters Host with only that ancestry.
            func textCalls(_ id: String) throws -> Int64 {
                if case let .integer(value) = try stored(id, "text_pre_calls") { return value }
                return 0
            }
            let firstBefore = try textCalls("nativeTLSdkZ"), secondBefore = try textCalls("nativeTLSdkA")
            try mode("origin_root")
            _ = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", textRequest))
            guard let captured = textRecorder.snapshot.first, let origin = captured.origin else { throw SDKTLFailure(description: "legacy C text lost its hook origin") }
            try tlCheck(origin.pluginIds == ["nativeTLSdkZ"], "legacy text ancestry was not the actual hook owner")
            let forwarded = await Task.detached { textRecorder.snapshot.first }.value
            try tlCheck(forwarded?.origin == origin, "native hop changed captured text ancestry")
            _ = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", textRequest, origin: forwarded?.origin))
            try tlCheck(try textCalls("nativeTLSdkZ") == firstBefore + 1 && textCalls("nativeTLSdkA") == secondBefore + 2, "delayed child did not skip only its ancestor")
            guard let owner = callbacks.captureOwner("nativeTLSdkZ") else { throw SDKTLFailure(description: "missing TL SDK owner") }
            let checks = try engine.checks(owner.pluginId)
            func check(_ method: String, _ arguments: String = "[]") async throws -> PluginJSONValue {
                let json = try await callbacks.result(owner, checks, method, arguments)
                return try NativeServiceWire.decode(json)
            }
            try tlCheck(try await check("legacy_unrelated") == .bool(true), "direct legacy Runtime.sendMessage failed")
            guard textRecorder.snapshot.count == 2, let ordinary = textRecorder.snapshot.last else { throw SDKTLFailure(description: "missing unrelated legacy text") }
            try tlCheck(ordinary.origin == nil, "unrelated legacy text inherited the prior hook scope")
            _ = try await current.events.transformTL(payload(.preRequest, "messages.sendMessage", textRequest, origin: ordinary.origin))
            try tlCheck(try textCalls("nativeTLSdkZ") == firstBefore + 2 && textCalls("nativeTLSdkA") == secondBefore + 3, "unrelated text did not traverse both SDK plugins")
            report.legacyTextOrigin = true
            report.legacyTextRecords = textRecorder.snapshot.map { request in
                .object(["pluginId": .string(request.pluginId), "account": .integer(Int64(request.account.index)),
                    "text": .string(request.text), "originPluginIds": request.origin.map { .array($0.pluginIds.map(PluginJSONValue.string)) } ?? .null,
                    "originRootId": request.origin.map { .string($0.rootId) } ?? .null])
            }

            // TLN-06: false/throw leave the legitimate completion pending; true
            // cancels only the captured ticket. Releases use the actual Host FIFO.
            for outcome in ["false", "throw", "true"] {
                guard case let .string(id) = try await check("begin_request") else { throw SDKTLFailure(description: "SDK returned no request ticket") }
                fixture.setCancellation(outcome == "false" ? .completionWon : outcome == "throw" ? .fail : .cancel)
                try tlCheck(try await check("cancel_request", "[\(tlQuote(outcome))]") == .bool(true), "SDK cancellation winner mismatch")
                if outcome != "true" {
                    try await fixture.complete(id, value: .array([.object(["_": .string("userEmpty"), "id": .integer(101)])]), checks: checks)
                }
                _ = try await check("barrier")
                try tlCheck(try await check("after_request", outcome == "true" ? "[0]" : "[1]") == .bool(true), "TL completion/release was lost or duplicated")
            }
            fixture.setCancellation(.cancel)
            report.requestCancelWinner = true

            // TLN-07: only messages.send is granted. Exact rich/scheduled/edit
            // presence reaches native DTO admission; no getPeer or raw RPC route.
            try current.setGrantedPermissions(id: owner.pluginId, permissions: [.messagesSend])
            let local: PluginJSONValue = .object(["status": .string("enqueued"), "messageIds": .array([.object(["peerId": .integer(101), "namespace": .integer(1), "id": .integer(901)])])])
            for scenario in ["rich", "scheduled", "edit_omitted", "edit_empty", "receipt"] {
                guard case let .string(id) = try await check("begin_text", "[\(tlQuote(scenario))]") else { throw SDKTLFailure(description: "SDK returned no text ticket") }
                let entry = try fixture.entry(id)
                guard case let .object(model) = entry.model else { throw SDKTLFailure(description: "text DTO missing") }
                try tlCheck(entry.member == (scenario.hasPrefix("edit_") ? "editMedia" : "sendMedia"), "high-level text used raw TL")
                if scenario == "rich" {
                    try tlCheck(model["caption"] == .string("native") && model["replyTo"] == .object(["id": .integer(7), "namespace": .integer(1)])
                        && model["entities"] == .array([.object(["_": .string("messageEntityBold"), "offset": .integer(0), "length": .integer(6)])]), "rich text/reply DTO changed")
                } else if scenario == "scheduled" {
                    try tlCheck(model["silent"] == .bool(false) && model["entities"] == .array([]) && model["scheduleTime"] == .integer(1_700_000_123)
                        && model["threadId"] == .integer(7) && model["disableLinkPreviews"] == .bool(true), "scheduled text presence changed")
                } else if scenario == "edit_omitted" {
                    try tlCheck(model["caption"] == nil && model["entities"] == nil && model["spoiler"] == nil, "text edit overwrote omitted fields")
                } else if scenario == "edit_empty" {
                    try tlCheck(model["caption"] == .string("") && model["entities"] == nil && model["spoiler"] == .bool(false), "empty edit fields were dropped")
                }
                let failure: PluginJSONValue = scenario == "scheduled" ? .object(["_": .string("error"), "code": .integer(403), "text": .string("PAID_MESSAGES_UNSUPPORTED")]) : .null
                let response: PluginJSONValue = scenario.hasPrefix("edit_") ? .object(["status": .string("edited"), "messageId": .object(["peerId": .integer(101), "namespace": .integer(3), "id": .integer(7)])]) : local
                try await fixture.complete(id, value: failure == .null ? response : .null, error: failure, checks: checks)
            }
            try tlCheck(try await check("after_text") == .bool(true) && fixture.pendingCount == 0, "native DTO local receipt/callback release failed")
            try tlCheck(services.serviceLogs.entries(pluginId: owner.pluginId).contains { $0.message.contains("PAID_MESSAGES_UNSUPPORTED") }, "native text failure was not visible in the SDK log")
            report.nativeTextRoutes = true
            report.boundaryReleases = fixture.releases
            try tlCheck(Set(fixture.releases).count == fixture.releases.count && fixture.releases.count == 8, "TL native callback release was not exactly once")
            await current.stop(); nativeBinding.uninstall()
            let snapshot = engine.snapshot
            report.traces = snapshot.records; report.initializations = snapshot.initializations; report.finalizations = snapshot.finalizations
            let pluginTraces = snapshot.records.compactMap(\.observation).filter { $0.pluginId != nil }
            try tlCheck(snapshot.records.count == 4 && snapshot.initializations == 1 && snapshot.finalizations == 1 && pluginTraces.count == 2, "TL fixture interpreter lifetime count changed")
            try tlCheck(snapshot.records.allSatisfy { $0.destroyed && $0.ownGIL && $0.hostCalls > 0 }, "TL interpreter did not finish on its owner")
            try tlCheck(pluginTraces.allSatisfy { $0.bridgeBuiltin && $0.backendInstalled && $0.legacyServiceCount == 0 && $0.mockCalls == 0 }, "TL SDK used a nonnative backend")
            report.nativeBridge = true
            let epochs = pluginTraces.compactMap(\.ownerToken)
            try tlCheck(epochs.count == 2 && Set(epochs).count == 2 && epochs.allSatisfy { UUID(uuidString: $0) != nil }, "TL plugin epochs were absent/reused")
            report.ownerEpochs = true
            try tlCheck(pluginTraces.allSatisfy { $0.handleCount == 0 && $0.callbackLeases == 0 && $0.loadedPlugins.isEmpty } && services.unexpectedEffects.isEmpty, "TL SDK cleanup/effect boundary failed")
            report.cleanup = true
            report.validatedRequestLengths = schema.validatedRequestLengths
            report.ok = true; try report.write(reportURL)
            print("EXTERALESS_SWIFT_SDK_TL_PROBE_OK")
            return 0
        } catch {
            if let host { await host.stop() }
            binding?.uninstall()
            let snapshot = engine.snapshot
            report.traces = snapshot.records; report.initializations = snapshot.initializations; report.finalizations = snapshot.finalizations
            report.error = String(describing: error)
            try? report.write(reportURL)
            return 1
        }
    }
}
