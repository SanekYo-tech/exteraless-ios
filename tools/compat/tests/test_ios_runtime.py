"""Small SDK/adapter unit tests; native services alone are strict test doubles.

Each case has its own -I -S import scope/process and a hard 20-second timeout.
No downloaded plugins, runtime simulator, C extension or network is required.
"""

import gc
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import types
import weakref


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).parent / "fixtures" / "ios_runtime"
CASES = ("metadata", "lifecycle_settings", "settings_account_scope", "hooks", "load_errors", "cleanup", "bootstrap", "requirements", "permissions", "callback_cleanup", "audit_paths", "audit_paths_frozen", "audit_layout")


class StrictNativeHost:
    """Only the documented native service envelope and handle ownership exist."""

    def __init__(self, directory):
        self.root = directory
        self.plugins = directory / "plugins"
        self.settings = directory / "settings"
        self.plugins.mkdir(parents=True)
        self.settings.mkdir()
        self.plugin_id = None
        self.owner_token = None
        self.thread = threading.get_ident()
        self.storage = {}
        self.handles = {}
        self.next_handle = 1
        self.queued = []
        self.pending_callbacks = {}
        self.calls = []
        self.fail_writes = False
        self.clear_count = 0
        self.bound = None
        self.settings_reloads = 0
        self.permissions = {"ui", "messages.read", "messages.send", "network", "files", "intents", "settings", "hooks", "native"}

    def register(self, value):
        for handle, existing in self.handles.items():
            if existing is value:
                return handle
        handle = self.next_handle
        self.next_handle += 1
        self.handles[handle] = value
        return handle

    def clear(self):
        self.handles.clear()
        self.clear_count += 1

    def set_plugin_id(self, plugin_id):
        assert threading.get_ident() == self.thread
        assert isinstance(plugin_id, str) and plugin_id
        assert self.plugin_id in (None, plugin_id)
        self.plugin_id = plugin_id

    def set_owner_token(self, token):
        if self.plugin_id is None: raise RuntimeError("plugin id must be bound first")
        if not isinstance(token, str): raise TypeError("owner token must be str")
        if not 0 < len(token.encode("utf-8")) <= 256 or "\0" in token: raise ValueError("invalid owner token")
        if self.owner_token not in (None, token): raise RuntimeError("native owner token is immutable")
        self.owner_token = token

    def transport(self, request):
        request = dict(request)
        request.pop("ownerToken", None)
        if self.owner_token is not None: request["ownerToken"] = self.owner_token
        return self.call(request)

    def bind(self, instance_class, error_class):
        self.bound = (instance_class, error_class)

    def value(self, key):
        return self.storage.get((self.plugin_id, key))

    def seed(self, key, value):
        self.storage[(self.plugin_id, key)] = value

    @property
    def files(self):
        return self.root / "files" / self.plugin_id

    @property
    def cache(self):
        return self.root / "cache" / self.plugin_id

    def call(self, request):
        from virtualjava import JavaMemberError
        assert threading.get_ident() == self.thread
        assert set(request) == {"op", "fqcn", "member", "args", "kwargs", "instance", "value"}
        assert request["kwargs"] == {} and request["instance"] is None and request["value"] is None
        assert isinstance(request["args"], list)
        fqcn, member, args = request["fqcn"], request["member"], request["args"]
        loader = sys.modules.get("extera_utils.plugin_loader")
        context = loader.current_plugin_id() if loader is not None and hasattr(loader, "current_plugin_id") else None
        # Do not retain callback objects in the diagnostic log.
        self.calls.append((request["op"], fqcn, member,
                           ["<callback>" if callable(arg) else arg for arg in args], context))
        if fqcn == "org.telegram.messenger.AndroidUtilities" and member == "runOnUIThread":
            assert request["op"] == "call" and len(args) == 2
            assert self.plugin_id == context and callable(args[0]) and type(args[1]) is int
            handle = self.register(args[0])
            self.pending_callbacks[handle] = self.pending_callbacks.get(handle, 0) + 1
            self.queued.append((handle, args[1]))
            return None
        if fqcn == "org.telegram.messenger.UserConfig" and member == "selectedAccount":
            assert request["op"] == "get" and not args
            return 2
        if fqcn != "exteraless.ios.Runtime":
            raise JavaMemberError(f"strict fixture has no {fqcn}#{member}")
        assert self.plugin_id is not None and request["op"] == "call"
        arities = {"getSetting": 2, "setSetting": 2, "removeSetting": 1,
                   "getSettings": 0, "setSettings": 1, "updateSettings": 1, "clearSettings": 0, "uiRefreshSettings": 0, "getProtectedPaths": 0,
                   "getPluginsDir": 0, "getFilesDir": 0, "getCacheDir": 0,
                   "log": 1, "getVersion": 0, "completeCallback": 1,
                   "hasPermission": 1, "isUnsafeMode": 0}
        if member not in arities:
            raise JavaMemberError(f"strict fixture has no Runtime.{member}")
        assert len(args) == arities[member], (member, args)
        if member in ("getSetting", "setSetting", "removeSetting"):
            assert isinstance(args[0], str)
            key = (self.plugin_id, args[0])
        if member == "getSetting":
            return json.loads(json.dumps(self.storage.get(key, args[1]), allow_nan=False))
        if member == "getSettings":
            return json.dumps({key: value for (owner, key), value in self.storage.items() if owner == self.plugin_id})
        if member == "getProtectedPaths": return []
        if member in ("setSettings", "updateSettings", "clearSettings"):
            if self.fail_writes: raise RuntimeError("strict fixture storage write failed")
            values = {} if member == "clearSettings" else json.loads(args[0])
            assert isinstance(values, dict)
            if member in ("setSettings", "clearSettings"):
                self.storage = {key: value for key, value in self.storage.items() if key[0] != self.plugin_id}
            self.storage.update({(self.plugin_id, key): value for key, value in values.items()})
            return None
        if member == "uiRefreshSettings":
            self.settings_reloads += 1
            return None
        if member == "setSetting":
            json.dumps(args[1], allow_nan=False)
            if self.fail_writes:
                raise RuntimeError("strict fixture storage write failed")
            self.storage[key] = json.loads(json.dumps(args[1]))
        elif member == "removeSetting":
            existed = key in self.storage
            self.storage.pop(key, None)
            return existed
        elif member == "getPluginsDir":
            return str(self.plugins)
        elif member == "getFilesDir":
            self.files.mkdir(parents=True, exist_ok=True)
            return str(self.files)
        elif member == "getCacheDir":
            self.cache.mkdir(parents=True, exist_ok=True)
            return str(self.cache)
        elif member == "getVersion":
            return "13.1.1-fixture"
        elif member == "hasPermission":
            assert isinstance(args[0], str)
            return args[0] in self.permissions
        elif member == "isUnsafeMode":
            return False
        elif member == "completeCallback":
            assert type(args[0]) is int and args[0] > 0
            count = self.pending_callbacks.get(args[0], 0)
            if count > 1:
                self.pending_callbacks[args[0]] = count - 1
                return False
            if count == 1:
                del self.pending_callbacks[args[0]]
                return True
            return False
        elif member == "log":
            assert isinstance(args[0], str)
        return None

    def module(self):
        import virtualjava
        host = self

        class StrictBridgeBackend(virtualjava.Backend):
            def __init__(self, service, manifest_path):
                assert service == "java" and Path(manifest_path).is_absolute()
                self.manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))

            def member_kind(self, fqcn, member):
                fields = self.manifest["classes"].get(fqcn, {}).get("declared", {}).get("fields", [])
                return "field" if member in fields else "method"

            def class_exists(self, fqcn):
                return fqcn in self.manifest["classes"]

            def call(self, fqcn, member, args, kwargs):
                return host.transport({"op": "call", "fqcn": fqcn, "member": member,
                                  "args": list(args), "kwargs": kwargs, "instance": None, "value": None})

            def get(self, fqcn, member):
                return host.transport({"op": "get", "fqcn": fqcn, "member": member,
                                  "args": [], "kwargs": {}, "instance": None, "value": None})

        module = types.ModuleType("_exteraless_bridge")
        module.BridgeBackend = StrictBridgeBackend
        module.xt_bind = self.bind
        module.xt_set_plugin_id = self.set_plugin_id
        module.xt_set_owner_token = self.set_owner_token
        module.xt_call_host = self.transport
        module.xt_register_handle = self.register
        module.xt_resolve_handle = self.handles.get
        module.xt_release_handle = lambda handle: self.handles.pop(handle, None) is not None
        module.xt_clear_handles = self.clear
        module.xt_handle_count = lambda: len(self.handles)
        return module


def bootstrap(directory, plugin_id="ios_runtime_probe", configure=True, dependency_provider=None, real_dependencies=False):
    import virtualjava
    import exteraless_runtime as runtime
    from exteraless_runtime import _dependencies
    # Keep SDK unit workers independent of an optional real bundle staged by a
    # concurrent build. Bundle discovery/path validation has its own data-only tests.
    if not real_dependencies:
        provider = dependency_provider or _dependencies.ProvidedDependencies({})
        _dependencies.create_provider = lambda: provider
    host = StrictNativeHost(directory)
    bridge = host.module()
    sys.modules["_exteraless_bridge"] = bridge
    manifest = directory / "native-unit-manifest.json"
    manifest.write_text(json.dumps({"classes": {
        "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
        "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
    }}), encoding="utf-8")
    bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
    backend = bridge.BridgeBackend(service="java", manifest_path=str(manifest))
    virtualjava.install(backend)
    if configure:
        runtime.configure(plugin_id, str(host.plugins), str(host.settings))
    assert virtualjava.finder._State.backend is backend
    assert host.bound == (virtualjava.JavaInstance, virtualjava.JavaMemberError)
    return runtime, host, bridge


def copy_fixture(host, name):
    destination = host.plugins / (name + ".plugin")
    shutil.copyfile(FIXTURES / (name + ".plugin"), destination)
    return str(destination)


def raises(error_type, operation, contains=None):
    try:
        operation()
    except error_type as error:
        if contains is not None:
            assert contains in str(error), str(error)
        return error
    raise AssertionError(f"did not raise {error_type.__name__}")


def case_metadata(directory):
    import exteraless_runtime as runtime
    meta = json.loads(runtime.metadata_json(str(FIXTURES / "metadata.plugin")))
    assert meta["id"] == "ios_metadata_probe" and meta["version"] == "1.0"
    assert meta["name"] == "Metadata without execution"
    assert "ios_metadata_probe" not in sys.modules
    assert "extera_utils.plugin_loader" not in sys.modules
    assert "_exteraless_bridge" not in sys.modules
    raises(runtime.RuntimeStateError, lambda: runtime.load_json(str(FIXTURES / "metadata.plugin")))
    raises(runtime.UnsupportedSurfaceError, lambda: runtime.metadata_json("example.zip"))
    malformed = directory / "malformed.plugin"
    malformed.write_text("__id__ = 'bad_probe'\n__name__ = 'bad'\nif :\n", encoding="utf-8")
    from extera_utils.metadata_parser import PluginMetadataError
    raises(PluginMetadataError, lambda: runtime.metadata_json(str(malformed)), "syntax error")
    return None


def case_lifecycle_settings(directory):
    runtime, host, bridge = bootstrap(directory)
    path = copy_fixture(host, "lifecycle")
    loaded = json.loads(runtime.load_json(path))
    from extera_utils import plugin_loader as loader
    from base_plugin import BasePlugin
    import plugin_settings
    import client_utils
    import file_utils
    record = loader.plugins[host.plugin_id]
    instance = record.instance
    assert isinstance(instance, BasePlugin) and instance.id == host.plugin_id
    assert len(loader.plugins) == 1 and loader.is_loaded(host.plugin_id)
    assert loaded["metadata"]["version"] == "1.2" and loaded["has_settings"] is True
    assert set(loaded["handles"]) == {"app_event", "pre_request", "post_request", "update", "updates", "send_message"}
    assert all(loaded["handles"].values())
    assert Path(instance.directory).is_dir() and Path(instance.files) == host.files
    assert Path(file_utils.get_cache_dir()) == host.cache
    assert instance.events == [("load", host.plugin_id, None)]
    assert host.value("loads") == 1 and len(host.queued) == 1
    assert os.path.normcase(path) in loader._owner_files
    assert Path(loader.load_plugin.__code__.co_filename).resolve() == ROOT / "python/sdk/extera_utils/plugin_loader.py"
    assert Path(BasePlugin.add_hook.__code__.co_filename).resolve() == ROOT / "python/sdk/base_plugin.py"

    rows = json.loads(runtime.settings_json())
    assert [row["type"] for row in rows] == ["header", "switch", "input", "text", "divider"]
    assert rows[1]["value"] is True and rows[2]["value"] == "iOS"
    assert all("row_id" in row for row in rows)
    assert set(record.change_callbacks) == {"enabled", "prefix"}
    assert runtime.setting_changed_json("enabled", "false") == "null"
    assert host.value("enabled") is False and host.value("changed_enabled") is False
    assert runtime.setting_changed_json("prefix", json.dumps("Привет")) == "null"
    assert host.value("changed_prefix") == "Привет"
    assert runtime.setting_click_json(rows[3]["callback_id"]) == "null"
    assert host.value("clicks") == 1
    runtime.setting_click_json(rows[3]["long_callback_id"])
    raises(LookupError, lambda: runtime.setting_click_json("stale"))
    raises(ValueError, lambda: runtime.setting_changed_json("enabled", "not-json"))

    with loader.plugin_context(host.plugin_id):
        plugin_settings.set_setting(host.plugin_id, "enabled", True)
        assert instance.get_setting("enabled", False) is True
        plugin_settings.remove_setting(host.plugin_id, "enabled")
        assert instance.get_setting("enabled", "missing") == "missing"
        instance.set_setting("nullable", None)
        assert instance.get_setting("nullable", "fallback") is None
        instance.set_setting("coerced", "off")
        assert instance.get_setting("coerced", True) is False
        assert instance.get_setting("missing", 1) == 1
        assert instance.get_setting("missing", 2) == 2
        instance.set_setting("reload", True, reload_settings=True)
        assert host.value("reload") is True and host.settings_reloads == 1
    before = len(instance.events)
    host.fail_writes = True
    raises(RuntimeError, lambda: runtime.setting_changed_json("enabled", "false"), "storage write failed")
    assert len(instance.events) == before and host.value("enabled") is None
    host.fail_writes = False

    handle, delay = host.queued[0]
    assert delay == 5
    # BridgeServices' Runnable is void, while its user callback still executes in
    # exactly the same SDK/owner context. Explicit result callbacks below retain JSON.
    assert runtime.invoke_handle_json(handle, "run", "[]") == "null"
    assert instance.events[-1] == ("native", host.plugin_id, None)
    assert host.value("native_seen") == host.plugin_id
    assert bridge.xt_resolve_handle(handle) is None and handle not in host.pending_callbacks
    raises(LookupError, lambda: runtime.invoke_handle_json(999999, "run", "[]"))
    object_handle = bridge.xt_register_handle(instance)
    returned = {"plugin": host.plugin_id, "account": None}
    assert json.loads(runtime.invoke_handle_json(object_handle, "echo", json.dumps([returned]))) == returned
    assert runtime.invoke_handle_json(object_handle, "clicked", "[]") == "null"
    assert host.value("clicks") == 2
    marker = {"__handle__": object_handle, "__fqcn__": None, "__fqcn": None}
    assert json.loads(runtime.invoke_handle_json(object_handle, "echo", json.dumps([marker]))) == {
        "__handle__": object_handle, "__fqcn__": None}
    raises(LookupError, lambda: runtime.invoke_handle_json(
        object_handle, "echo", '[{"__handle__":-123,"__fqcn__":"unknown.Native"}]'))
    raises(TypeError, lambda: runtime.invoke_handle_json(object_handle, "clicked", "{}"))
    assert loader.current_plugin_id() is None and client_utils.get_hook_account() is None

    weak = weakref.ref(instance)
    module_name = record.module_name
    runtime.unload()
    assert host.value("unloads") == 1
    assert not record.change_callbacks and not record.click_callbacks and not record.custom_views
    assert not instance._exteraless_request_hooks and not instance._exteraless_send_message_registered
    assert not loader.plugins and not bridge.xt_handle_count() and module_name not in sys.modules
    assert not loader._owner_files
    del record, instance
    gc.collect()
    assert weak() is None, "unload retained the plugin through callback refs"
    runtime.unload()
    assert host.value("unloads") == 1
    raises(runtime.RuntimeStateError, lambda: runtime.setting_click_json(rows[3]["callback_id"]))
    return host


def case_settings_account_scope(directory):
    runtime, host, bridge = bootstrap(directory)
    path = copy_fixture(host, "lifecycle")
    runtime.load_json(path)
    from extera_utils import plugin_loader as loader
    import client_utils
    record = loader.plugins[host.plugin_id]
    rows = json.loads(runtime.settings_json())
    callback = rows[3]["callback_id"]
    before_calls = len(host.calls)
    assert runtime.setting_changed_json("enabled", "false", 4) == "null"
    assert record.instance.events[-1] == ("change", host.plugin_id, 4)
    assert host.value("enabled") is False and host.value("changed_enabled") is False
    assert runtime.setting_click_json(callback, 4) == "null"
    assert record.instance.events[-1] == ("click", host.plugin_id, 4)
    assert not any(call[2] == "selectedAccount" for call in host.calls[before_calls:]), "captured settings account was retargeted"
    before = dict(host.storage), list(record.instance.events)
    for account in (True, False, -1, 2 ** 31, 4.0, "4"):
        raises(ValueError, lambda: runtime.setting_changed_json("enabled", "true", account), "Int32")
        raises(ValueError, lambda: runtime.setting_click_json(callback, account), "Int32")
    assert (host.storage, record.instance.events) == before
    # Old arities still enter the original unbound scope; they never reuse the
    # previous numeric account from an earlier invocation.
    runtime.setting_changed_json("enabled", "true")
    assert record.instance.events[-1] == ("change", host.plugin_id, None)
    runtime.setting_click_json(callback)
    assert record.instance.events[-1] == ("click", host.plugin_id, None)
    assert client_utils.get_hook_account() is None and loader.current_plugin_id() is None
    runtime.unload()
    assert bridge.xt_handle_count() == 0
    return host


def case_hooks(directory):
    runtime, host, bridge = bootstrap(directory)
    runtime.load_json(copy_fixture(host, "lifecycle"))
    from extera_utils import plugin_loader as loader
    import client_utils
    instance = loader.plugins[host.plugin_id].instance

    def dispatch(hook, **payload):
        return json.loads(runtime.dispatch_json(hook, json.dumps(payload)))

    for event in ("start", "pause", "resume", "stop"):
        assert dispatch("on_app_event", event_type="app_" + event) is None
        assert host.value("app_event") == event.upper()
    raises(ValueError, lambda: dispatch("on_app_event", event_type="unknown"))
    assert dispatch("pre_request_hook", account=7, request_name="TL_echo", request={"text": "ok"}) == {
        "strategy": "MODIFY", "request": {"text": "ok", "visited": 7}}
    assert dispatch("pre_request_hook", account=7, request_name="TL_other", request={}) == {
        "strategy": "DEFAULT", "request": {}}
    assert dispatch("post_request_hook", account=7, request_name="TL_echo", response=None, error="fail")["strategy"] == "CANCEL"
    dispatch("on_update_hook", account=7, update_name="TL_updateLocal", update={"value": 1})
    dispatch("on_updates_hook", account=7, container_name="TL_updates", updates=[{"value": 1}])
    for phase in ("pre", "post", "update", "updates"):
        assert (phase, host.plugin_id, 7) in instance.events
    result = dispatch("on_send_message_hook", account=7, params={"message": "hello", "peer": 42})
    assert result == {"strategy": "MODIFY", "params": {"message": "iOS: hello", "peer": 42}}
    assert dispatch("on_send_message_hook", account=7, params={"message": "/cancel"})["strategy"] == "CANCEL"
    assert dispatch("on_send_message_hook", account=7, params={"message": "/final"})["strategy"] == "MODIFY_FINAL"
    assert dispatch("on_send_message_hook", account=7, params={"message": "/default"})["strategy"] == "DEFAULT"
    raises(ValueError, lambda: dispatch("on_send_message_hook", account=7, params={"message": "/throw"}), "fixture hook failure")
    assert loader.current_plugin_id() is None and client_utils.get_hook_account() is None
    raises(ValueError, lambda: dispatch("on_send_message_hook", account=True, params={}))
    raises(TypeError, lambda: dispatch("on_send_message_hook", account=7, params=[]))
    raises(runtime.UnsupportedSurfaceError, lambda: dispatch("unknown"))
    assert json.loads(runtime.dispatch_json("create_settings", '{"account":4}'))
    assert instance.events[-1] == ("settings", host.plugin_id, 4)
    handle = bridge.xt_register_handle(instance)
    runtime.invoke_handle_json(handle, "add_hook", '["TL_echo"]')
    assert instance._exteraless_request_hooks.count(("TL_echo", False, 0)) == 1
    runtime.invoke_handle_json(handle, "remove_hook", '["TL_echo"]')
    assert dispatch("pre_request_hook", account=7, request_name="TL_echo", request={})["strategy"] == "DEFAULT"
    runtime.invoke_handle_json(handle, "remove_hook", '["on_send_message_hook"]')
    assert dispatch("on_send_message_hook", account=7, params={"message": "hello"})["strategy"] == "DEFAULT"
    runtime.unload()
    return host


def case_load_errors(directory):
    runtime, host, bridge = bootstrap(directory, "ios_failure_probe")
    path = copy_fixture(host, "failure")
    from extera_utils import plugin_loader as loader

    def clean():
        assert not loader.plugins and not loader._owner_files
        assert host.plugin_id not in sys.modules and not bridge.xt_handle_count()
        assert loader.current_plugin_id() is None

    error = raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "fixture load failure")
    assert "failure.plugin" in error.debug and host.value("attempted") is True
    clean()
    for stage, reason in (("constructor", "fixture constructor failure"), ("api", "BasePlugin.hook_method")):
        host.seed("failure_stage", stage)
        raises(runtime.PluginLoadError, lambda: runtime.load_json(path), reason)
        clean()
    host.seed("failure_stage", "exit")
    assert raises(SystemExit, lambda: runtime.load_json(path)).code == 7
    clean()
    source = Path(path).read_text(encoding="utf-8")
    Path(path).write_text(source + '\n__requirements__ = ["ios-no-download-fixture==0"]\n', encoding="utf-8")
    calls = len(host.queued)
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "__requirements__")
    assert len(host.queued) == calls, "requirements must fail before executing plugin code"
    clean()
    Path(path).write_text(source.replace("class FailurePlugin(BasePlugin):", "class FailurePlugin:"), encoding="utf-8")
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "no BasePlugin subclass")
    clean()
    raises(runtime.PluginLoadError, lambda: runtime.load_json(str(FIXTURES / "metadata.plugin")), "__id__")
    clean()
    runtime.unload()
    return host


def case_cleanup(directory):
    runtime, host, bridge = bootstrap(directory)
    path = copy_fixture(host, "lifecycle")
    runtime.load_json(path)
    from extera_utils import plugin_loader as loader
    record = loader.plugins[host.plugin_id]
    rows = json.loads(runtime.settings_json())
    old_handle = host.queued[0][0]
    runtime.setting_changed_json("fail_unload", "true")
    raises(RuntimeError, runtime.unload, "fixture unload failure")
    assert not loader.plugins and not bridge.xt_handle_count()
    assert not record.change_callbacks and not record.click_callbacks
    assert loader.current_plugin_id() is None
    host.seed("fail_unload", False)
    runtime.load_json(path)
    raises(LookupError, lambda: runtime.invoke_handle_json(old_handle, "__call__", "[]"))
    raises(LookupError, lambda: runtime.setting_click_json(rows[3]["callback_id"]))
    runtime.settings_json()
    runtime.setting_changed_json("empty_settings", "true")
    assert json.loads(runtime.settings_json()) == []
    record = loader.plugins[host.plugin_id]
    assert not record.change_callbacks and not record.click_callbacks
    runtime.setting_changed_json("fail_settings", "true")
    assert "fixture settings failure" in json.loads(runtime.settings_json())[0]["text"]
    # Reload must invoke lifecycle, unlike the SDK's internal quiet replacement.
    runtime.load_json(path)
    assert host.value("loads") == 3 and host.value("unloads") == 2
    runtime.unload()
    assert host.value("unloads") == 3
    return host


def case_bootstrap(directory):
    runtime, host, bridge = bootstrap(directory, configure=False)
    import virtualjava
    backend = virtualjava.finder._State.backend
    virtualjava.uninstall()
    raises(runtime.RuntimeStateError, lambda: runtime.configure("ios_runtime_probe", host.plugins, host.settings), "bootstrap")
    virtualjava.install(backend)
    native_call = bridge.xt_call_host
    del bridge.xt_call_host
    raises(runtime.RuntimeStateError, lambda: runtime.configure("ios_runtime_probe", host.plugins, host.settings), "xt_call_host")
    bridge.xt_call_host = native_call
    runtime.configure("ios_runtime_probe", host.plugins, host.settings)
    runtime.configure("ios_runtime_probe", host.plugins, host.settings)
    raises(runtime.RuntimeStateError, lambda: runtime.configure("different_probe", host.plugins, host.settings), "only one")
    runtime.load_json(copy_fixture(host, "lifecycle"))
    from base_plugin import PythonBridge
    from java import jclass
    assert PythonBridge.getVersion() == "13.1.1-fixture"
    raises(virtualjava.JavaMemberError, lambda: jclass("no.such.NativeClass").call())
    exceptions = []

    def foreign():
        try:
            runtime.settings_json()
        except runtime.RuntimeStateError as error:
            exceptions.append(str(error))

    thread = threading.Thread(target=foreign)
    thread.start()
    thread.join(timeout=2)
    assert not thread.is_alive() and len(exceptions) == 1
    assert "owner worker" in exceptions[0]
    runtime.unload()
    return host


def case_requirements(directory):
    from email.message import Message
    from exteraless_runtime import _dependencies

    lock = json.loads((ROOT / "python/runtime/dependency-lock.json").read_text(encoding="utf-8"))
    distributions = {}
    for entry in lock["packages"]:
        metadata = Message()
        metadata["Name"] = entry["name"]
        metadata["Requires-Python"] = entry["requires_python"]
        for extra in entry["provides_extra"]:
            metadata["Provides-Extra"] = extra
        distributions[entry["name"]] = types.SimpleNamespace(
            version=entry["version"], metadata=metadata, requires=entry["requires_dist"])
    provider = _dependencies.ProvidedDependencies(distributions)
    # Unit injection supplies distribution metadata, not a replacement resolver.
    runtime, host, bridge = bootstrap(directory, dependency_provider=provider)
    from extera_utils import plugin_loader as loader
    import pip_controller
    assert loader._ensure_requirements.__self__ is provider
    assert pip_controller.ensure_requirements.__self__ is provider
    assert pip_controller.is_provided("typing_extensions") and not pip_controller.is_provided("java")
    path = copy_fixture(host, "lifecycle")
    original = Path(path).read_text(encoding="utf-8")

    def with_requirements(requirements):
        Path(path).write_text(original + "\n__requirements__ = " + repr(requirements) + "\n", encoding="utf-8")
        return runtime.load_json(path)

    satisfied = ["requests>=2.34,<3", "cachetools==8.0.0", "typing_extensions>=4.16",
                 'missing_marker_fixture>=1; python_version < "0"',
                 f'other_platform_fixture; sys_platform != "{sys.platform}"']
    assert json.loads(with_requirements(satisfied))["metadata"]["requirements"] == satisfied
    assert host.value("loads") == 1
    runtime.unload()
    assert host.value("unloads") == 1
    for requirement, expected in [
        ("cachetools<8", "provided cachetools==8.0.0"),
        ("missing_fixture>=1", "missing_fixture"),
        ("requests @ https://example.invalid/request.whl", "URL requirement"),
        ("requests[socks]", "pysocks"),
        ("requests[unknown_extra]", "does not provide extras"),
        ("cachetools>>>8", "invalid requirement"),
    ]:
        raises(runtime.PluginLoadError, lambda: with_requirements([requirement]), expected)
        assert host.value("loads") == 1 and not loader.plugins and not bridge.xt_handle_count()
    metadata = distributions["cachetools"].metadata
    metadata.replace_header("Requires-Python", ">=99")
    raises(runtime.PluginLoadError, lambda: with_requirements(["cachetools"]), "requires Python >=99")
    metadata.replace_header("Requires-Python", ">=3.11")
    # A installed parent cannot conceal an absent transitive dependency.
    del provider.distributions["idna"]
    raises(runtime.PluginLoadError, lambda: with_requirements(["requests"]), "idna")
    assert "requests" not in sys.modules, "checking metadata must not import the requested package"
    before = provider.installed_packages()
    pip_controller.remove_requirements(host.plugin_id)
    assert provider.installed_packages() == before
    raises(runtime.UnsupportedSurfaceError, lambda: pip_controller._fetch_pypi_json("requests"), "resolution")
    raises(runtime.UnsupportedSurfaceError, lambda: pip_controller._download_and_install("requests", None, {}), "installation")
    runtime.unload()
    return host


def case_callback_cleanup(directory):
    runtime, host, bridge = bootstrap(directory)
    runtime.load_json(copy_fixture(host, "lifecycle"))

    def failure():
        raise ValueError("callback body failure")

    handle = bridge.xt_register_handle(failure)
    host.pending_callbacks[handle] = 2
    raises(ValueError, lambda: runtime.invoke_handle_json(handle, "run", "[]"), "callback body failure")
    assert bridge.xt_resolve_handle(handle) is failure and host.pending_callbacks[handle] == 1
    raises(ValueError, lambda: runtime.invoke_handle_json(handle, "run", "[]"), "callback body failure")
    assert bridge.xt_resolve_handle(handle) is None and handle not in host.pending_callbacks

    reusable = bridge.xt_register_handle(failure)
    raises(ValueError, lambda: runtime.invoke_handle_json(reusable, "run", "[]"), "callback body failure")
    assert bridge.xt_resolve_handle(reusable) is failure  # No scheduled reference to release.

    previous = bridge.xt_call_host

    def broken_completion(request):
        if request["member"] == "completeCallback":
            raise RuntimeError("completion provider unavailable")
        return previous(request)

    bridge.xt_call_host = broken_completion
    raises(ValueError, lambda: runtime.invoke_handle_json(reusable, "run", "[]"), "callback body failure")
    bridge.xt_call_host = previous
    runtime.unload()
    assert not bridge.xt_handle_count()
    return host


def case_permissions(directory):
    runtime, host, bridge = bootstrap(directory)
    runtime.load_json(copy_fixture(host, "lifecycle"))
    loader = sys.modules["extera_utils.plugin_loader"]
    assert loader.has_permission("network", host.plugin_id) is True
    host.permissions.remove("network")
    assert loader.has_permission("network", host.plugin_id) is False
    raises(PermissionError, lambda: loader.require_permission("network", "fixture request", plugin_id=host.plugin_id))
    previous = bridge.xt_call_host

    def broken(request):
        if request["member"] == "hasPermission":
            raise RuntimeError("native permission provider unavailable")
        return previous(request)

    bridge.xt_call_host = broken
    raises(PermissionError, lambda: loader.has_permission("network", host.plugin_id), "unavailable")
    bridge.xt_call_host = previous
    runtime.unload()
    return host


def _audit_paths_case(directory, frozen_os=False):
    if frozen_os:
        # Re-create the actual CPython frozen module with an embedded-style
        # unavailable _stdlib_dir. No SDK helper/import implementation is mocked.
        from importlib.machinery import FrozenImporter
        sys._stdlib_dir = None
        spec = FrozenImporter.find_spec("os")
        assert spec is not None
        frozen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(frozen)
        assert not hasattr(frozen, "__file__") and frozen.__spec__.origin == "frozen"
        sys.modules["os"] = frozen

    runtime, host, bridge = bootstrap(directory, "ios_audit_probe", configure=False, real_dependencies=True)
    host.permissions = {"ui", "messages.send", "network"}
    # Neither mutable sys.path nor an ambient app-wide TMPDIR conveys file trust.
    shared_temp = directory / "shared-temp"
    shared_temp.mkdir()
    os.environ["TMPDIR"] = str(shared_temp)
    sys.path.extend((str(host.plugins), str(directory)))
    runtime.configure(host.plugin_id or "ios_audit_probe", host.plugins, host.settings)
    loader = sys.modules["extera_utils.plugin_loader"]
    audit = sys.modules["extera_utils.audit_gate"]
    vendor = ROOT / "python/vendor"
    assert runtime._state.dependencies.vendor_dir == vendor
    assert "cachetools" not in sys.modules and "requests" not in sys.modules
    assert audit._runtime_paths()
    assert audit._is_runtime_file(str(vendor / "cachetools/__init__.py"))
    assert not audit._is_runtime_file(str(host.plugins))
    assert not audit._is_runtime_file(str(host.settings))
    assert not audit._is_runtime_file(str(directory))
    assert not audit._is_runtime_file(str(shared_temp / "other-plugin.txt"))
    path = copy_fixture(host, "audit_import")
    try:
        runtime.load_json(path)
    except BaseException:
        print("AUDIT_PATH_DIAGNOSTIC " + json.dumps({
            "frozen_os": frozen_os, "os_file": getattr(audit.os, "__file__", None),
            "stdlib_dir": getattr(sys, "_stdlib_dir", None), "sys_path": sys.path,
            "runtime_prefixes": audit._runtime_prefixes,
            "vendor_on_sys_path": str(vendor) in sys.path,
        }))
        raise
    record = loader.plugins[host.plugin_id]
    assert record.instance.dependencies["cachetools"] == "8.0.0"
    assert record.instance.dependencies["requests"] == "2.34.2"
    assert record.instance.dependencies["cache_value"] == 7
    assert record.instance.dependencies["certificate_bytes"] > 0
    assert Path(record.instance.dependencies["plugin_data"]).is_dir()
    assert Path(record.instance.dependencies["plugin_cache"]).is_dir()
    assert Path(record.instance.dependencies["requests_file"]).is_relative_to(vendor)
    assert Path(record.instance.dependencies["cachetools_file"]).is_relative_to(vendor)
    assert host.value("imported") is True and "files" not in host.permissions
    assert not any(Path(name).is_relative_to(vendor) for name in loader._owner_files)
    handle = bridge.xt_register_handle(record.instance)

    def invoke(method, *args):
        return json.loads(runtime.invoke_handle_json(handle, method, json.dumps(args)))

    certificate = record.instance.dependencies["certifi_file"]
    assert invoke("read_file", certificate) > 0
    assert invoke("pathlib_read", certificate) > 0
    assert invoke("sdk_read", certificate) > 0
    own_file = host.files / "mine.txt"
    own_file.write_text("own data", encoding="utf-8")
    assert invoke("read_file", str(own_file)) == 8

    foreign_files = [directory / "foreign.txt", shared_temp / "other-plugin.txt",
                     host.plugins / "other.plugin", host.settings / "other.json"]
    for foreign in foreign_files:
        foreign.write_text("not this plugin's data", encoding="utf-8")
        for method in ("read_file", "pathlib_read", "sdk_read"):
            raises(PermissionError, lambda: invoke(method, str(foreign)), "files")

    # Real audit events, without opening a write descriptor or making a syscall.
    mutations = [("open", [certificate, "w", os.O_WRONLY | os.O_TRUNC]),
                 ("os.rename", [certificate, str(own_file), -1, -1]),
                 ("os.rename", [str(vendor.parent), str(own_file), -1, -1]),
                 ("os.link", [certificate, str(own_file), -1, -1])]
    for permission_set in (set(host.permissions), {*host.permissions, "files", "hooks"}):
        host.permissions = permission_set
        for event, args in mutations:
            raises(PermissionError, lambda: invoke("audit_event", event, args), "read-only")
    host.permissions = {"ui", "messages.send"}
    import socket
    raises(socket.gaierror,
           lambda: invoke("audit_event", "socket.getaddrinfo", ["never-resolved.invalid", 443, 0, 0, 0]),
           "network")
    original_call = bridge.xt_call_host
    for member in ("isUnsafeMode", "hasPermission"):
        def unavailable(request, failed_member=member):
            if request["member"] == failed_member:
                raise RuntimeError("permission service unavailable")
            return original_call(request)
        bridge.xt_call_host = unavailable
        try:
            raises(PermissionError,
                   lambda: invoke("audit_event", "socket.getaddrinfo", ["never-resolved.invalid", 443, 0, 0, 0]),
                   "unavailable")
        finally:
            bridge.xt_call_host = original_call
    assert loader.has_permission("network", host.plugin_id) is False
    assert loader.has_permission("files", host.plugin_id) is False
    assert loader.unsafe_mode() is False
    assert loader.current_plugin_id() is None
    print("AUDIT_PATHS_OK " + json.dumps({
        "frozen_os": frozen_os, "os_file": getattr(audit.os, "__file__", None),
        "vendor_imported": True, "foreign_reads_denied": 12,
        "runtime_mutations_denied": 8, "dns_audit_denied": True,
        "unavailable_permission_provider_denied": True,
    }))
    runtime.unload()
    assert not loader.plugins and not bridge.xt_handle_count()
    return host


def case_audit_paths(directory):
    return _audit_paths_case(directory)


def case_audit_paths_frozen(directory):
    return _audit_paths_case(directory, frozen_os=True)


def case_audit_layout(directory):
    from exteraless_runtime._audit_paths import RuntimePaths, _framework_directories
    from exteraless_runtime import RuntimeStateError
    app = directory / "Fixture.app"
    python = app / "python"
    stdlib = app / "python-stdlib/lib/python3.12"
    dynload = stdlib / "lib-dynload"
    dynload.mkdir(parents=True)
    frameworks = app / "Frameworks"
    for name in ("Python", "_ssl", "TelegramUI"):
        binary = frameworks / (name + ".framework") / name
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"path-only fixture; never loaded")
    marker = dynload / "_ssl.cpython-312-iphoneos.fwork"
    marker.write_text("Frameworks/_ssl.framework/_ssl\n", encoding="utf-8")
    framework_roots = _framework_directories(python, [str(stdlib)])
    data = app / "Library/Application Support/exteraless"
    paths = RuntimePaths([stdlib, *framework_roots], excluded=[data / "plugins", data / "settings"])
    assert paths.contains(marker)
    assert paths.contains(frameworks / "_ssl.framework/_ssl")
    assert paths.contains(frameworks / "Python.framework/Python")
    assert not paths.contains(frameworks / "TelegramUI.framework/TelegramUI")
    assert not paths.contains(data / "plugins/foreign.plugin")
    assert not paths.contains(data / "settings/foreign.json")
    assert not paths.contains(str(stdlib) + "-foreign/os.py")
    too_broad = RuntimePaths([app], excluded=[data / "plugins"])
    assert not too_broad.contains(data / "plugins/foreign.plugin")
    assert not too_broad.directories
    marker.write_text("../../Library/Application Support/foreign\n", encoding="utf-8")
    raises(RuntimeStateError, lambda: _framework_directories(python, [str(stdlib)]), "marker")
    return None


def worker(case, directory):
    sys.path.insert(0, str(ROOT / "python"))
    if case == "requirements":
        # Pre-existing host packaging only; downloaded wheel code is never used
        # by these unit tests. The other workers retain the original -S scope.
        sys.path.append(sys.argv[3])
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    counts = {}
    loader_file = str(ROOT / "python/sdk/extera_utils/plugin_loader.py")
    counted = {"load_plugin", "unload_plugin", "get_settings_json", "notify_setting_changed",
               "dispatch_setting_click", "call_app_event", "call_send_message_hook", "_import_module"}

    def profile(frame, event, arg):
        if event == "call" and os.path.normcase(frame.f_code.co_filename) == os.path.normcase(loader_file):
            name = frame.f_code.co_name
            if name in counted:
                counts[name] = counts.get(name, 0) + 1

    sys.setprofile(profile)
    try:
        host = globals()["case_" + case](Path(directory))
    finally:
        sys.setprofile(None)
    if case not in ("metadata", "audit_layout"):
        assert counts.get("load_plugin", 0) > 0 and counts.get("unload_plugin", 0) > 0
    if case == "lifecycle_settings":
        assert counts.get("get_settings_json", 0) and counts.get("notify_setting_changed", 0)
        assert counts.get("dispatch_setting_click", 0)
    print("IOS_RUNTIME_UNIT_OK " + json.dumps({
        "case": case, "sdk_executed": counts, "native_double_calls": len(host.calls) if host else 0,
    }, sort_keys=True))


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
elif __name__ != "_ios_runtime_fixture_support":
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_ios_runtime(case, tmp_path):
        arguments = []
        if case == "requirements":
            spec = importlib.util.find_spec("packaging")
            assert spec is not None, "requirement unit tests need the host's existing packaging"
            arguments = [str(Path(spec.origin).resolve().parent.parent)]
        result = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path), *arguments],
            cwd=tmp_path, text=True, encoding="utf-8", errors="replace",
            capture_output=True, timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        summary = next((line for line in result.stdout.splitlines()
                        if line.startswith("IOS_RUNTIME_UNIT_OK ")), None)
        assert summary is not None
        for line in result.stdout.splitlines():
            if line.startswith("AUDIT_PATHS_OK "):
                print(line)
        print(summary)
