"""Direct Java and original BasePlugin hooks in configured <=20-second workers.

Only desktop native services are recorders. Optional C mode uses the genuine
BridgeBackend, immutable owner binding, dispatcher ABI and handle operations.
"""

import contextlib
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OWNER = "sdkDirectHooksProbe"
EPOCH = "own-direct-hooks-epoch"
BOUND = 32_768
REQUEST = {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}
USER = {"_": "userEmpty", "id": 7}
UPDATE = {"_": "updateUser", "user_id": 7}
UPDATES = [
    {"_": "updatesTooLong"},
    {"_": "updateShortMessage", "flags": 0, "id": 1, "user_id": 7,
     "message": "fixture", "pts": 3, "pts_count": 1, "date": 4},
    {"_": "updateShortChatMessage", "flags": 0, "id": 1, "from_id": 7, "chat_id": 42,
     "message": "fixture", "pts": 3, "pts_count": 1, "date": 4},
    {"_": "updateShort", "update": UPDATE, "date": 4},
    {"_": "updatesCombined", "updates": [UPDATE], "users": [], "chats": [], "date": 4, "seq_start": 1, "seq": 1},
    {"_": "updates", "updates": [UPDATE], "users": [], "chats": [], "date": 4, "seq": 1},
    {"_": "updateShortSentMessage", "flags": 0, "id": 1, "pts": 3, "pts_count": 1, "date": 4},
]


@contextlib.contextmanager
def configured(directory, bridge_path):
    sys.path.insert(0, str(ROOT / "python"))
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", HERE / "test_ios_runtime.py")
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)

    class Host(support.StrictNativeHost):
        def call(self, request):
            request = dict(request)
            assert request.pop("ownerToken", None) == self.owner_token
            return super().call(request)

    if not bridge_path:
        support.StrictNativeHost = Host
        runtime, host, bridge = support.bootstrap(directory, OWNER)
        runtime.bind_owner_json(json.dumps(EPOCH))
        yield runtime, host, bridge, support.raises, {"transport": "unit"}
        return

    spec = importlib.util.spec_from_file_location("_exteraless_bridge", bridge_path)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    sys.modules["_exteraless_bridge"] = bridge
    import virtualjava
    import exteraless_runtime as runtime
    from exteraless_runtime import _dependencies
    host = Host(directory)
    host.set_plugin_id(OWNER)
    errors = []
    evidence = {"transport": "C-dispatcher", "native_calls": 0, "bootstrap_denials": 0}

    class Buffer(ctypes.Structure):
        _fields_ = [("bytes", ctypes.c_void_p), ("count", ctypes.c_size_t)]

    Dispatch = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Buffer))
    library = ctypes.CDLL(str(bridge_path))
    library.EXLPythonBridgeInstallDispatcher.argtypes = [Dispatch, ctypes.c_void_p, ctypes.c_void_p]
    library.EXLPythonBridgeUninstallDispatcher.argtypes = [Dispatch, ctypes.c_void_p]
    library.EXLPythonBridgeBufferCopy.argtypes = [ctypes.POINTER(Buffer), ctypes.c_void_p, ctypes.c_size_t]
    bootstrap = {"getPluginsDir", "getFilesDir", "getCacheDir", "getVersion", "getProtectedPaths", "log", "hasPermission", "isUnsafeMode"}

    def dispatch(context, request, request_count, owner, owner_count, response):
        try:
            assert request_count <= BOUND and threading.get_ident() == host.thread
            assert ctypes.string_at(owner, owner_count).decode("utf-8") == OWNER
            model = json.loads(ctypes.string_at(request, request_count))
            assert model.pop("pluginId") == OWNER
            assert model.get("ownerToken") == host.owner_token
            evidence["native_calls"] += 1
            if host.owner_token is None and (model["fqcn"] != "exteraless.ios.Runtime" or model["member"] not in bootstrap):
                evidence["bootstrap_denials"] += 1
                reply = {"ok": False, "error": {"kind": "SecurityError", "message": "Native interpreter owner expired or missing"}}
            else:
                try:
                    if model["op"] == "member_kind":
                        value = "field" if (model["fqcn"], model["member"]) == ("org.telegram.messenger.UserConfig", "selectedAccount") else "unknown"
                    else:
                        value = host.call(model)
                    reply = {"ok": True, "value": value}
                except virtualjava.JavaMemberError as error:
                    reply = {"ok": False, "error": {"kind": "Unimplemented", "message": str(error)}}
        except BaseException as error:
            errors.append(type(error).__name__ + ": " + str(error)[:300])
            reply = {"ok": False, "error": {"kind": "FixtureFailure", "message": errors[-1]}}
        raw = json.dumps(reply, allow_nan=False).encode("utf-8")
        assert len(raw) <= BOUND
        return library.EXLPythonBridgeBufferCopy(response, raw, len(raw))

    callback = Dispatch(dispatch)
    assert library.EXLPythonBridgeInstallDispatcher(callback, None, None) == 0
    try:
        manifest = directory / "direct-hooks-manifest.json"
        manifest.write_text(json.dumps({"classes": {
            "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
            "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
        }}), encoding="utf-8")
        bridge.xt_set_plugin_id(OWNER)
        bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
        backend = bridge.BridgeBackend(service="java", manifest_path=str(manifest))
        virtualjava.install(backend)
        _dependencies.create_provider = lambda: _dependencies.ProvidedDependencies({})
        runtime.configure(OWNER, str(host.plugins), str(host.settings))
        bridge.xt_set_owner_token(EPOCH)
        host.set_owner_token(EPOCH)
        runtime.bind_owner_json(json.dumps(EPOCH))
        assert virtualjava.finder._State.backend is backend
        assert type(bridge.xt_call_host) is type(len)
        yield runtime, host, bridge, support.raises, evidence
        assert not errors and not bridge.xt_mock_log(), errors
        assert all(bridge.xt_service_ptr("java." + op) == 0 for op in (
            "construct", "call", "call_instance", "get", "get_instance", "set", "set_instance"))
    finally:
        assert library.EXLPythonBridgeUninstallDispatcher(callback, None) == 0


def worker(directory, bridge_path=None):
    with configured(directory, bridge_path) as (runtime, host, bridge, raises, evidence):
        from base_plugin import BasePlugin
        from extera_utils import plugin_loader as loader
        from exteraless_runtime import RuntimeStateError
        from exteraless_runtime._hook_registrations import send_priority
        from java import jclass
        facade = jclass("app.exteraless.plugins.PythonBridge")
        base_add = BasePlugin.add_hook
        assert Path(base_add.__code__.co_filename).resolve() == ROOT / "python/sdk/base_plugin.py"
        host.permissions = {"ui", "messages.read", "messages.send"}
        if bridge_path:
            # The desktop host recorder itself uses ctypes for the dispatcher
            # ABI. Xposed/hooks remains denied in both transports.
            host.permissions.add("native")
        raises(RuntimeStateError, lambda: facade.addRequestHook(OWNER, "users.getUsers", False, 1), "inactive")
        path = host.plugins / "owner.plugin"
        shutil.copyfile(HERE / "fixtures/sdk_direct_hooks/owner.plugin", path)
        loaded = json.loads(runtime.load_json(str(path)))
        assert all(loaded["handles"][name] for name in ("app_event", "pre_request", "post_request", "update", "updates", "send_message"))
        record = loader.plugins[OWNER]
        plugin = record.instance
        ledger = plugin.__dict__["_exteraless_request_hooks"]
        schema = runtime._state.tl.schema
        admitted = 0

        def command(target, method, *args):
            plugin.command = (target, method, (OWNER, *args) if target == "direct" else args)
            assert runtime.dispatch_json("on_app_event", '{"event_type":"app_resume"}') == "null"
            assert loader.plugins[OWNER] is record and host.value("loads") == 1
            assert plugin.__dict__["_exteraless_request_hooks"] is ledger

        def add(name, substring=False, priority=0, *, base=False):
            command("base" if base else "direct", "add_hook" if base else "addRequestHook", name, substring, priority)

        def remove(name, *, base=False):
            command("base" if base else "direct", "remove_hook" if base else "removeRequestHook", name)

        def priority(hook, name, canonical=None):
            canonical = canonical or schema.canonical_name(name)
            return json.loads(runtime.hook_priority_json(hook, name, canonical))

        def invoke(hook, name, value, count=1):
            nonlocal admitted
            field, name_field = {"pre_request_hook": ("request", "request_name"),
                "post_request_hook": ("response", "request_name"), "on_update_hook": ("update", "update_name"),
                "on_updates_hook": ("updates", "container_name"), "on_send_message_hook": ("params", None)}[hook]
            if name_field is None:
                payload = {"account": 2, field: value}
            else:
                wire_name = next(iter(schema.hook_names(name)), name)
                payload = {"account": 2, name_field: wire_name, "canonical_name": name, field: {
                    "schemaVersion": 1, "observational": False, "canCancel": True, "tl": value,
                    "metadata": {"fixture": "direct-hooks", "requestName": name, "nested": [1, 2]}}}
            raw = json.dumps(payload)
            assert len(raw.encode("utf-8")) <= BOUND
            before = len(plugin.events)
            result = runtime.dispatch_json(hook, raw)
            assert len(result.encode("utf-8")) <= BOUND
            assert json.loads(result) == {"strategy": "DEFAULT", field: value}
            assert len(plugin.events) == before + count, (hook, name, plugin.events[before:])
            if count:
                assert host.value("invocations") == len(plugin.events)
                admitted += 1

        # Warm the actual query/dispatch path before late registration. There is
        # one load and one SDK instance throughout all registration scenarios.
        assert priority("pre_request_hook", "TL_users_getUsers") is None
        invoke("pre_request_hook", "users.getUsers", REQUEST, 0)
        add("TL_users_getUsers", priority=3)
        assert priority("pre_request_hook", "TL_users_getUsers") == 3
        invoke("pre_request_hook", "users.getUsers", REQUEST)
        invoke("post_request_hook", "users.getUsers", [USER])
        remove("TL_users_getUsers", base=True)
        invoke("pre_request_hook", "users.getUsers", REQUEST, 0)

        # BasePlugin's pre-delegate bookkeeping and repeated direct calls must
        # join one target, including exact+substring and overlapping names.
        add("TL_users_getUsers", priority=5, base=True)
        add("TL_users_getUsers", priority=5, base=True)
        add("TL_users_getUsers", priority=2)
        add("getUsers", True, 11)
        add("users.getUsers", priority=7)
        assert priority("post_request_hook", "TL_users_getUsers") == 11
        invoke("pre_request_hook", "users.getUsers", REQUEST)
        remove("getUsers")
        assert priority("pre_request_hook", "TL_users_getUsers") == 7
        remove("users.getUsers")
        assert priority("pre_request_hook", "TL_users_getUsers") == 5
        remove("TL_users_getUsers")
        assert priority("pre_request_hook", "TL_users_getUsers") is None
        invoke("pre_request_hook", "users.getUsers", REQUEST, 0)

        # A key's maximum is shared across its matching modes. Here the exact
        # registration cannot match updateShortMessage; its substring can.
        add("TL_updateShort", priority=23)
        add("TL_updateShort", True, -4, base=True)
        assert priority("on_updates_hook", "TL_updateShortMessage") == 23
        invoke("on_updates_hook", "updateShortMessage", UPDATES[1])
        add("TL_updateShort", priority=2, base=True)
        assert priority("on_updates_hook", "TL_updateShortMessage") == 23
        remove("TL_updateShort")
        assert priority("on_updates_hook", "TL_updateShortMessage") is None
        invoke("on_updates_hook", "updateShortMessage", UPDATES[1], 0)
        add("TL_updateShort", True, -9)
        assert priority("on_updates_hook", "TL_updateShortMessage") == -9
        remove("TL_updateShort", base=True)
        for value in (-2 ** 31, 2 ** 31 - 1):
            add("users.getUsers", priority=value)
            assert priority("pre_request_hook", "TL_users_getUsers") == value
            remove("users.getUsers")
        raises(ValueError, lambda: facade.addRequestHook(OWNER, "users.getUsers", False, 2 ** 31), "Int32")
        facade.addRequestHook(OWNER, "", False, 9)
        facade.addRequestHook(OWNER, None, False, 9)
        assert not ledger

        # Exact groups and the shared substring registry cover all seven native
        # Updates constructors. "all" is an ordinary exact key in the original.
        add("all")
        assert priority("on_updates_hook", "TL_updates") is None
        remove("all")
        add("TL_updateUser", priority=6, base=True)
        assert priority("on_update_hook", "TL_updateUser") == 6
        assert priority("on_updates_hook", "TL_updateUser") is None
        assert priority("pre_request_hook", "TL_updateUser") is None
        invoke("on_update_hook", "updateUser", UPDATE)
        remove("TL_updateUser")
        assert {item["_"] for item in UPDATES} == {name for name, definition in schema.definitions.items()
            if definition["type"] == "Updates" and name not in schema.method_names}
        for index, updates in enumerate(UPDATES):
            name = updates["_"]
            alias = schema.hook_names(name)[0]
            add(alias, priority=index + 1, base=bool(index % 2))
            assert priority("on_updates_hook", alias) == index + 1
            assert priority("on_update_hook", alias) is None
            assert priority("pre_request_hook", alias) is None
            invoke("on_updates_hook", name, updates)
            remove(alias)
            invoke("on_updates_hook", name, updates, 0)
        add("TL_update", True, 4)
        invoke("on_update_hook", "updateUser", UPDATE)
        for updates in UPDATES:
            invoke("on_updates_hook", updates["_"], updates)
        remove("TL_update")
        invoke("on_update_hook", "updateUser", UPDATE, 0)

        # The send flag is the same BasePlugin flag; last add wins its priority.
        # Native consumption of send_priority has a separate coordinator hunk.
        params = {"message": "fixture", "peer": 42}
        invoke("on_send_message_hook", None, params, 0)
        command("direct", "addSendMessageHook", 100)
        command("direct", "addSendMessageHook", 100)
        assert send_priority(plugin) == 100
        invoke("on_send_message_hook", None, params)
        command("base", "add_on_send_message_hook", -100)
        command("base", "add_on_send_message_hook", -100)
        assert send_priority(plugin) == -100
        invoke("on_send_message_hook", None, params)
        for bad in (True, "100", 1.5, 2 ** 31):
            plugin.__dict__["_exteraless_send_message_priority"] = bad
            raises(ValueError, lambda: send_priority(plugin), "Int32")
        command("direct", "removeSendMessageHook")
        assert send_priority(plugin) is None
        invoke("on_send_message_hook", None, params, 0)
        command("direct", "addSendMessageHook", 2)
        command("base", "remove_hook", "on_send_message_hook")
        invoke("on_send_message_hook", None, params, 0)

        add("users.getUsers", priority=13, base=True)
        command("base", "add_on_send_message_hook", 100)
        for operation in (
            lambda: facade.addRequestHook("foreign", "users.getUsers", False, 1),
            lambda: facade.removeRequestHook("foreign", "users.getUsers"),
            lambda: facade.addSendMessageHook("foreign", 1),
            lambda: facade.removeSendMessageHook("foreign"),
        ):
            raises(RuntimeStateError, operation, "worker belongs")
        errors = []

        def wrong_worker():
            try:
                facade.addRequestHook(OWNER, "users.getUsers", False, 1)
            except RuntimeStateError as error:
                errors.append(str(error))

        thread = threading.Thread(target=wrong_worker)
        thread.start(); thread.join(timeout=2)
        assert not thread.is_alive() and len(errors) == 1 and "owner worker" in errors[0]
        assert priority("pre_request_hook", "TL_users_getUsers") == 13
        assert send_priority(plugin) == 100
        invoke("pre_request_hook", "users.getUsers", REQUEST)
        invoke("on_send_message_hook", None, params)
        remove("users.getUsers")
        command("direct", "removeSendMessageHook")
        assert not ledger and send_priority(plugin) is None
        if bridge_path:
            raises(RuntimeError, lambda: bridge.xt_set_plugin_id("foreign"))
            raises(RuntimeError, lambda: bridge.xt_set_owner_token("foreign-epoch"))

        # An actual leased callback can register late. Its saved wrapper and C
        # handle cannot register into the next load after generation retirement.
        lease = runtime._state.callbacks.new("direct-hooks-fixture")
        stale = lease.wrap(plugin.register_from_callback)
        handle = lease.handles[0]
        assert runtime.invoke_handle_json(handle, "run", "[]") == "null"
        assert priority("pre_request_hook", "TL_users_getUsers") == 17
        invoke("pre_request_hook", "users.getUsers", REQUEST)
        assert BasePlugin.add_hook is base_add and host.value("loads") == 1
        evidence.update({"admitted_once": admitted, "updates_constructors": len(UPDATES), "loads_before_retirement": 1})
        runtime.unload()
        assert not ledger and bridge.xt_handle_count() == 0
        for operation in (
            lambda: facade.addRequestHook(OWNER, "users.getUsers", False, 1),
            lambda: facade.removeRequestHook(OWNER, "users.getUsers"),
            lambda: facade.addSendMessageHook(OWNER, 1),
            lambda: facade.removeSendMessageHook(OWNER),
        ):
            raises(RuntimeStateError, operation, "inactive")
        runtime.load_json(str(path))
        raises(RuntimeStateError, stale, "closed plugin generation")
        raises(LookupError, lambda: runtime.invoke_handle_json(handle, "run", "[]"), "unknown callback")
        assert priority("pre_request_hook", "TL_users_getUsers") is None
        assert not loader.plugins[OWNER].instance.events
        runtime.unload()
        assert bridge.xt_handle_count() == 0
        evidence.update({"ok": True, "python": sys.version.split()[0], "handles_after_unload": 0})
    print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    worker(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) > 2 else None)
elif __name__ != "_direct_hook_fixture_support":
    import pytest

    @pytest.mark.parametrize("transport", ["unit", "C-dispatcher"])
    def test_direct_hook_registration(transport, tmp_path):
        bridge = os.environ.get("EXTERALESS_DIRECT_HOOK_C_BRIDGE") if transport == "C-dispatcher" else None
        if transport == "C-dispatcher" and not bridge:
            pytest.skip("Set EXTERALESS_DIRECT_HOOK_C_BRIDGE to a C extension with dispatcher ABI exports")
        command = [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), str(tmp_path)]
        if bridge: command.append(bridge)
        result = subprocess.run(command, cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=20)
        assert result.returncode == 0, (result.stdout + result.stderr)[-8000:]
        print(result.stdout.strip())
