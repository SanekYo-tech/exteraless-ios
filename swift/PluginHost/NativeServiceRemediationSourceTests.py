"""HNS-02/HNS-03 source wiring checks, not Swift/CPython execution evidence."""
import importlib.util
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "swift/PluginHost/Sources/PluginHost"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices"


def read(path):
    return path.read_text(encoding="utf-8")


class NativeServiceRemediationSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "telegram-ios/build-system/Make/PostboxImportCheck.py"
        spec = importlib.util.spec_from_file_location("NativeRemediationPostboxCheck", path)
        cls.checker = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(cls.checker)

    def test_cleanup_is_revoke_only_and_does_not_resolve_active_owner(self):
        cleanup = read(HOST / "NativeServiceCleanup.swift")
        code = self.checker.strip_comments_and_strings(cleanup)
        self.assertNotRegex(code, r"\b(?:captureOwner|hasPermission|callbackOwner|reserve|schedule)\s*\(")
        for member in ("cancelOwnerTask", "nativeServiceCancel", "notificationUnsubscribe", "fileRemove", "intentRemove"):
            self.assertIn('"' + member + '"', cleanup)
        lease = read(HOST / "NativeServiceCallback.swift")
        self.assertIn("private let ownerWireToken: String?", lease)
        self.assertIn("pluginId == identity.pluginId && ownerWireToken != nil && ownerWireToken == identity.ownerToken", lease)
        for name in ("NativeServiceScheduler.swift", "NativeServiceOperations.swift", "NativeServiceOpenBarrier.swift"):
            source = read(HOST / name)
            self.assertIn("cleanup: NativeServiceCleanupIdentity", source)
            self.assertIn("$0.matchesCleanup(cleanup)", source)

    def test_plain_and_result_routes_both_forward_worker_control(self):
        source = read(HOST / "NativeServiceCallback.swift")
        self.assertRegex(source, r"public typealias NativeServiceCallback<[^>]+> = @Sendable \(\s*Owner, Int64, String, String, NativeServiceCallbackControl")
        self.assertEqual(source.count("shouldExecute: { control.allowsExecution }"), 2)
        self.assertIn("callback(owner, handle, method, argumentsJSON, control)", source)
        self.assertIn("if !admitted { deliveryEntitlement.revoke() }", source)
        send = source[source.index("public func send("):source.index("public func request(")]
        self.assertIn("control.bindExecutionCheck { entitlement.allowsExecution }", send)
        self.assertNotIn("[weak self]", send)
        self.assertNotIn("self?.isOpen", send)

    def test_production_provider_wires_cleanup_saved_epoch_and_callback_adapter(self):
        source = read(UI / "PluginNativeServicesBridgeExtension.swift")
        self.assertIn("public typealias Callback = NativeServiceCallback<PluginHost.CallbackOwner>", source)
        self.assertIn("callback: NativeServiceCallbackTransport.callback(using: callbacks)", source)
        self.assertIn("ownerWireToken: captured.wireToken", source)
        self.assertLess(source.index("NativeServiceCleanupRoute.dispatch(request"), source.index("switch request.member"))
        self.assertNotRegex(source, r"(?:scheduler\.cancel|operations\.take|interceptions\.remove)\([^\n]*owner: try owner\(")
        self.assertIn("ticket.lease.send(argumentsJSON: arguments, terminal: true)", source)

    def test_guard_stays_lock_only_and_changed_ui_respects_postbox_boundary(self):
        source = read(HOST / "NativeServiceCallback.swift")
        entitlement = source[source.index("private final class NativeServiceDeliveryEntitlement"):source.index("public final class NativeServiceCallbackLease")]
        code = self.checker.strip_comments_and_strings(entitlement)
        self.assertNotRegex(code, r"MainActor|DispatchQueue\.main|\.sync\(|\.wait\(|\.postbox")
        for name in ("PluginNativeServicesBridgeExtension.swift", "NativeServiceControllerSnapshots.swift"):
            source = read(UI / name)
            self.assertIsNone(self.checker.find_import_line(source), name)
            self.assertIsNone(self.checker.find_access_line(source), name)
        self.assertIn("for state in contexts.values { values.end(state.scope) }", read(UI / "NativeServiceControllerSnapshots.swift"))


if __name__ == "__main__":
    unittest.main()
