"""Real native menu/file/intent admission, with per-registration callback leases."""

import json

from ._callbacks import admitted_id
from ._platform import RuntimeStateError, UnsupportedSurfaceError


class Registrations:
    def __init__(self, platform):
        self.platform = platform
        self.entries = {}
        self.menu_keys = {}
        self.next_id = 0

    def add(self, kind, model, callback, on_retire=None):
        platform = self.platform
        platform.check_worker()
        public_id = None
        signature = None
        if kind == "menu":
            signature = json.dumps(model, sort_keys=True, ensure_ascii=False)
            public_id = model.get("item_id") or self.menu_keys.get(signature)
            if not public_id:
                self.next_id += 1
                public_id = f"{platform.plugin_id}_{self.next_id}"
            model = dict(model, item_id=public_id)
        lease = platform.callbacks.new(kind, lambda ident: platform.call(kind + "Remove", ident))
        try:
            wrapped = lease.wrap(callback)
            lease.id = admitted_id(platform.call(kind + "Register", model, wrapped))
            lease.native_owned = True
        except BaseException:
            lease.close()
            raise
        public_id = public_id or lease.id
        old = self.entries.pop((kind, public_id), None)
        if old is not None:
            old.close()  # Native atomically replaced the same menu/item id.
        self.entries[(kind, public_id)] = lease
        def retired():
            if self.entries.get((kind, public_id)) is lease:
                self.entries.pop((kind, public_id), None)
            if on_retire is not None:
                on_retire(public_id)
        lease.on_close = retired
        if signature is not None: self.menu_keys[signature] = public_id
        return public_id

    def remove(self, kind, ident):
        self.platform.check_worker()
        lease = self.entries.pop((kind, str(ident)), None)
        if lease is None:
            raise LookupError(f"unknown {kind} registration {ident!r}")
        lease.dispose()
        if kind == "menu":
            self.menu_keys = {key: value for key, value in self.menu_keys.items() if value != str(ident)}


def install(platform, base, files):
    registry = Registrations(platform)
    platform.registrations = registry

    def add_menu(instance, menu_item_data, text=None, *, on_click=None, condition=None,
                 priority=0, icon=None, subtext=None, item_id=None):
        if isinstance(menu_item_data, str) and text is not None:
            menu_item_data = base.MenuItemData(menu_item_data, text, on_click, item_id, icon, subtext, condition, priority)
        elif text is not None or any(value is not None for value in (on_click, condition, icon, subtext, item_id)) or priority:
            raise TypeError("use either MenuItemData or individual menu fields")
        if not isinstance(menu_item_data, base.MenuItemData):
            raise TypeError("add_menu_item expects MenuItemData")
        platform.check_plugin(instance.plugin_id)
        platform.loader.require_permission("ui", "register menu", plugin_id=instance.plugin_id)
        model = {"menu_type": menu_item_data.menu_type, "text": menu_item_data.text,
                 "priority": int(menu_item_data.priority)}
        for name in ("item_id", "icon", "subtext", "condition"):
            value = getattr(menu_item_data, name)
            if value is not None:
                model[name] = value
        callback = menu_item_data.on_click
        if not callable(callback): raise TypeError("menu on_click must be callable")
        def native_click(event):
            if not isinstance(event, dict) or type(event.get("account")) is not int or not 0 <= event["account"] < 2 ** 31:
                raise RuntimeStateError("menu callback requires its captured native account slot")
            with platform.loader.client_utils.hook_scope(event["account"]):
                callback(platform.menu_context(event))
            return None
        ident = registry.add("menu", model, native_click)
        instance._exteraless_state("_exteraless_menu_callbacks", dict)[ident] = menu_item_data.on_click
        return ident

    def remove_menu(instance, item_id):
        platform.check_plugin(instance.plugin_id)
        registry.remove("menu", item_id)
        instance._exteraless_state("_exteraless_menu_callbacks", dict).pop(item_id, None)

    base.BasePlugin.add_menu_item = add_menu
    base.BasePlugin.remove_menu_item = remove_menu

    services = base.PluginServices

    def register_file(plugin_id, ext, whitelist, blacklist, has_icon, callback=None):
        platform.check_plugin(plugin_id)
        if has_icon:
            raise UnsupportedSurfaceError("Android file-icon factories require an iOS icon model")
        if not callable(callback):
            raise TypeError("file registration requires a callable on_click")
        def native_click(context):
            from ._java_types import File
            context = dict(context)
            if isinstance(context.get("file"), str):
                context["file"] = File(context["file"])
            callback(context)
            return None
        def retired(ident):
            controller = files.FilesController
            key = (plugin_id, str(ext).lstrip(".").lower())
            with controller._lock:
                if controller._registrations.get(key, {}).get("secret") == ident:
                    controller._registrations.pop(key, None)
        return registry.add("file", {"extension": ext, "whitelist": json.loads(whitelist) if whitelist else [],
                                     "blacklist": json.loads(blacklist) if blacklist else [], "icon": False}, native_click, retired)

    def register_intent(plugin_id, before, filters, priority, callback):
        platform.check_plugin(plugin_id)
        platform.loader.require_permission("intents", "register intent", plugin_id=plugin_id)
        def native_intent(context):
            result = callback(context)
            if before:
                if type(result) is not bool:
                    raise TypeError("before intent callback must return Bool")
                return result
            return None
        def retired(ident):
            manager = intents.IntentsManager
            with manager._lock:
                manager._handlers.pop(ident, None)
                bucket = manager._by_plugin.get(plugin_id)
                if bucket is not None:
                    bucket.discard(ident)
                    if not bucket:
                        manager._by_plugin.pop(plugin_id, None)
        return registry.add("intent", {"before": bool(before), "filters": json.loads(filters),
                                       "priority": int(priority)}, native_intent, retired)

    services.registerFileHandler = register_file
    services.unregisterFileHandler = lambda plugin_id, ext, ident: (platform.check_plugin(plugin_id), registry.remove("file", ident))[-1]
    services.fileIconsSupported = lambda: False
    services.registerIntentHandler = register_intent
    services.unregisterIntentHandler = lambda plugin_id, ident: (platform.check_plugin(plugin_id), registry.remove("intent", ident))[-1]
    import intents
    intents._plugin_services = lambda: services
