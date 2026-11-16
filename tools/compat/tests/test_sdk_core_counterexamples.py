"""Configured SDK regressions for CORE-API-F01/F03/F04/F05, <=30s per child.

The C variant uses the existing extension named by EXTERALESS_TL_C_BRIDGE.
Native services/edit validation are explicit recorders, not UIKit/Swift/RPC runs.
The coordinator-only reflection install hunk is joined in memory after configure.
"""

import ctypes
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
CASES = ("edit_omission", "class_existence", "user_callbacks", "queue_isolation")
PLUGIN = '''__id__ = "sdkCoreRemediation"
__name__ = "Own SDK core counterexample fixture"
__permissions__ = ["ui", "network", "messages.read", "messages.send", "settings"]
from base_plugin import BasePlugin
import client_utils as client
class Probe(BasePlugin):
    def on_plugin_load(self):
        self.events = []
        self.mode = "ok"
        self.task_callback = self.task_body
        self.other_callback = self.other_body
    def edit(self, account, target, **kwargs):
        return client.get_client(account).edit_message(target, **kwargs)
    def module_edit(self, account, target, **kwargs):
        return client.edit_message(target, account=account, **kwargs)
    def lookup(self, name):
        from hook_utils import find_class
        return find_class(name)
    def reply(self, response, error):
        self.events.append((client.get_hook_account(), response, error))
        if self.mode == "throw": raise ValueError("own user callback failed")
        if self.mode == "stop": raise KeyboardInterrupt("own cancellation signal")
        return {1: object()}
    def request(self, wrapped=False, account=2):
        callback = client.RequestCallback(self.reply, account) if wrapped else self.reply
        return client.send_request({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}, callback, account)
    def direct_delegate(self, response=None, error=None):
        return client.RequestCallback(self.reply, 3).run(response, error)
    def task_body(self):
        self.events.append(("task", client.get_hook_account()))
        return {1: object()}
    def other_body(self): self.events.append(("other", client.get_hook_account()))
    def post(self, queue, other=False):
        return client.get_queue_by_name(queue).postRunnable(self.other_callback if other else self.task_callback)
    def cancel(self, queue):
        return client.get_queue_by_name(queue).cancelRunnable(self.task_callback)
'''


class NativeFailure(RuntimeError):
    pass


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def worker(case, directory, transport, bridge_path=None):
    sys.path.insert(0, str(ROOT / "python"))
    support = load_module("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))

    class Host(support.StrictNativeHost):
        def __init__(self, path):
            super().__init__(path)
            self.requests, self.tasks, self.releases = {}, {}, []
            self.logs, self.cancel_calls = [], []
            self.serial = 0
            self.cancel_result = True
            self.reject_admission = False
            self.permission_failure = False
            self.native_depth = 0
            self.known_classes = {"org.telegram.messenger.UserConfig", "org.telegram.messenger.AndroidUtilities"}
            self.class_result = "normal"
            self.last_id = None
            self.bridge = None

        def identity(self, member):
            self.serial += 1
            self.last_id = member + "-" + str(self.serial)
            return self.last_id

        def module(self):
            module = super().module()
            base, host = module.BridgeBackend, self
            class Backend(base):
                def class_exists(self, name):
                    if host.class_result == "throw": raise NativeFailure("native class metadata owner expired")
                    if host.class_result == "malformed": return 1
                    return name in host.known_classes
            module.BridgeBackend = Backend
            self.bridge = module
            return module

        def call(self, request):
            request = dict(request)
            token = request.pop("ownerToken", None)
            assert token in (None, self.owner_token)
            member, args = request["member"], request["args"]
            # ctypes host-memory access can itself trigger nested SDK audit
            # permission probes. Fail the outer operation under test, not those
            # implementation-only probes (a Swift dispatcher has no Python audit).
            if self.permission_failure and self.native_depth <= 1 and member in ("hasPermission", "isUnsafeMode"):
                raise NativeFailure("native permission owner expired")
            if member == "logEvent": self.logs.append(args[0]); return None
            if member in ("tlRequest", "editMedia", "sendMedia", "postToOwner"):
                assert token == self.owner_token and token is not None
                if self.reject_admission: raise NativeFailure("native admission rejected")
                if member == "postToOwner":
                    callback, delay, queue = args
                    assert type(delay) is int and queue in ("STAGE_QUEUE", "GLOBAL_QUEUE", "UI", "PLUGINS_QUEUE")
                    ident = self.identity(member)
                    self.tasks[ident] = (self.bridge.xt_register_handle(callback), queue)
                    return {"id": ident}
                model, callback = args
                assert model["schemaVersion"] == 1 and type(model["account"]) is int
                if member == "editMedia":
                    assert model["peer"] == {"type": "user", "id": 7}
                    if model["message"].get("namespace", 0) not in (0, 3):
                        raise NativeFailure("native edit namespace rejected")
                ident = self.identity(member)
                self.requests[ident] = (self.bridge.xt_register_handle(callback), model, member)
                return {"requestId": ident}
            if member in ("tlCancel", "cancelOwnerTask"):
                self.cancel_calls.append((member, args[0]))
                if self.cancel_result == "throw": raise NativeFailure("native cancellation failed")
                if type(self.cancel_result) is not bool: return self.cancel_result
                entries = self.requests if member == "tlCancel" else self.tasks
                record = entries.pop(args[0], None) if self.cancel_result else None
                if record: self.releases.append(record[0])
                cancelled = record is not None
                return {"cancelled": cancelled} if member == "tlCancel" else cancelled
            return super().call(request)

        def finish(self, token, response, error=None):
            handle, _, _ = self.requests.pop(token.native_id)
            try:
                return runtime.invoke_handle_json(handle, "run", json.dumps([response, error]))
            finally:
                self.releases.append(handle)

        def fire(self, ident):
            handle, _ = self.tasks.pop(ident)
            try: return runtime.invoke_handle_json(handle, "run", "[]")
            finally: self.releases.append(handle)

        def drain(self):
            ids, self.releases = self.releases, []
            if ids: runtime.release_handles_json(json.dumps(ids))

    support.StrictNativeHost = Host
    detach = lambda: None
    if transport == "unit":
        runtime, host, bridge = support.bootstrap(directory, "sdkCoreRemediation")
    else:
        bridge = load_module("_exteraless_bridge", bridge_path)
        sys.modules["_exteraless_bridge"] = bridge
        import virtualjava
        import exteraless_runtime as runtime
        from exteraless_runtime import _codec, _dependencies
        host = Host(directory)
        host.bridge = bridge
        host.set_plugin_id("sdkCoreRemediation")
        host.set_owner_token("core-native-epoch")
        native_calls, transport_failures = [], []
        class Buffer(ctypes.Structure):
            _fields_ = [("bytes", ctypes.c_void_p), ("count", ctypes.c_size_t)]
        Callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                    ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Buffer))
        library = ctypes.CDLL(str(bridge_path))
        library.EXLPythonBridgeInstallDispatcher.argtypes = [Callback, ctypes.c_void_p, ctypes.c_void_p]
        library.EXLPythonBridgeUninstallDispatcher.argtypes = [Callback, ctypes.c_void_p]
        library.EXLPythonBridgeBufferCopy.argtypes = [ctypes.POINTER(Buffer), ctypes.c_void_p, ctypes.c_size_t]
        def dispatch(context, raw, count, owner, owner_count, reply):
            host.native_depth += 1
            try:
                try:
                    assert count <= 32768
                    assert ctypes.string_at(owner, owner_count).decode() == host.plugin_id
                    request = json.loads(ctypes.string_at(raw, count))
                    assert request.pop("pluginId") == host.plugin_id
                    native_calls.append(request["member"])
                    # BridgeServices accepts these omitted optional envelope
                    # fields; the unit service recorder expects the full shape.
                    for key, default in (("args", []), ("kwargs", {}), ("instance", None), ("value", None)):
                        request.setdefault(key, default)
                    request["args"] = _codec.decode(request["args"], bridge)
                    result = {"ok": True, "value": host.call(request)}
                except (NativeFailure, virtualjava.JavaMemberError) as error:
                    result = {"ok": False, "error": {"kind": "ServiceUnavailable", "message": str(error)}}
                except BaseException as error:
                    transport_failures.append(type(error).__name__ + ": " + str(error)[:300])
                    result = {"ok": False, "error": {"kind": "FixtureFailure", "message": transport_failures[-1]}}
                payload = json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")
                assert len(payload) <= 32768
                return library.EXLPythonBridgeBufferCopy(reply, payload, len(payload))
            finally:
                host.native_depth -= 1
        callback = Callback(dispatch)
        assert library.EXLPythonBridgeInstallDispatcher(callback, None, None) == 0
        def detach(): assert library.EXLPythonBridgeUninstallDispatcher(callback, None) == 0
        manifest = directory / "native-unit-manifest.json"
        manifest.write_text(json.dumps({"classes": {
            "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
            "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
        }}), encoding="utf-8")
        bridge.xt_set_plugin_id(host.plugin_id)
        bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
        virtualjava.install(bridge.BridgeBackend(service="java", manifest_path=str(manifest)))
        _dependencies.create_provider = lambda: _dependencies.ProvidedDependencies({})
        runtime.configure(host.plugin_id, str(host.plugins), str(host.settings))
        bridge.xt_set_owner_token(host.owner_token)

    try:
        from exteraless_runtime import _reflection, RuntimeStateError, UnsupportedSurfaceError
        # Exact coordinator hunk, without editing the shared _platform.py file.
        _reflection.install(runtime._state)
        _reflection.install(runtime._state)  # Idempotence must not duplicate queries.
        runtime.bind_owner_json('"core-native-epoch"')
        path = host.plugins / "sdkCoreRemediation.plugin"
        assert len(PLUGIN.encode()) <= 32768
        path.write_text(PLUGIN, encoding="utf-8")
        runtime.load_json(str(path))
        from extera_utils import plugin_loader as loader
        import android_utils
        import client_utils as client
        from java import jclass
        from virtualjava import finder, get_registered
        from extera_utils.class_aliases import unwrap
        backend = finder._State.backend
        assert type(backend) is bridge.BridgeBackend
        assert android_utils.safe_call.__module__ == "exteraless_runtime._logging"
        plugin = loader.plugins[host.plugin_id].instance
        raises = support.raises
        with loader.plugin_context(host.plugin_id):
            if case == "edit_omission":
                target = {"peer": {"type": "user", "id": 7}, "id": 9, "namespace": 0}
                with client.hook_scope(3):
                    token = plugin.edit(None, target, text="**native**", parse_mode="Markdown")
                model = host.requests[token.native_id][1]
                assert model["account"] == 3 and model["message"] == {"id": 9, "namespace": 0}
                assert model["caption"] == "native" and model["entities"] == [{"_": "messageEntityBold", "offset": 0, "length": 6}]
                assert "spoiler" not in model
                assert host.finish(token, {"status": "edited"}) == "null"
                host.drain()
                for value in (False, True):
                    token = plugin.edit(4, target, text="", with_spoiler=value)
                    model = host.requests[token.native_id][1]
                    assert model["account"] == 4 and model["spoiler"] is value and model["caption"] == ""
                    assert host.finish(token, {"status": "edited"}) == "null"
                    host.drain()
                file = host.files / "own-document.txt"
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("own bounded document", encoding="utf-8")
                token = plugin.edit(2, dict(target, kind="document"), file_path=str(file))
                model = host.requests[token.native_id][1]
                assert model["path"] == str(file.resolve()) and model["kind"] == "document"
                assert {"caption", "entities", "spoiler"}.isdisjoint(model)
                assert host.finish(token, {"status": "edited"}) == "null"
                host.drain()
                token = plugin.module_edit(2, target, text="control")
                assert "spoiler" not in host.requests[token.native_id][1]
                host.finish(token, {"status": "edited"}); host.drain()
                raises(TypeError, lambda: plugin.edit(2, target, with_spoiler=1), "Bool")
                raises(TypeError, lambda: plugin.edit(2, object(), text="bad"), "target")
                raises(Exception, lambda: plugin.edit(2, dict(target, namespace=99), text="bad"), "native edit namespace rejected")
                assert not runtime._state.tl.pending and not runtime._state.callbacks.leases

            elif case == "class_existence":
                queries = []
                def profile(frame, event, arg):
                    if event == "c_call" and getattr(arg, "__self__", None) is backend and getattr(arg, "__name__", None) == "class_exists":
                        queries.append("c.class_exists")
                    elif event == "call" and frame.f_code.co_name == "class_exists" and frame.f_locals.get("self") is backend:
                        queries.append(frame.f_locals.get("name"))
                sys.setprofile(profile)
                try:
                    for name in ("java.lang.Class", "java.util.ArrayList", "org.telegram.tgnet.TLRPC$TL_userEmpty", "[B"):
                        assert unwrap(plugin.lookup(name)) is jclass(name)
                    assert unwrap(plugin.lookup("com.exteragram.messenger.plugins.PluginsController")) is get_registered("app.exteraless.plugins.PluginsController")
                    assert unwrap(plugin.lookup("com.exteragram.messenger.ExteraConfig")) is get_registered("com.exteragram.messenger.ExteraConfig")
                    assert not queries, queries
                    assert plugin.lookup("org.telegram.messenger.CoreApiMissingClass") is None
                    assert len(queries) == 1
                    assert plugin.lookup("com.exteragram.messenger.plugins.CoreApiMissingClass") is None
                    assert len(queries) == 2
                    assert plugin.lookup("org.telegram.messenger.UserConfig") is jclass("org.telegram.messenger.UserConfig")
                    assert len(queries) == 3
                    before = len(queries)
                    assert plugin.lookup("app.exteraless.plugins.PluginServices") is None
                    assert len(queries) == before
                    host.permission_failure = True
                    assert plugin.lookup("org.telegram.messenger.UserConfig") is None
                    assert len(queries) == before, "failed owner/permission guard became existence"
                    host.permission_failure = False
                    if transport == "unit":
                        for mode in ("throw", "malformed"):
                            host.class_result = mode
                            assert plugin.lookup("org.telegram.messenger.UserConfig") is None
                        host.class_result = "normal"
                        name = "org.telegram.messenger.CoreApiLateClass"
                        assert plugin.lookup(name) is None
                        host.known_classes.add(name)
                        assert plugin.lookup(name) is not None
                        host.known_classes.remove(name)
                        assert plugin.lookup(name) is None
                finally:
                    sys.setprofile(None)
                assert jclass("java.lang.Class").forName("java.util.ArrayList").getName() == "java.util.ArrayList"

            elif case == "user_callbacks":
                value = [{"_": "userEmpty", "id": 7}]
                for wrapped in (False, True):
                    plugin.mode = "throw"
                    token = plugin.request(wrapped)
                    handle = host.requests[token.native_id][0]
                    lease = runtime._state.tl.pending[int(token)]
                    before_logs = len(host.logs)
                    assert host.finish(token, value) == "null"
                    assert plugin.events[-1][0] == 2 and plugin.events[-1][1].objects[0].id == 7
                    assert len(host.logs) == before_logs + 1 and host.logs[-1]["phase"] == "sdk.safe_call"
                    assert "own user callback failed" in host.logs[-1]["message"]
                    assert not lease.open and int(token) not in runtime._state.tl.pending
                    assert bridge.xt_resolve_handle(handle) is not None, "Python stole native FIFO release"
                    host.drain(); assert bridge.xt_resolve_handle(handle) is None
                assert plugin.direct_delegate() is None and plugin.events[-1][0] == 3
                plugin.mode = "ok"
                assert plugin.direct_delegate() is None, "void delegate leaked user return"
                token = plugin.request()
                assert host.finish(token, None, {"_": "error", "code": 400, "text": "own RPC error"}) == "null"
                assert plugin.events[-1][2].code == 400
                host.drain()
                before = len(plugin.events)
                token = plugin.request()
                raises(TypeError, lambda: host.finish(token, {"not": "a vector"}), "Vector")
                assert len(plugin.events) == before, "schema error reached user callback"
                host.drain()
                token = plugin.request()
                raises(UnsupportedSurfaceError, lambda: host.finish(token, [{"_": "missingConstructor"}]), "schema")
                host.drain()
                plugin.mode = "stop"
                token = plugin.request(True)
                raises(KeyboardInterrupt, lambda: host.finish(token, value), "own cancellation signal")
                assert not runtime._state.tl.pending and not runtime._state.callbacks.leases
                host.drain()
                raises(KeyboardInterrupt, plugin.direct_delegate, "own cancellation signal")
                plugin.mode = "ok"
                token = plugin.request()
                handle = host.requests[token.native_id][0]
                lease = runtime._state.tl.pending[int(token)]
                lease.close()
                raises(RuntimeStateError, lambda: host.finish(token, value), "closed plugin generation")
                host.drain()
                host.reject_admission = True
                raises(Exception, plugin.request, "native admission rejected")
                host.reject_admission = False
                assert not runtime._state.tl.pending and not runtime._state.callbacks.leases

            elif case == "queue_isolation":
                ids = {}
                for name in (client.STAGE_QUEUE, client.GLOBAL_QUEUE, "UI"):
                    with client.hook_scope(3): assert plugin.post(name) is True
                    ids[name] = host.last_id
                    assert type(host.last_id) is str and runtime._state.scheduler.tasks[host.last_id][0].open
                assert plugin.post(client.STAGE_QUEUE, other=True) is True
                other = host.last_id
                assert plugin.cancel(client.STAGE_QUEUE) is True
                assert host.cancel_calls == [("cancelOwnerTask", ids[client.STAGE_QUEUE])]
                assert set(host.tasks) == {ids[client.GLOBAL_QUEUE], ids["UI"], other}
                host.drain()
                host.cancel_result = False
                global_id = ids[client.GLOBAL_QUEUE]
                lease = runtime._state.scheduler.tasks[global_id][0]
                assert plugin.cancel(client.GLOBAL_QUEUE) is False
                assert runtime._state.scheduler.tasks[global_id][0] is lease and lease.open
                assert host.fire(global_id) == "null" and plugin.events[-1] == ("task", 3)
                host.drain()
                ui_id = ids["UI"]
                lease = runtime._state.scheduler.tasks[ui_id][0]
                host.cancel_result = 1
                raises(RuntimeStateError, lambda: plugin.cancel("UI"), "Bool")
                assert lease.open and ui_id in host.tasks
                host.cancel_result = "throw"
                raises(Exception, lambda: plugin.cancel("UI"), "native cancellation failed")
                assert lease.open and ui_id in host.tasks
                host.cancel_result = True
                assert client.get_queue_by_name(client.STAGE_QUEUE).cancelRunnable(ui_id) is False
                assert host.fire(ui_id) == "null" and host.fire(other) == "null"
                host.drain()
                ident = runtime._state.scheduler.post(plugin.task_callback, client.GLOBAL_QUEUE)
                assert type(ident) is str and runtime._state.scheduler.cancel(ident) is True
                host.drain()
                host.reject_admission = True
                raises(Exception, lambda: plugin.post(client.STAGE_QUEUE), "native admission rejected")
                host.reject_admission = False
                assert not runtime._state.scheduler.tasks and not runtime._state.callbacks.leases

        assert not host.tasks and not host.requests and not host.releases
        runtime.unload()
        assert bridge.xt_handle_count() == 0
        if transport == "c":
            assert type(bridge.xt_call_host) is type(len) and finder._State.backend is backend
            assert not bridge.xt_mock_log() and not transport_failures, transport_failures
            assert all(bridge.xt_service_ptr("java." + op) == 0 for op in ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance"))
        print("SDK_CORE_COUNTEREXAMPLE_OK " + json.dumps({"case": case, "transport": transport, "handles": 0,
              "reflection_install": "coordinator hunk joined in memory", "boundary": "configured SDK; recorded native services; no Swift/UIKit/network"}))
    finally:
        detach()


if __name__ == "__main__":
    worker(sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
else:
    import pytest
    @pytest.mark.parametrize("case", CASES)
    @pytest.mark.parametrize("transport", ("unit", "c"))
    def test_sdk_core_counterexample(case, transport, tmp_path):
        bridge = os.environ.get("EXTERALESS_TL_C_BRIDGE")
        if transport == "c" and not bridge: pytest.skip("Set EXTERALESS_TL_C_BRIDGE to the existing C extension with dispatcher exports")
        args = [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path), transport]
        if transport == "c": args.append(bridge)
        result = subprocess.run(args, cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=30)
        assert result.returncode == 0, (result.stdout + result.stderr)[-6000:]
        assert "SDK_CORE_COUNTEREXAMPLE_OK " in result.stdout
