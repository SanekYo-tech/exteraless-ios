"""Read-only observer for the fifth native child; no loader/gate replacements."""

import _thread
import json
import sys


_thread_id = _thread.get_ident()
_gate_calls = 0
_hooks = {}
_network = []
_entry_calls = 0
_load_calls = 0
_unload_calls = 0
_hook_sources = {}
_handle = None
_plugin_source = None


def _profile(frame, event, value):
    global _gate_calls, _entry_calls, _load_calls, _unload_calls
    if event == "c_call":
        bridge = sys.modules.get("_exteraless_bridge")
        if bridge is not None and value is getattr(bridge, "xt_elyx_source", None):
            _gate_calls += 1
    elif event == "call":
        path = frame.f_code.co_filename.replace("\\", "/")
        name = frame.f_code.co_name
        if path.endswith("/exteraless_runtime/_archives.py") and name in (
                "developer_manifest", "inspect_developer_descriptor", "verified_developer_load"):
            _hooks[name] = _hooks.get(name, 0) + 1
            _hook_sources[name] = path
        if path.endswith("/main.py"):
            if name == "<module>": _entry_calls += 1
            if name == "on_plugin_load": _load_calls += 1
            if name == "on_plugin_unload": _unload_calls += 1


def _audit(event, arguments):
    if event in ("socket.connect", "socket.bind", "socket.getaddrinfo"):
        _network.append(event)


sys.setprofile(_profile)
sys.addaudithook(_audit)


def loaded():
    global _handle, _plugin_source
    import _exteraless_bridge as bridge
    import exteraless_runtime as runtime
    assert _handle is None and _thread.get_ident() == _thread_id
    record = runtime._state.loader.plugins[runtime._state.plugin_id]
    _plugin_source = record.instance.on_plugin_load.__code__.co_filename
    _handle = bridge.xt_register_handle(Checks())
    return json.dumps({"pluginId": runtime._state.plugin_id, "handle": _handle})


class Checks:
    def snapshot(self, label):
        import _exteraless_bridge as bridge
        import exteraless_runtime as runtime
        import elyx_runtime
        from virtualjava import finder
        state = runtime._state
        record = state.loader.plugins[state.plugin_id]
        archive = elyx_runtime.get_state(state.plugin_id)
        expected = [label, "asset-" + label, "wheel-" + label]
        assert record.instance.get_setting("seen") == expected
        assert record.module.helpers.VALUE == label and record.module.elyxprobe.VALUE == "wheel-" + label
        assert _thread.get_ident() == _thread_id and state.owner_token
        assert bridge.__spec__.origin == "built-in" and type(finder._State.backend) is bridge.BridgeBackend and not _network
        assert _entry_calls == 1 and _load_calls == 1 and _unload_calls == 0
        return {"seen": expected, "owner": state.owner_token, "digest": archive.digest, "extract": archive.extract_dir,
                 "helper": record.module.helpers.__file__, "wheel": record.module.elyxprobe.__file__,
                 "class_name": type(record.instance).__name__, "module_name": record.module.__name__,
                 "hooks": dict(_hooks), "gate_calls": _gate_calls, "entry_calls": _entry_calls,
                 "runtime_source": runtime.__file__, "archive_source": runtime._archives.__file__}

    def replay(self, descriptor_json):
        import _exteraless_bridge as bridge
        try:
            bridge.xt_elyx_source("claim", descriptor_json)
        except Exception as error:
            return {"rejected": True, "error": str(error)}
        raise AssertionError("expired native source capability was replayed")


def observation():
    import _exteraless_bridge as bridge
    runtime = sys.modules.get("exteraless_runtime")
    state = getattr(runtime, "_state", None)
    loader = sys.modules.get("extera_utils.plugin_loader")
    finder = sys.modules.get("virtualjava.finder")
    assert not _network and _thread.get_ident() == _thread_id
    if state is None:
        assert _entry_calls == 0 and _load_calls == 0 and _unload_calls == 0
        assert not any(name.startswith("ElyxPlugins.") for name in sys.modules)
    operations = ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance")
    result = {"thread": _thread_id, "plugin": getattr(state, "plugin_id", None), "source": _plugin_source,
        "handles": bridge.xt_handle_count(), "leases": len(state.callbacks.leases) if state else 0,
        "plugins": sorted(loader.plugins) if loader else [], "gate_calls": _gate_calls,
        "hooks": dict(_hooks), "hook_sources": dict(_hook_sources), "network": list(_network),
        "builtin": bridge.__spec__.origin == "built-in", "entry_calls": _entry_calls,
        "load_calls": _load_calls, "unload_calls": _unload_calls,
        "backend_installed": finder is not None and type(finder._State.backend) is bridge.BridgeBackend,
        "legacy_services": sum(bool(bridge.xt_service_ptr("java." + op)) for op in operations),
        "mock_calls": len(bridge.xt_mock_log())}
    sys.setprofile(None)
    return json.dumps(result)
