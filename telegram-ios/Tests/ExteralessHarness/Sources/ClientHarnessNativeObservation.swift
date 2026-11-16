import Foundation
import PluginHost
import TelegramUI

/// Host sources are forwarded exactly once. Two separately counted FD-helper
/// calls follow each real plugin load on the same owner worker; no backend replacement.
final class ClientHarnessObservedEngine: CPythonEngine, @unchecked Sendable {
    private let native = CPythonXCFrameworkEngine()
    private let lock = NSLock()
    private var created: Set<Int64> = []
    private var destroyed: Set<Int64> = []
    private var initialized = 0
    private var finalized = 0
    private var scriptCalls = 0
    private var fdProbeScriptCalls = 0
    private var fdPaths: [[String: Any]] = []
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
        let result = try self.native.runScript(reference, source)
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            guard let helper = Bundle.main.url(forResource: "native_plugin_probe", withExtension: "py") else {
                throw ClientHarnessFailure(description: "missing bundled actual FD helper")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let helperPath = String(decoding: try encoder.encode(helper.path), as: UTF8.self)
            _ = try self.native.runScript(reference, """
            import importlib.util as _fd_import, sys as _fd_sys, json as _fd_json, hashlib as _fd_hash, _thread as _fd_thread
            from extera_utils import plugin_loader as _fd_loader
            from base_plugin import PythonBridge as _fd_bridge
            import exteraless_runtime as _fd_runtime, _exteraless_bridge as _fd_native
            if _fd_sys.platform != "ios":
                raise AssertionError("UIKit FD witness requires actual sys.platform ios")
            _fd_spec = _fd_import.spec_from_file_location("_client_ui_native_fd", \(helperPath))
            _fd_module = _fd_import.module_from_spec(_fd_spec)
            _fd_spec.loader.exec_module(_fd_module)
            _fd_record = _fd_loader.plugins["clientUIFixture"]
            if _fd_runtime._state.plugin_id != "clientUIFixture" or _fd_record.instance.worker != _fd_thread.get_ident():
                raise AssertionError("FD witness left the actual UIKit plugin owner")
            with _fd_loader.plugin_context("clientUIFixture"):
                _fd_module._probe_darwin_family_fds(_fd_record, _fd_bridge.getCacheDir())
            with open(\(helperPath), "rb") as _fd_input:
                _fd_digest = _fd_hash.file_digest(_fd_input, "sha256").hexdigest()
            _fd_observation = {"platform": _fd_sys.platform, "checks": dict(_fd_module._sdk_checks),
                "nativeReference": \(reference.raw), "ownerToken": _fd_runtime._state.owner_token,
                "helperSHA256": _fd_digest, "bridgeBuiltin": _fd_native.__spec__.origin == "built-in"}
            """)
            let json = try self.native.runScript(reference, "_fd_json.dumps(_fd_observation)")
            guard let data = json.data(using: .utf8),
                  let observation = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  observation["platform"] as? String == "ios",
                  let checks = observation["checks"] as? [String: Bool], checks["actual_ios_fd_paths"] == true else {
                throw ClientHarnessFailure(description: "actual iOS FD operations did not complete")
            }
            self.lock.lock()
            self.fdProbeScriptCalls += 2
            self.fdPaths.append(observation)
            self.lock.unlock()
        }
        return result
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
            "allDestroyed": !self.created.isEmpty && self.created == self.destroyed,
            "fdProbeScriptCalls": self.fdProbeScriptCalls, "fdPaths": self.fdPaths]
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
