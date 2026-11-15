"""Native persistent bulk settings and the original SDK mirror/JSON conventions."""

import json

from ._codec import loads
from ._platform import RuntimeStateError


def install(platform, base, settings):
    loader = platform.loader

    def read_values(plugin_id):
        platform.check_plugin(plugin_id)
        raw = platform.call("getSettings")
        if not isinstance(raw, str):
            raise RuntimeStateError("getSettings must return opaque JSON text")
        values = loads(raw)
        if not isinstance(values, dict) or any(not isinstance(key, str) for key in values):
            raise RuntimeStateError("getSettings must return a typed JSON object")
        values = json.loads(json.dumps(values, ensure_ascii=False, allow_nan=False))
        return dict(values)

    def update(plugin_id, values, replace=False, reload=False):
        platform.check_plugin(plugin_id)
        if not isinstance(values, dict) or any(not isinstance(key, str) for key in values):
            raise TypeError("settings must be an object with string keys")
        values = json.loads(json.dumps(values, ensure_ascii=False, allow_nan=False))
        if replace and not values:
            platform.call("clearSettings")
        else:
            platform.call("setSettings" if replace else "updateSettings", json.dumps(values, ensure_ascii=False, allow_nan=False))
        loader.invalidate_settings_mirror(plugin_id)
        if reload:
            platform.call("uiRefreshSettings")

    def reload(plugin_id):
        platform.check_plugin(plugin_id)
        loader.invalidate_settings_mirror(plugin_id)
        platform.call("uiRefreshSettings")

    def export_raw(plugin_id):
        return json.dumps(settings.encode_values(read_values(plugin_id)), ensure_ascii=False)

    def import_raw(plugin_id, raw, reload_settings=True):
        if not isinstance(loads(raw), dict): raise TypeError("importSettings requires a JSON object")
        update(plugin_id, settings.decode_values(raw), reload=reload_settings)

    def replace_raw(plugin_id, raw):
        if not isinstance(loads(raw), dict): raise TypeError("replaceSettings requires a JSON object")
        update(plugin_id, settings.decode_values(raw), replace=True)

    platform.get_settings = read_values
    platform.update_settings = update
    platform.reloadSettingsScreen = reload
    platform.exportSettings = export_raw
    platform.importSettings = import_raw
    platform.replaceSettings = replace_raw
    base.BasePlugin.export_settings = lambda instance: read_values(instance.plugin_id)
    def import_settings(instance, settings, reload_settings=True):
        update(instance.plugin_id, settings, reload=reload_settings)
    base.BasePlugin.import_settings = import_settings
    base.BasePlugin.reset_settings = lambda instance, reload_settings=True: update(
        instance.plugin_id, {}, replace=True, reload=reload_settings)
    def get_client(instance, key, default=None):
        platform.loader.require_permission("settings", "get client setting", plugin_id=instance.plugin_id)
        return platform.call("getClientSetting", key, default)
    def set_client(instance, key, value):
        platform.loader.require_permission("settings", "set client setting", plugin_id=instance.plugin_id)
        return platform.call("setClientSetting", key, value)
    base.BasePlugin.get_client_setting = get_client
    base.BasePlugin.set_client_setting = set_client
    def cached(plugin_id):
        platform.check_plugin(plugin_id)
        with settings._lock:
            return settings._cached(plugin_id)
    settings.get_settings = lambda plugin_id: dict(cached(plugin_id))
    settings._load_plugin = read_values

    def save_mirror():
        with settings._lock:
            for plugin_id, values in list(settings._settings_cache.items()):
                if settings._snapshot(values) != settings._synced.get(plugin_id):
                    update(plugin_id, values, replace=True)
                    settings._settings_cache[plugin_id] = values
                    settings._synced[plugin_id] = settings._snapshot(values)

    settings._save_settings_to_file = save_mirror

    def get_value(plugin_id, key, default=None):
        # Opaque JSON also prevents reserved transport keys inside individual
        # setting values from becoming C handles/bytes during unmarshalling.
        return settings.coerce_value(read_values(plugin_id).get(key, default), default)
    base.BasePlugin.get_setting = lambda instance, key, default=None: get_value(
        instance.plugin_id or platform.plugin_id, key, default)
    settings.get_setting = lambda plugin_id, key, default=None: settings.coerce_value(cached(plugin_id).get(key, default), default)
    settings.set_setting = lambda plugin_id, key, value, reload_settings=False: update(
        plugin_id, {key: value}, reload=reload_settings)

    def set_value(instance, key, value, reload_settings=False):
        update(instance.plugin_id or platform.plugin_id, {key: value}, reload=reload_settings)
        instance._exteraless_drop_settings_cache()
    base.BasePlugin.set_setting = set_value


def set_raw(platform, plugin_id, key, raw, reload_settings):
    value = loads(raw)
    platform.update_settings(plugin_id, {key: value}, reload=reload_settings)
