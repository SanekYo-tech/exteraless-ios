"""One-plugin iOS worker adapter for ``sdk/extera_utils/plugin_loader.py``.

The Swift bootstrap installs virtualjava and binds the native bridge first.
Importing this module alone neither installs a backend nor executes a plugin.
"""

import importlib
import os
import sys
from contextlib import contextmanager

from . import _codec, _dependencies
from ._platform import Platform, RuntimeStateError, UnsupportedSurfaceError

__all__ = [
    "configure", "metadata_json", "load_json", "unload", "dispatch_json",
    "settings_json", "setting_changed_json", "setting_click_json", "invoke_handle_json",
    "PluginLoadError", "RuntimeStateError", "UnsupportedSurfaceError",
]


class PluginLoadError(RuntimeError):
    def __init__(self, message, debug=None):
        super().__init__(message)
        self.debug = debug


_state = None


def _sdk_module(name):
    # Canonical SDK names matter: two imports of BasePlugin/plugin_loader would
    # create two class identities and two registries. Never import sdk.* aliases.
    sdk_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "sdk")
    if sdk_dir not in sys.path:
        sys.path.insert(0, sdk_dir)
    return importlib.import_module(name)


def _source_path(path):
    path = os.path.abspath(os.fspath(path))
    if not path.lower().endswith((".py", ".plugin")):
        raise UnsupportedSurfaceError("iOS runtime accepts Python source .py/.plugin files only")
    return path


def _metadata(path):
    return _sdk_module("extera_utils.metadata_parser").read_metadata(path)


def metadata_json(path) -> str:
    """Return the SDK metadata object using its AST reader, even before configure."""
    return _codec.dumps(_metadata(_source_path(path)))


def configure(plugin_id, plugins_dir, settings_dir) -> None:
    """Bind a single immutable plugin identity to the current owner worker."""
    global _state
    _sdk_module("extera_utils.metadata_parser")._validate_plugin_id(plugin_id)
    plugins_dir = os.path.realpath(os.fspath(plugins_dir))
    settings_dir = os.path.realpath(os.fspath(settings_dir))
    if _state is not None:
        _state.check_worker()
        if (plugin_id, plugins_dir, settings_dir) != (
                _state.plugin_id, _state.plugins_dir, _state.settings_dir):
            raise RuntimeStateError("an iOS interpreter can be configured for only one plugin")
        return None

    bridge = importlib.import_module("_exteraless_bridge")
    finder = importlib.import_module("virtualjava.finder")
    for name in ("xt_set_plugin_id", "xt_call_host", "xt_resolve_handle",
                 "xt_register_handle", "xt_release_handle", "xt_clear_handles", "BridgeBackend"):
        if not hasattr(bridge, name):
            raise RuntimeStateError(f"native bridge is missing {name}")
    if not finder._State.installed or not isinstance(finder._State.backend, bridge.BridgeBackend):
        raise RuntimeStateError("configure requires the native virtualjava bootstrap")

    platform = Platform(bridge, plugin_id, plugins_dir, settings_dir)
    bridge.xt_set_plugin_id(plugin_id)
    platform.getPluginsDir()
    dependencies = _dependencies.create_provider()
    loader = _sdk_module("extera_utils.plugin_loader")
    if loader.plugins:
        raise RuntimeStateError("configure requires an empty SDK plugin registry")
    platform.install(loader, dependencies)
    _state = platform
    return None


def _runtime(loaded=False):
    platform = _state
    if platform is None:
        raise RuntimeStateError("call configure before using the iOS plugin runtime")
    platform.check_worker()
    if loaded and not platform.loader.is_loaded(platform.plugin_id):
        raise RuntimeStateError(f"plugin {platform.plugin_id!r} is not loaded")
    return platform


@contextmanager
def _scope(platform, account=None):
    with platform.loader.plugin_context(platform.plugin_id):
        with platform.loader.client_utils.hook_scope(account):
            yield


def _cleanup(platform, record=None, path=None, module_name=None):
    loader = platform.loader
    if record is not None:
        record.click_callbacks.clear()
        record.change_callbacks.clear()  # SDK unload only clears click/custom refs.
        record.custom_views.clear()
        instance = record.instance
        for name in ("_exteraless_menu_callbacks", "_exteraless_request_hooks"):
            value = instance.__dict__.get(name)
            if value is not None:
                value.clear()
        instance.__dict__["_exteraless_send_message_registered"] = False
        instance._exteraless_drop_settings_cache()
    if path is not None:
        # A class lookup/constructor failure happens before SDK creates a record.
        module = sys.modules.get(module_name)
        if module is not None and loader._same_file(getattr(module, "__file__", None), path):
            sys.modules.pop(module_name, None)
        loader._forget_owner(path)
    loader.invalidate_settings_mirror(platform.plugin_id)
    loader.forget_audit(platform.plugin_id)
    # These SDK caches can hold native instances whose C identity mapping is
    # about to be dropped. A subsequent load must obtain fresh native proxies.
    loader.client_utils._account_parts.clear()
    loader.client_utils._queues.clear()
    # This interpreter/realm belongs exclusively to this plugin, including refs
    # exported by C while marshalling native service arguments (UI callbacks).
    platform.bridge.xt_clear_handles()


def load_json(path) -> str:
    """Use the SDK loader; turn its failure JSON into an exception for Swift."""
    platform = _runtime()
    path = _source_path(path)
    metadata = _metadata(path)
    if metadata["id"] != platform.plugin_id:
        raise PluginLoadError("plugin __id__ does not match the configured worker")
    if platform.loader.is_loaded(platform.plugin_id):
        unload()
    loader = platform.loader
    module_name = loader._module_name_for(platform.plugin_id)
    try:
        with _scope(platform):
            result = _codec.loads(loader.load_plugin(path, platform.plugin_id))
        if result.get("ok") is not True:
            raise PluginLoadError(result.get("error") or "SDK plugin load failed", result.get("debug"))
        return _codec.dumps({
            "metadata": metadata, "handles": result["handles"],
            "has_settings": result["has_settings"],
        })
    except BaseException:
        record = loader.plugins.get(platform.plugin_id)
        try:
            with _scope(platform):
                loader._unload_record(platform.plugin_id, quiet=True)
        finally:
            _cleanup(platform, record, path, module_name)
        raise


def unload() -> None:
    """Run on_plugin_unload in context and release refs, including on failure."""
    if _state is None:
        return None
    platform = _runtime()
    record = platform.loader.plugins.get(platform.plugin_id)
    try:
        with _scope(platform):
            platform.loader.unload_plugin(platform.plugin_id)
    finally:
        _cleanup(platform, record)
    return None


_HOOKS = {
    "pre_request_hook": ("call_pre_request_hook", "request_name", "request"),
    "post_request_hook": ("call_post_request_hook", "request_name", "response"),
    "on_update_hook": ("call_update_hook", "update_name", "update"),
    "on_updates_hook": ("call_updates_hook", "container_name", "updates"),
}


def _account(payload):
    value = payload["account"]
    if type(value) is not int or not -(2 ** 31) <= value < 2 ** 31:
        raise ValueError("hook account must be an Int32 index")
    return value


def _registered(instance, hook, name=None):
    if hook == "on_send_message_hook":
        return bool(instance.__dict__.get("_exteraless_send_message_registered", False))
    return any((pattern in name if substring else pattern == name)
               for pattern, substring, _ in instance.__dict__.get("_exteraless_request_hooks", ()))


def dispatch_json(hook, payload_json) -> str:
    """Dispatch SDK protocol names with JSON snapshots, not Android objects."""
    platform = _runtime(loaded=True)
    payload = _codec.loads(payload_json)
    if not isinstance(payload, dict):
        raise TypeError("hook payload must be a JSON object")
    loader, plugin_id = platform.loader, platform.plugin_id
    if hook == "create_settings":
        account = _account(payload) if "account" in payload else None
        with _scope(platform, account):
            return loader.get_settings_json(plugin_id)
    if hook == "on_app_event":
        event = payload["event_type"]
        if event not in ("app_start", "app_stop", "app_pause", "app_resume"):
            raise ValueError(f"unknown SDK app event {event!r}")
        with _scope(platform):
            loader.call_app_event(plugin_id, event)
        return "null"
    if hook != "on_send_message_hook" and hook not in _HOOKS:
        raise UnsupportedSurfaceError(f"unsupported hook {hook!r}")
    account = _account(payload)
    instance = loader.plugins[plugin_id].instance
    if hook == "on_send_message_hook":
        field, name = "params", None
        value = _codec.decode(payload[field], platform.bridge)
        if not isinstance(value, dict):
            raise TypeError("send_message params must be a JSON object")
        args = (account, value)
        fn = loader.call_send_message_hook
    else:
        function, name_field, field = _HOOKS[hook]
        name = payload[name_field]
        if not isinstance(name, str):
            raise TypeError(f"{name_field} must be a string")
        value = _codec.decode(payload[field], platform.bridge)
        args = (account, name, value)
        if hook == "post_request_hook":
            args += (_codec.decode(payload.get("error"), platform.bridge),)
        fn = getattr(loader, function)
    with _scope(platform, account):
        result = None
        if _registered(instance, hook, name):
            result = fn(plugin_id, *args)
        strategy = "DEFAULT" if result is None else result.strategy
        if result is not None and result.value is not None:
            value = result.value
        return _codec.dumps({"strategy": strategy, field: value}, platform.bridge)


def settings_json() -> str:
    platform = _runtime(loaded=True)
    with _scope(platform):
        return platform.loader.get_settings_json(platform.plugin_id)


def setting_changed_json(key, value_json) -> str:
    platform = _runtime(loaded=True)
    if not isinstance(key, str):
        raise TypeError("setting key must be a string")
    _codec.loads(value_json)  # The SDK alone would turn malformed JSON into null.
    with _scope(platform):
        platform.loader.notify_setting_changed(platform.plugin_id, key, value_json)
    return "null"


def setting_click_json(callback_id) -> str:
    platform = _runtime(loaded=True)
    record = platform.loader.plugins[platform.plugin_id]
    if callback_id not in record.click_callbacks:
        raise LookupError(f"unknown settings callback {callback_id!r}")
    with _scope(platform):
        platform.loader.dispatch_setting_click(platform.plugin_id, callback_id)
    return "null"


def invoke_handle_json(handle, method, args_json) -> str:
    platform = _runtime(loaded=True)
    if type(handle) is not int or handle <= 0:
        raise ValueError("callback handle must be a positive integer")
    if not isinstance(method, str):
        raise TypeError("callback method must be a string")
    arguments = _codec.loads(args_json)
    if not isinstance(arguments, list):
        raise TypeError("callback arguments must be a JSON array")
    try:
        target = platform.bridge.xt_resolve_handle(handle)
        if target is None:
            raise LookupError(f"unknown callback handle {handle}")
        with _scope(platform):
            arguments = _codec.decode(arguments, platform.bridge)
            if method in ("", "__call__"):
                callback = target
            elif method == "run" and callable(target):
                callback = getattr(target, "run", target)
            else:
                callback = getattr(target, method)
            if not callable(callback):
                raise TypeError(f"handle {handle} method {method!r} is not callable")
            return _codec.dumps(callback(*arguments), platform.bridge)
    finally:
        original_error = sys.exception()
        try:
            # Native accounting and C-handle release occur consecutively under
            # this owner's GIL. A reused runnable remains pinned until its last
            # queued invocation completes. Unscheduled reusable handles return false.
            with _scope(platform):
                if platform.call("completeCallback", handle):
                    platform.bridge.xt_release_handle(handle)
        except BaseException:
            if original_error is None:
                raise
