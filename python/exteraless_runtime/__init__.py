"""One-plugin iOS worker adapter for ``sdk/extera_utils/plugin_loader.py``.

The Swift bootstrap installs virtualjava and binds the native bridge first.
Importing this module alone neither installs a backend nor executes a plugin.
"""

import importlib
import os
import sys
from contextlib import contextmanager

from . import _archives, _codec, _dependencies
from ._platform import Platform, RuntimeStateError, UnsupportedSurfaceError

__all__ = [
    "configure", "metadata_json", "load_json", "unload", "dispatch_json",
    "settings_json", "setting_changed_json", "setting_click_json", "invoke_handle_json",
    "PluginLoadError", "RuntimeStateError", "UnsupportedSurfaceError",
    "bind_owner_json",
    "release_handles_json",
    "hook_priority_json",
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
    if not path.lower().endswith((".py", ".plugin", ".elyx", ".eaf")):
        raise UnsupportedSurfaceError("iOS runtime accepts .py/.plugin source and .elyx/.eaf archives")
    return path


def _metadata(path):
    if _archives.is_archive(path):
        return _archives.inspect_archive(path).metadata
    return _sdk_module("extera_utils.metadata_parser").read_metadata(path)


def metadata_json(path) -> str:
    """Static SDK metadata, including bounded archive mappings, before configure."""
    return _codec.dumps(_metadata(_source_path(path)))


def configure(plugin_id, plugins_dir, settings_dir, plugin_format="source") -> None:
    """Bind a single immutable plugin identity to the current owner worker."""
    global _state
    _archives.validate_plugin_id(plugin_id, plugin_format)
    plugins_dir = os.path.realpath(os.fspath(plugins_dir))
    settings_dir = os.path.realpath(os.fspath(settings_dir))
    if _state is not None:
        _state.check_worker()
        if (plugin_id, plugins_dir, settings_dir, plugin_format) != (
                _state.plugin_id, _state.plugins_dir, _state.settings_dir, _state.plugin_format):
            raise RuntimeStateError("an iOS interpreter can be configured for only one plugin")
        return None

    bridge = importlib.import_module("_exteraless_bridge")
    finder = importlib.import_module("virtualjava.finder")
    for name in ("xt_set_plugin_id", "xt_set_owner_token", "xt_call_host", "xt_resolve_handle",
                 "xt_register_handle", "xt_release_handle", "xt_clear_handles", "BridgeBackend"):
        if not hasattr(bridge, name):
            raise RuntimeStateError(f"native bridge is missing {name}")
    if not finder._State.installed or not isinstance(finder._State.backend, bridge.BridgeBackend):
        raise RuntimeStateError("configure requires the native virtualjava bootstrap")

    platform = Platform(bridge, plugin_id, plugins_dir, settings_dir)
    platform.plugin_format = plugin_format
    bridge.xt_set_plugin_id(plugin_id)
    platform.getPluginsDir()
    dependencies = _dependencies.create_provider()
    loader = _sdk_module("extera_utils.plugin_loader")
    if loader.plugins:
        raise RuntimeStateError("configure requires an empty SDK plugin registry")
    platform.install(loader, dependencies)
    platform.archives = _archives.ArchiveAdapter(platform)
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


def bind_owner_json(owner_json) -> None:
    """Host-only bootstrap seam: bind a native CallbackOwner token before load."""
    platform = _runtime()
    token = _codec.loads(owner_json)
    if not isinstance(token, str) or not token or len(token.encode("utf-8")) > 256 or "\0" in token:
        raise ValueError("owner token must be a nonempty bounded JSON string")
    if platform.callbacks.active or platform.owner_token not in (None, token):
        raise RuntimeStateError("callback owner identity is immutable for this interpreter")
    # The host binds C first. Repeating it here validates agreement with the
    # immutable native epoch; Python state never becomes authority for requests.
    platform.bridge.xt_set_owner_token(token)
    platform.owner_token = token
    return None


def release_handles_json(handles_json) -> None:
    """Native FIFO release seam, including silent account-replacement teardown."""
    platform = _runtime()
    handles = _codec.loads(handles_json)
    if not isinstance(handles, list) or len(handles) > 4096 or any(
            type(handle) is not int or not 0 < handle < 2 ** 63 for handle in handles):
        raise ValueError("release requires at most 4096 positive Int64 handles")
    platform.callbacks.release_handles(handles)
    return None


@contextmanager
def _scope(platform, account=None):
    platform.refresh_protected_paths()
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
    primary_error = sys.exception()
    try:
        try:
            platform.archives.cleanup()
        finally:
            platform.callbacks.end()
    except BaseException:
        if primary_error is None:
            raise
    finally:
        platform.registrations.entries.clear()
        platform.registrations.menu_keys.clear()
        platform.tl.pending.clear()
        with platform.callbacks.lock:
            platform.scheduler.tasks.clear()
        platform.controller_caches.clear()
        platform.pills.clear()
        platform.bridge.xt_clear_handles()


def load_json(path) -> str:
    """Use the SDK loader; turn its failure JSON into an exception for Swift."""
    platform = _runtime()
    path = _source_path(path)
    snapshot = _archives.snapshot_for_load(platform, path) if _archives.is_archive(path) else None
    metadata = snapshot.metadata if snapshot is not None else _metadata(path)
    if metadata["id"] != platform.plugin_id:
        raise PluginLoadError("plugin __id__ does not match the configured worker")
    if platform.loader.is_loaded(platform.plugin_id):
        unload()
    loader = platform.loader
    module_name = loader._module_name_for(platform.plugin_id)
    platform.callbacks.begin()
    try:
        with _scope(platform):
            if snapshot is not None:
                platform.archives.activate(snapshot)
            # The preserved SDK dispatcher is case-sensitive. Its archive branch
            # also serves a direct API caller with an upper-case file suffix.
            load = loader._load_elyx_plugin if snapshot is not None and not path.endswith((".elyx", ".eaf")) else loader.load_plugin
            result = _codec.loads(load(path, platform.plugin_id))
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


def _matching_priorities(platform, instance, hook, name, canonical_name=None):
    if hook not in _HOOKS:
        raise UnsupportedSurfaceError(f"unsupported TL hook protocol name {hook!r}")
    schema = platform.tl.schema
    canonical_name = canonical_name or schema.canonical_name(name)
    candidates = {name, canonical_name, *schema.hook_names(canonical_name)}
    group = "request" if hook in ("pre_request_hook", "post_request_hook") else "update" if hook == "on_update_hook" else "updates"
    # BasePlugin.add_hook stores ONE Python ledger. PluginsController.java:1726–1744
    # partitions it into exact request/update/container maps plus shared substrings.
    for pattern, substring, priority in instance.__dict__.get("_exteraless_request_hooks", ()):
        if not pattern or not isinstance(pattern, str): continue
        if not substring and schema.hook_group(pattern) != group: continue
        if any(pattern in candidate if substring else pattern == candidate for candidate in candidates):
            yield int(priority)


def hook_priority_json(hook, name, canonical_name):
    platform = _runtime(loaded=True)
    if not isinstance(name, str) or not isinstance(canonical_name, str):
        raise TypeError("hook names must be strings")
    instance = platform.loader.plugins[platform.plugin_id].instance
    with _scope(platform):
        if hook == "on_send_message_hook":
            from ._hook_registrations import send_priority
            return _codec.dumps(send_priority(instance) if platform.callbacks.active else None)
        matches = list(_matching_priorities(platform, instance, hook, name, canonical_name))
        return _codec.dumps(max(matches) if matches else None)


def _registered(instance, hook, name=None, platform=None, canonical_name=None):
    if hook == "on_send_message_hook":
        return bool(instance.__dict__.get("_exteraless_send_message_registered", False))
    return next(_matching_priorities(platform, instance, hook, name, canonical_name), None) is not None


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
    canonical_name = payload.get("canonical_name")
    if canonical_name is not None and not isinstance(canonical_name, str): raise TypeError("canonical_name must be a string")
    native_snapshot = None
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
        snapshot = value
        if isinstance(snapshot, dict) and "tl" in snapshot: native_snapshot = snapshot
        if canonical_name is None and isinstance(snapshot, dict) and "tl" in snapshot:
            metadata = snapshot.get("metadata", {})
            if hook == "post_request_hook" and isinstance(metadata, dict): canonical_name = metadata.get("canonicalName", metadata.get("requestName"))
            elif isinstance(snapshot["tl"], dict): canonical_name = snapshot["tl"].get("_")
        value = platform.tl.schema.hook_value(snapshot, request_name=(canonical_name or name) if hook == "post_request_hook" else None)
        args = (account, name, value)
        if hook == "post_request_hook":
            error = payload.get("error")
            if error is None and isinstance(snapshot, dict): error = snapshot.get("tlError")
            error = platform.tl.schema.decode(_codec.decode(error, platform.bridge))
            if native_snapshot is not None: error = platform.tl.schema.attach_context(error, native_snapshot)
            args += (error,)
        fn = getattr(loader, function)
    with _scope(platform, account):
        result = None
        if _registered(instance, hook, name, platform, canonical_name):
            result = fn(plugin_id, *args)
        strategy = "DEFAULT" if result is None else result.strategy
        if native_snapshot is not None and strategy in ("DEFAULT", "CANCEL"):
            value = native_snapshot["tl"]
        elif result is not None and result.value is not None:
            value = result.value
        return _codec.dumps({"strategy": strategy, field: value}, platform.bridge)


def settings_json() -> str:
    platform = _runtime(loaded=True)
    with _scope(platform):
        return platform.loader.get_settings_json(platform.plugin_id)


def _settings_account(account):
    if account is not None and (type(account) is not int or not 0 <= account < 2 ** 31):
        raise ValueError("settings account must be a nonnegative Int32 SDK index")
    return account


def setting_changed_json(key, value_json, account=None) -> str:
    platform = _runtime(loaded=True)
    account = _settings_account(account)
    if not isinstance(key, str):
        raise TypeError("setting key must be a string")
    _codec.loads(value_json)  # The SDK alone would turn malformed JSON into null.
    with _scope(platform, account):
        platform.loader.notify_setting_changed(platform.plugin_id, key, value_json)
    return "null"


def setting_click_json(callback_id, account=None) -> str:
    platform = _runtime(loaded=True)
    account = _settings_account(account)
    record = platform.loader.plugins[platform.plugin_id]
    if callback_id not in record.click_callbacks:
        raise LookupError(f"unknown settings callback {callback_id!r}")
    with _scope(platform, account):
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
