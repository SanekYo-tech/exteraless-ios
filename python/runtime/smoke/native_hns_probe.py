"""Own bounded native lifecycle checks; all callbacks enter the real SDK/C worker."""

import _thread
import json
import sys


_source = None
_thread_id = None
_checks = None


def loaded():
    global _source, _thread_id, _checks
    import _exteraless_bridge as bridge
    state = sys.modules["exteraless_runtime"]._state
    _source = state.loader.plugins[state.plugin_id].instance.on_plugin_load.__code__.co_filename
    _thread_id = _thread.get_ident()
    _checks = bridge.xt_register_handle(_Checks())
    return json.dumps({"pluginId": state.plugin_id, "handle": _checks})


def _state():
    state = sys.modules["exteraless_runtime"]._state
    assert _thread.get_ident() == _thread_id and state.loader.current_plugin_id() == state.plugin_id
    return state, state.loader.plugins[state.plugin_id].instance


class _Checks:
    def barrier(self):
        _state()

    def block(self):
        state, _ = _state()
        return state.call("sdkHNSBlockWorker")

    def notifications_table(self):
        import client_utils as client
        _state()
        center = client.get_notification_center(2)
        rows = center.supported()
        for row in rows: assert getattr(center, row.name) == row.id
        return [row.id for row in rows]

    def pending(self):
        import client_utils as client
        state, plugin = _state()
        with client.hook_scope(2): result = plugin.pending_resources()
        assert len(state.callbacks.leases) == 4 and len(state.callbacks.handles) == 12
        return dict(result, handles=sorted(state.callbacks.handles))

    def callbacks(self, positive):
        state, plugin = _state()
        ids = plugin.callback_resources(positive)
        return {"ids": ids, "handles": sorted(state.callbacks.handles)}

    def after_callbacks(self, expected):
        import _exteraless_bridge as bridge
        state, plugin = _state()
        assert plugin.bodies == expected, "revoked native callback entered user Python"
        assert not state.callbacks.leases and not state.scheduler.tasks and bridge.xt_handle_count() == 1
        assert bridge.xt_resolve_handle(_checks) is self
        return True


def observation():
    bridge = sys.modules.get("_exteraless_bridge")
    runtime = sys.modules.get("exteraless_runtime")
    state = getattr(runtime, "_state", None)
    loader = sys.modules.get("extera_utils.plugin_loader")
    finder = sys.modules.get("virtualjava.finder")
    operations = ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance")
    return json.dumps({
        "threadId": _thread.get_ident(), "pluginId": getattr(state, "plugin_id", None),
        "ownerToken": getattr(state, "owner_token", None), "pluginSource": _source,
        "runtimeSource": getattr(runtime, "__file__", None), "sdkSource": getattr(loader, "__file__", None),
        "handleCount": bridge.xt_handle_count() if bridge else 0,
        "callbackLeases": len(state.callbacks.leases) if state else 0, "loadedPlugins": sorted(loader.plugins) if loader else [],
        "bridgeBuiltin": bridge is not None and bridge.__spec__.origin == "built-in" and type(bridge.xt_call_host) is type(len),
        "backendInstalled": bridge is not None and finder is not None and type(finder._State.backend) is bridge.BridgeBackend,
        "legacyServiceCount": sum(bool(bridge.xt_service_ptr("java." + operation)) for operation in operations) if bridge else 0,
        "mockCalls": len(bridge.xt_mock_log()) if bridge else 0,
    }, ensure_ascii=False, allow_nan=False)
