"""Explicit iOS runtime providers for the unmodified Android SDK.

Only service boundaries are replaced. The SDK still owns PluginRecord,
BasePlugin attachment/registrations, dispatch, settings rows and callback IDs.
"""

import contextlib
import importlib
import json
import os
import threading

from ._codec import loads


class UnsupportedSurfaceError(RuntimeError):
    """The requested SDK operation has no iOS implementation."""


class RuntimeStateError(RuntimeError):
    """Missing configuration, wrong worker, or wrong plugin ownership."""


def unsupported(operation):
    def fail(*args, **kwargs):
        raise UnsupportedSurfaceError(f"{operation} is not supported by the iOS runtime")
    return fail


class _PluginServices:
    def __init__(self, platform):
        self.platform = platform

    def runOnUiThread(self, callback, delay=0):
        return self.platform.call(
            "runOnUIThread", callback, delay,
            fqcn="org.telegram.messenger.AndroidUtilities")

    def __getattr__(self, member):
        if member.startswith("_"):
            raise AttributeError(member)

        def call(*args):
            return self.platform.call(member, *args, fqcn="app.exteraless.plugins.PluginServices")
        return call


class Platform:
    """Native host calls always derive pluginId from the C interpreter state."""

    def __init__(self, bridge, plugin_id, plugins_dir, settings_dir):
        self.bridge = bridge
        self.plugin_id = plugin_id
        self.plugins_dir = plugins_dir
        self.settings_dir = settings_dir
        self.thread_id = threading.get_ident()
        self.loader = None

    def check_worker(self):
        if threading.get_ident() != self.thread_id:
            raise RuntimeStateError("iOS SDK calls must run on the plugin's owner worker")

    def check_plugin(self, plugin_id):
        self.check_worker()
        if plugin_id != self.plugin_id:
            raise RuntimeStateError(f"worker belongs to {self.plugin_id!r}, not {plugin_id!r}")

    @contextlib.contextmanager
    def mark(self, plugin_id):
        if plugin_id is not None:
            self.check_plugin(plugin_id)
            self.bridge.xt_set_plugin_id(self.plugin_id)
        yield

    def call(self, member, *args, fqcn="exteraless.ios.Runtime", op="call"):
        self.check_worker()
        return self.bridge.xt_call_host({
            "op": op, "fqcn": fqcn, "member": member,
            "args": list(args), "kwargs": {}, "instance": None, "value": None,
        })

    def _directory(self, member):
        path = self.call(member)
        if not isinstance(path, str) or not os.path.isabs(path):
            raise RuntimeStateError(f"native {member} did not return an absolute path")
        return path

    def getPluginsDir(self):
        path = self._directory("getPluginsDir")
        if os.path.normcase(os.path.realpath(path)) != os.path.normcase(self.plugins_dir):
            raise RuntimeStateError("native getPluginsDir disagrees with configure(plugins_dir)")
        return path

    def getFilesDir(self):
        return self._directory("getFilesDir")

    def getCacheDir(self):
        return self._directory("getCacheDir")

    def getVersion(self):
        version = self.call("getVersion")
        if not isinstance(version, str):
            raise RuntimeStateError("native getVersion did not return a string")
        return version

    def hasPermission(self, plugin_id, permission):
        self.check_plugin(plugin_id)
        value = self.call("hasPermission", permission)
        if type(value) is not bool:
            raise RuntimeStateError("native hasPermission must return bool")
        return value

    def checkPermission(self, plugin_id, permission, what):
        return self.hasPermission(plugin_id, permission)

    def isUnsafeMode(self):
        value = self.call("isUnsafeMode")
        if type(value) is not bool:
            raise RuntimeStateError("native isUnsafeMode must return bool")
        return value

    def log(self, plugin_id, text):
        if plugin_id not in (None, "sdk"):
            self.check_plugin(plugin_id)
        self.call("log", str(text))

    def getSetting(self, plugin_id, key, default=None):
        self.check_plugin(plugin_id)
        if not isinstance(key, str):
            raise TypeError("setting key must be a string")
        # Swift accepts a typed JSON default and distinguishes it from stored null.
        json.dumps(default, ensure_ascii=False, allow_nan=False)
        return self.call("getSetting", key, default)

    def setSetting(self, plugin_id, key, raw, reload_settings=False):
        self.check_plugin(plugin_id)
        if not isinstance(key, str):
            raise TypeError("setting key must be a string")
        if reload_settings:
            raise UnsupportedSurfaceError("reload_settings=True has no native settings-reload service")
        self.call("setSetting", key, loads(raw))

    def removeSetting(self, plugin_id, key):
        self.check_plugin(plugin_id)
        if not isinstance(key, str):
            raise TypeError("setting key must be a string")
        return self.call("removeSetting", key)

    # BasePlugin records these registrations itself BEFORE calling PythonBridge.
    # dispatch_json consumes those very records instead of an Android registry.
    def addRequestHook(self, plugin_id, name, match_substring, priority):
        self.check_plugin(plugin_id)

    def removeRequestHook(self, plugin_id, name):
        self.check_plugin(plugin_id)

    def addSendMessageHook(self, plugin_id, priority):
        self.check_plugin(plugin_id)

    def removeSendMessageHook(self, plugin_id):
        self.check_plugin(plugin_id)

    def selected_account(self):
        value = self.call("selectedAccount", fqcn="org.telegram.messenger.UserConfig", op="get")
        if type(value) is not int or not -(2 ** 31) <= value < 2 ** 31:
            raise RuntimeStateError("native selectedAccount must be an Int32")
        return value

    def install(self, loader, dependencies):
        self.loader = loader
        self.dependencies = dependencies
        base = importlib.import_module("base_plugin")
        settings = importlib.import_module("plugin_settings")
        files = importlib.import_module("file_utils")
        android = importlib.import_module("android_utils")
        client = importlib.import_module("client_utils")
        services = _PluginServices(self)

        base.PythonBridge = self
        loader._permissions_class = self

        def has_permission(permission, plugin_id=None):
            owner = plugin_id or loader.caller_plugin_id()
            if owner is None:
                return True
            return self.hasPermission(owner, permission)

        def require_permission(permission, what, detail=None, plugin_id=None):
            if not has_permission(permission, plugin_id):
                raise PermissionError(f"plugin {self.plugin_id!r}: {what} requires {permission!r}")

        # A missing/broken native provider must not take the SDK's desktop
        # no-JVM permissive fallback in an actual embedded client.
        loader.has_permission = has_permission
        loader.require_permission = require_permission
        loader.unsafe_mode = self.isUnsafeMode
        base.PluginServices = services
        android._bridge_cache = self
        android._services_cache = services
        client._plugin_services = lambda: services
        client.get_selected_account = self.selected_account
        files._plugin_services = lambda: services
        files.get_plugins_dir = self.getPluginsDir
        files.get_files_dir = self.getFilesDir
        files.get_cache_dir = self.getCacheDir
        files._media_cache_dir = lambda: None
        files._app_cache_dir = self.getCacheDir
        original_own_roots = files._own_roots

        def own_roots(plugin_id):
            self.check_plugin(plugin_id)
            return list(dict.fromkeys([
                *original_own_roots(plugin_id),
                files._real(self.getFilesDir()), files._real(self.getCacheDir()),
            ]))

        files._own_roots = own_roots
        loader.java_runtime_mark = self.mark
        loader._plugins_dir_cached = self.plugins_dir
        loader._ensure_requirements = dependencies.ensure_requirements
        loader._dependency_available = dependencies.is_provided
        if loader.pip_controller is not None:
            pip = loader.pip_controller
            pip.ensure_requirements = dependencies.ensure_requirements
            pip.is_provided = dependencies.is_provided
            pip.bundled_version = dependencies.bundled_version
            pip.installed_packages = dependencies.installed_packages
            pip.remove_requirements = dependencies.remove_requirements
            pip.restore_sys_path = dependencies.restore_path
            pip._fetch_pypi_json = unsupported("runtime PyPI dependency resolution")
            pip._download_and_install = unsupported("runtime wheel installation")

        def forward_log(level, text):
            if text:
                self.log(self.plugin_id, f"[{level}] {text}")
        loader._forward_log = forward_log

        # The Android methods swallow bridge failures. At the iOS boundary a
        # failed persistent write must fail the invocation, not report success.
        def get_setting(instance, key, default=None):
            plugin_id = instance.plugin_id or self.plugin_id
            value = self.getSetting(plugin_id, key, default)
            return settings.coerce_value(value, default)

        def set_setting(instance, key, value, reload_settings=False):
            plugin_id = instance.plugin_id or self.plugin_id
            raw = json.dumps(value, ensure_ascii=False, allow_nan=False)
            try:
                self.setSetting(plugin_id, key, raw, reload_settings)
            except Exception:
                instance._exteraless_drop_settings_cache()
                raise
            instance._exteraless_drop_settings_cache()
            settings.invalidate(plugin_id)

        def log(instance, msg):
            self.log(instance.plugin_id or self.plugin_id, str(msg))

        base.BasePlugin.get_setting = get_setting
        base.BasePlugin.set_setting = set_setting
        base.BasePlugin.log = log
        for name in ("export_settings", "import_settings", "add_menu_item", "remove_menu_item",
                     "hook_method", "hook_all_methods", "hook_all_constructors", "unhook_method"):
            setattr(base.BasePlugin, name, unsupported(f"BasePlugin.{name}"))

        # plugin_settings otherwise relies on Android exportSettings/replaceSettings.
        # Keep the SDK's coercion rules, but read/write each key through native storage.
        def module_get(plugin_id, key, default=None):
            value = self.getSetting(plugin_id, key, default)
            return settings.coerce_value(value, default)

        def module_set(plugin_id, key, value, reload_settings=False):
            raw = json.dumps(value, ensure_ascii=False, allow_nan=False)
            self.setSetting(plugin_id, key, raw, reload_settings)
            loader.invalidate_settings_mirror(plugin_id)

        def module_remove(plugin_id, key):
            self.removeSetting(plugin_id, key)
            loader.invalidate_settings_mirror(plugin_id)

        settings._bridge = self
        settings.get_setting = module_get
        settings.set_setting = module_set
        settings.remove_setting = module_remove
        settings.get_settings = unsupported("plugin_settings.get_settings (enumeration)")
        settings._save_settings_to_file = unsupported("plugin_settings._save_settings_to_file (bulk replace)")
