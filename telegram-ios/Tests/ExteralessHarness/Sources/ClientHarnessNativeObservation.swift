import Foundation
import PluginHost
import TelegramUI

/// Transparent native engine forwarder. No source injection, interpreter
/// replacement, rendered pixels, or fabricated return values.
final class ClientHarnessObservedEngine: CPythonEngine, @unchecked Sendable {
    private let native = CPythonXCFrameworkEngine()
    private let lock = NSLock()
    private var created: Set<Int64> = []
    private var destroyed: Set<Int64> = []
    private var initialized = 0
    private var finalized = 0
    private var scriptCalls = 0
    private let journal: ClientHarnessJournal

    init(journal: ClientHarnessJournal) { self.journal = journal }
    var apiVersion: String { self.native.apiVersion }
    var isProcessInitialized: Bool { self.native.isProcessInitialized }

    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        try self.native.initializeProcess(configuration: configuration)
        self.lock.lock(); self.initialized += 1; self.lock.unlock()
        self.journal.record("cpython-initialize", ["version": self.apiVersion])
    }

    func finalizeProcess() throws {
        try self.native.finalizeProcess()
        self.lock.lock(); self.finalized += 1; self.lock.unlock()
        self.journal.record("cpython-finalize")
    }

    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        try clientHarnessRequire(!Thread.isMainThread && configuration.ownsGIL && configuration.checkMultiInterpExtensions,
            "CPython interpreter must be OWN_GIL on its native worker")
        let reference = try self.native.createInterpreter(configuration)
        self.lock.lock(); self.created.insert(reference.raw); self.lock.unlock()
        self.journal.record("cpython-create", ["reference": reference.raw, "ownGIL": configuration.ownsGIL])
        return reference
    }

    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        try clientHarnessRequire(!Thread.isMainThread, "Python entered on main")
        self.lock.lock(); self.scriptCalls += 1; self.lock.unlock()
        return try self.native.runScript(reference, source)
    }

    func destroyInterpreter(_ reference: InterpRef) throws {
        try clientHarnessRequire(!Thread.isMainThread, "Python destruction entered on main")
        try self.native.destroyInterpreter(reference)
        self.lock.lock(); self.destroyed.insert(reference.raw); self.lock.unlock()
        self.journal.record("cpython-destroy", ["reference": reference.raw])
    }

    func interpreterFootprintKB(_ reference: InterpRef) -> Int { self.native.interpreterFootprintKB(reference) }

    var snapshot: [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["initializations": self.initialized, "finalizations": self.finalized,
            "created": self.created.sorted(), "destroyed": self.destroyed.sorted(), "scriptCalls": self.scriptCalls,
            "allDestroyed": !self.created.isEmpty && self.created == self.destroyed]
    }
}

/// C -> real provider forwarding observation. Diagnostic uiState reads use the
/// provider directly and therefore cannot inflate the count of Python UI calls.
final class ClientHarnessObservedUI: PluginBridgeExtension, @unchecked Sendable {
    let provider: PluginUIBridgeExtension
    private let host: PluginHost
    private let journal: ClientHarnessJournal
    private let lock = NSLock()
    private var presentationIds: [String: [String]] = [:]
    private var epochs: Set<String> = []
    private var nativeUICalls = 0
    var exportedMethods: [String: Set<String>] { self.provider.exportedMethods }

    init(provider: PluginUIBridgeExtension, host: PluginHost, journal: ClientHarnessJournal) {
        self.provider = provider
        self.host = host
        self.journal = journal
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        let request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        if request?["op"] as? String == "call", let member = request?["member"] as? String,
           ["openURL", "addToClipboard"].contains(member) {
            self.journal.reject(member)
            throw BridgeFailure.unimplemented("client-ui-harness: external effect " + member + " is not provided")
        }
        if let epoch = request?["ownerToken"] as? String, let owner = self.host.callbackOwner(id: pluginId) {
            try clientHarnessRequire(pluginId == ClientHarnessRuntime.pluginId && owner.wireToken == epoch,
                "C request owner disagrees with current Host lifetime")
            self.lock.lock(); self.epochs.insert(epoch); self.lock.unlock()
        }
        let response = try self.provider.dispatch(requestJSON: requestJSON, pluginId: pluginId)
        if let response, request?["op"] as? String == "call" {
            try clientHarnessRequire(!Thread.isMainThread, "observed SDK UI request did not originate on native C worker")
            let reply = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            let member = request?["member"] as? String ?? "<missing>"
            self.lock.lock()
            self.nativeUICalls += 1
            if let value = reply?["value"] as? [String: Any], let id = value["id"] as? String {
                let args = request?["args"] as? [Any]
                let kind = member == "uiNavigate" ? "navigation" : args?.first as? String ?? member
                self.presentationIds[kind, default: []].append(id)
            }
            self.lock.unlock()
            self.journal.record("native-ui-request", ["member": member, "ok": reply?["ok"] as Any? ?? NSNull()])
        }
        return response
    }

    func releaseInstances(pluginId: String) { self.provider.releaseInstances(pluginId: pluginId) }

    var snapshot: [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["nativeUICalls": self.nativeUICalls, "cEpochs": self.epochs.sorted(), "presentations": self.presentationIds]
    }

    func lastId(_ kind: String) -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.presentationIds[kind]?.last
    }
}
