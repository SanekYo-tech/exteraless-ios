"""Owner-worker observations for swift_plugin_probe; no service/backend doubles.

The native engine loads this helper before the host's untouched bootstrap. The
profiler observes real SDK/plugin calls and the built-in xt_call_host C function.
The two exported checks enter through PluginHost.invokeCallback, in SDK context.
"""

import _thread
import json
import os
import sys


_plugin_id = "nativeWaveProbe"
_runtime_class = "exteraless.ios.Runtime"
_operations = ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance")
_sdk_names = {
    "load_plugin", "unload_plugin", "get_settings_json", "_serialize_setting_item",
    "notify_setting_changed", "dispatch_setting_click", "call_app_event",
    "call_send_message_hook", "_import_module",
}
_fixture_names = {"<module>", "on_plugin_load", "on_plugin_unload", "create_settings",
                  "clicked", "on_app_event", "on_send_message_hook"}
_owner = None
_native_reference = None
_python_root = None
_plugin_file = None
_files = {}
_sdk_calls = {}
_fixture_calls = {}
_native_members = {}
_sources = {}
_events = []
_problems = []
_transport_calls = 0
_transport_errors = 0
_metadata_calls = 0
_checks_handle = None
_services_verified = False
_unknown_rejected = False
_directories = {}


def _path(path):
    return os.path.normcase(os.path.normpath(path))


def install(python_root, installed_plugin, native_reference):
    global _owner, _python_root, _plugin_file, _native_reference, _files
    if _owner is not None or sys.getprofile() is not None:
        raise RuntimeError("native plugin probe profiler must be installed exactly once")
    _owner = _thread.get_ident()
    _python_root = os.path.realpath(python_root)
    _plugin_file = _path(installed_plugin)
    _native_reference = native_reference
    _files = {
        "loader": _path(os.path.join(_python_root, "sdk", "extera_utils", "plugin_loader.py")),
        "metadata": _path(os.path.join(_python_root, "sdk", "extera_utils", "metadata_parser.py")),
        "android": _path(os.path.join(_python_root, "sdk", "android_utils.py")),
    }
    sys.setprofile(_profile)


def _profile(frame, event, arg):
    global _transport_calls, _transport_errors, _metadata_calls
    try:
        if event in ("c_call", "c_exception"):
            bridge = sys.modules.get("_exteraless_bridge")
            if bridge is not None and arg is getattr(bridge, "xt_call_host", None):
                if event == "c_exception":
                    _transport_errors += 1
                else:
                    _transport_calls += 1
                    local = frame.f_locals
                    fqcn = local.get("fqcn", _runtime_class)
                    member = local.get("member", "<direct>")
                    if isinstance(fqcn, str) and isinstance(member, str):
                        key = fqcn + "#" + member
                        _native_members[key] = _native_members.get(key, 0) + 1
                if _thread.get_ident() != _owner:
                    _problems.append("native transport entered from a foreign worker")
            return
        if event != "call":
            return
        code = frame.f_code
        filename = _path(code.co_filename)
        name = code.co_name
        if filename == _files["metadata"] and name == "read_metadata":
            _metadata_calls += 1
            _sources["read_metadata"] = code.co_filename
        if ((filename == _files["loader"] and name in _sdk_names)
                or (filename == _files["android"] and name == "run_on_ui_thread")):
            _sdk_calls[name] = _sdk_calls.get(name, 0) + 1
            _sources[name] = code.co_filename
        if filename == _plugin_file and name in _fixture_names:
            _fixture_calls[name] = _fixture_calls.get(name, 0) + 1
            _sources["fixture." + name] = code.co_filename
            if _thread.get_ident() != _owner:
                _problems.append("fixture executed on a foreign worker")
            if name != "<module>":
                loader = sys.modules.get("extera_utils.plugin_loader")
                owner = loader.current_plugin_id() if loader else None
                if owner != _plugin_id:
                    _problems.append("fixture executed outside its SDK plugin context: " + name)
                local = frame.f_locals
                _events.append({"method": name, "pluginId": owner,
                                "account": local.get("account"),
                                "event": local.get("event_type")})
    except BaseException as error:
        # Observation failures must fail the probe, without changing SDK control flow.
        if len(_problems) < 16:
            _problems.append(type(error).__name__ + ": " + str(error))


def _record():
    if _thread.get_ident() != _owner:
        raise RuntimeError("probe checks require the owning native worker")
    loader = sys.modules.get("extera_utils.plugin_loader")
    if loader is None or _plugin_id not in loader.plugins:
        raise RuntimeError("the real SDK fixture has not loaded")
    return loader, loader.plugins[_plugin_id]


def export_checks():
    """Register only this probe helper; the plugin/SDK objects are never replaced."""
    global _checks_handle
    _record()
    if _checks_handle is None:
        import _exteraless_bridge
        _checks_handle = _exteraless_bridge.xt_register_handle(_NativeChecks())
    return _checks_handle


def _native(member, *args):
    import _exteraless_bridge
    return _exteraless_bridge.xt_call_host({
        "op": "call", "fqcn": _runtime_class, "member": member,
        "args": list(args), "kwargs": {},
    })


class _NativeChecks:
    def verify_services(self):
        global _services_verified, _unknown_rejected, _directories
        loader, record = _record()
        if loader.current_plugin_id() != _plugin_id:
            raise RuntimeError("invokeCallback did not enter SDK plugin context")
        from base_plugin import PythonBridge
        from virtualjava import JavaMemberError
        directories = {"plugins": PythonBridge.getPluginsDir(),
                       "files": PythonBridge.getFilesDir(), "cache": PythonBridge.getCacheDir()}
        for name, directory in directories.items():
            if not os.path.isabs(directory) or not os.path.isdir(directory):
                raise AssertionError("native directory does not exist: " + name)
        if _path(directories["plugins"]) != _path(os.path.dirname(_plugin_file)):
            raise AssertionError("native plugins directory differs from host configuration")
        if PythonBridge.getVersion() != "native-swift-sdk-fixture/1":
            raise AssertionError("Runtime.getVersion did not reach the Swift fixture provider")
        value = "native \u96ea\x00\u03c0"
        record.instance.set_setting("probe_roundtrip", value)
        if record.instance.get_setting("probe_roundtrip", "missing") != value:
            raise AssertionError("native UTF-8/NUL settings roundtrip failed")
        if PythonBridge.removeSetting(_plugin_id, "probe_roundtrip") is not True:
            raise AssertionError("native removeSetting did not remove the stored value")
        if record.instance.get_setting("probe_roundtrip", "missing") != "missing":
            raise AssertionError("removed native setting survived")
        try:
            _native("__unsupported_probe_member__")
        except JavaMemberError as error:
            if "__unsupported_probe_member__" not in str(error):
                raise AssertionError("unexpected native error: " + str(error)) from error
            _unknown_rejected = True
        else:
            raise AssertionError("unknown native member was silently accepted")
        _directories = directories
        _services_verified = True

    def queue_click(self):
        loader, record = _record()
        if loader.current_plugin_id() != _plugin_id:
            raise RuntimeError("callback scheduler check is outside SDK context")
        from android_utils import run_on_ui_thread
        # Actual SDK lambda -> C handle -> Swift onCallback -> host owner queue.
        run_on_ui_thread(record.instance.clicked, 0)


def snapshot_json():
    """Read-only observations, collected while the same owner thread is attached."""
    if _thread.get_ident() != _owner:
        raise RuntimeError("snapshot requested on the wrong worker")
    loader = sys.modules.get("extera_utils.plugin_loader")
    bridge = sys.modules.get("_exteraless_bridge")
    finder = sys.modules.get("virtualjava.finder")
    runtime = sys.modules.get("exteraless_runtime")
    state = getattr(runtime, "_state", None)
    module_paths = {}
    for name in ("extera_utils.plugin_loader", "extera_utils.metadata_parser", "base_plugin",
                 "ui.settings", "exteraless_runtime", "virtualjava"):
        module = sys.modules.get(name)
        if module is not None:
            module_paths[name] = getattr(module, "__file__", "")
    return json.dumps({
        "nativeReference": _native_reference,
        "threadId": _owner,
        "pluginId": getattr(state, "plugin_id", None),
        "profileActive": sys.getprofile() is _profile,
        "sdkLoaderPresent": loader is not None,
        "metadataCalls": _metadata_calls,
        "sdkCalls": dict(_sdk_calls),
        "fixtureCalls": dict(_fixture_calls),
        "transportCalls": _transport_calls,
        "transportErrors": _transport_errors,
        "nativeMembers": dict(_native_members),
        "sources": dict(_sources),
        "modulePaths": module_paths,
        "events": list(_events),
        "problems": list(_problems),
        "bridgeBuiltin": bridge is not None and bridge.__spec__.origin == "built-in"
            and type(bridge.xt_call_host) is type(len),
        "backendInstalled": bridge is not None and finder is not None
            and type(finder._State.backend) is bridge.BridgeBackend,
        "legacyServiceCount": sum(bool(bridge.xt_service_ptr("java." + op)) for op in _operations) if bridge else 0,
        "mockCalls": len(bridge.xt_mock_log()) if bridge else 0,
        "handleCount": bridge.xt_handle_count() if bridge else 0,
        "loadedPlugins": sorted(loader.plugins) if loader else [],
        "checksHandle": _checks_handle,
        "servicesVerified": _services_verified,
        "unknownRejected": _unknown_rejected,
        "directories": dict(_directories),
    }, ensure_ascii=False, allow_nan=False)


def finish_json():
    result = snapshot_json()
    sys.setprofile(None)
    return result
