"""Plugin Pill wire v1: native IDs/CAS, owner callbacks, selection-bound DTOs."""

import re
from types import MappingProxyType

from ._callbacks import admitted_id
from ._java_types import ArrayList, Object
from ._pill_types import BasePill, PillCreator, PillInfo, PillType, LayoutDraft, content, int32
from ._platform import RuntimeStateError, UnsupportedSurfaceError


def opaque(value, name):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 128:
        raise RuntimeStateError(f"native pill {name} must be a bounded nonempty string")
    return value


class NativePillId(int):
    """An opaque layout ID from native, even if it equals an own Android alias."""


class NativeLayout:
    def __init__(self, owner):
        self.owner = owner
        self.draft = LayoutDraft()
        self.revision = None
        self.selected = -1
        self.infinite = None
        self.saved_options = None
        self.known_native = set()

    @property
    def dirty(self):
        return self.draft.dirty or self.draft.loaded and self.saved_options != (type(self.selected), self.selected, self.infinite)

    def public_id(self, native_id):
        value = int32(native_id)
        if value == -1: return -1
        for android_id, native in self.owner.mappings.items():
            if native == value: return android_id
        return NativePillId(value)

    def native_id(self, public_id):
        value = int32(public_id)
        if isinstance(public_id, NativePillId) or value == -1: return value
        if value in self.owner.mappings: return self.owner.mappings[value]
        if 1 <= value <= 15 or value in self.known_native: return value
        raise UnsupportedSurfaceError(f"pill {value} has no native ID mapping; register it first")

    def refresh(self, force=False):
        self.owner.require("pillGetLayout")
        if self.draft.loaded and not force:
            return  # Original live-list ADT, not one new native CAS receipt per getter.
        result = self.owner.call("pillGetLayout")
        if not isinstance(result, dict) or result.get("idSpace") != "native" or type(result.get("mappingVersion")) is not int or result["mappingVersion"] != 1:
            raise RuntimeStateError("unsupported native pill layout schema")
        revision = opaque(result.get("revision"), "layout revision")
        rows = result.get("mappings")
        if not isinstance(rows, list) or len(rows) > 4096: raise RuntimeStateError("invalid native pill mappings")
        mappings = {}
        for row in rows:
            if not isinstance(row, dict): raise RuntimeStateError("invalid native pill mapping")
            android, native = int32(row.get("androidId")), int32(row.get("nativeId"))
            if android in mappings or native in mappings.values() or native < 10000:
                raise RuntimeStateError("duplicate or reserved native pill mapping")
            mappings[android] = native
        active, hidden = result.get("active"), result.get("hidden")
        if not isinstance(active, list) or not isinstance(hidden, list) or len(active) + len(hidden) > 8192:
            raise RuntimeStateError("invalid native pill layout lists")
        for value in active + hidden:
            if type(value) is not int or not 0 < value < 2 ** 31: raise RuntimeStateError("invalid native layout ID")
        if len(set(active + hidden)) != len(active + hidden): raise RuntimeStateError("native pill layout is not disjoint/unique")
        selected, infinite = int32(result.get("selected")), result.get("infiniteScrolling")
        if selected != -1 and selected not in active or type(infinite) is not bool:
            raise RuntimeStateError("invalid native selection/scrolling state")
        self.owner.accept_mappings(mappings)
        self.known_native.update(active + hidden)
        if self.dirty and not force:
            return  # Preserve the old revision too: save must detect a native CAS conflict.
        self.draft.accept([self.public_id(value) for value in active], [self.public_id(value) for value in hidden], force=True)
        self.revision, self.selected, self.infinite = revision, self.public_id(selected), infinite
        self.saved_options = (type(self.selected), self.selected, self.infinite)

    def save(self):
        if not self.draft.loaded: self.refresh()
        active = [self.native_id(value) for value in self.draft.active]
        hidden = [self.native_id(value) for value in self.draft.hidden]
        if len(set(active + hidden)) != len(active + hidden): raise ValueError("pill layout lists must be unique and disjoint")
        selected = self.native_id(self.selected)
        if selected not in active: selected = -1
        if type(self.infinite) is not bool: raise TypeError("infiniteScrolling must be Bool")
        result = self.owner.call("pillSaveLayout", {"revision": self.revision, "idSpace": "native", "active": active,
            "hidden": hidden, "selected": selected, "infiniteScrolling": self.infinite})
        if result is not None: raise RuntimeStateError("pillSaveLayout must return null")
        self.refresh(force=True)  # Retain the native merged dormant IDs and next revision.


class PillRegistration:
    def __init__(self, owner, info, prototype, lease):
        self.owner, self.info, self.prototype, self.lease = owner, info, prototype, lease
        self.native_id = None
        self.sessions = {}
        self.scope = None

    def context(self, raw):
        if not isinstance(raw, dict): raise RuntimeStateError("pill callback routing context must be an object")
        expected = (self.lease.id, self.native_id, int(self.info.id))
        if type(raw.get("nativeId")) is not int or type(raw.get("androidId")) is not int or (raw.get("id"), raw.get("nativeId"), raw.get("androidId")) != expected:
            raise RuntimeStateError("pill callback changed its registration identity")
        slot, record = raw.get("account"), raw.get("accountRecordId")
        if type(slot) is not int or not 0 <= slot < 2 ** 31 or not isinstance(record, str) or not re.fullmatch(r"-?\d{1,19}", record) or not -(2 ** 63) <= int(record) < 2 ** 63:
            raise RuntimeStateError("pill callback has an invalid account identity")
        return MappingProxyType({"id": self.lease.id, "nativeId": self.native_id, "androidId": int(self.info.id),
            "account": slot, "accountRecordId": record, "selection": opaque(raw.get("selection"), "selection"),
            "generation": opaque(raw.get("generation"), "account generation")})

    def retire_session(self, selection=None):
        selected = list(self.sessions) if selection is None else [selection]
        for selection in selected:
            session = self.sessions.pop(selection, None)
            if session is None: continue
            pill, _ = session
            def retired(value): raise RuntimeStateError("pill selection is retired")
            pill._publish = retired

    def publish(self, pill, context, value):
        self.owner.platform.check_worker()
        session = self.sessions.get(context["selection"])
        if not self.lease.open or session is None or session[0] is not pill or session[1] != context:
            raise RuntimeStateError("pill update belongs to a retired selection")
        result = self.owner.call("pillUpdate", self.lease.id, dict(content(value), selection=context["selection"]))
        if result is not None: raise RuntimeStateError("pillUpdate must return null")

    def start(self, raw):
        context = self.context(raw)
        scope = (context["account"], context["accountRecordId"], context["generation"])
        if scope != self.scope:
            self.retire_session()
            self.scope = scope
            if not self.owner.layout.dirty: self.owner.layout.draft.loaded = False
        existing = self.sessions.get(context["selection"])
        if existing is not None and existing[1] == context: return
        if len(self.sessions) >= 8: raise RuntimeStateError("native pill selection budget exceeded")
        with self.owner.client.hook_scope(context["account"]):
            pill = self.prototype or self.info.creator.create(self.owner.platform.ui_context, None)
            self.prototype = None
            if int32(pill.getPillId()) != int(self.info.id): raise ValueError("BasePill.getPillId changed its registered Android ID")
            self.sessions[context["selection"]] = (pill, context)
            pill.pill_context = context
            pill._publish = lambda value: self.publish(pill, context, value)
            pill.onPillSelected()
            pill.onStackVisibilityChanged(True)

    def event(self, name, raw, *args):
        context = self.context(raw)
        session = self.sessions.get(context["selection"])
        if session is None or session[1] != context:
            raise RuntimeStateError("pill callback belongs to a retired selection")
        pill, _ = session
        with self.owner.client.hook_scope(context["account"]):
            if name == "update":
                if len(args) != 1 or type(args[0]) is not bool: raise TypeError("pill force must be Bool")
                pill.onUpdateData(args[0])
            elif name == "tap": pill.onPillClicked()
            elif name == "longPress":
                value = pill.onPillLongClicked()
                if type(value) is not bool: raise TypeError("BasePill.onPillLongClicked must return Bool")
                return value
        return None

    def stop(self, raw):
        # A stop is local cleanup, never a deferred native UI error.
        context = None
        try:
            context = self.context(raw)
            session = self.sessions.get(context["selection"])
            if session is None or session[1] != context: return
            pill, _ = session
            pill._publish = None
            with self.owner.client.hook_scope(context["account"]):
                for call in (lambda: pill.onStackVisibilityChanged(False), pill.onPillUnselected):
                    try: call()
                    except BaseException: self.owner.platform.callbacks.report_error("pill:stop")
        except BaseException:
            self.owner.platform.callbacks.report_error("pill:stop")
        finally:
            if context is not None:
                session = self.sessions.get(context["selection"])
                if session is not None and session[1] == context: self.retire_session(context["selection"])


class Pills:
    methods = ("pillRegister", "pillUpdate", "pillUnregister", "pillGetLayout", "pillSaveLayout")
    def __init__(self, platform, client):
        self.platform, self.client = platform, client
        self.entries, self.mappings = {}, {}
        self.layout = NativeLayout(self)

    def require(self, member):
        self.platform.check_worker()
        if not self.platform.supported(member): raise UnsupportedSurfaceError(f"native provider does not export {member}")
        self.platform.loader.require_permission("ui", member, plugin_id=self.platform.plugin_id)
        if member in ("pillGetLayout", "pillSaveLayout"):
            self.platform.loader.require_permission("settings", member, plugin_id=self.platform.plugin_id)

    def call(self, member, *args):
        self.require(member)
        return self.platform.call(member, *args)

    def accept_mappings(self, mappings):
        for android, native in mappings.items():
            if android in self.mappings and self.mappings[android] != native:
                raise RuntimeStateError("native changed a persistent pill ID mapping")
            if any(other != android and existing == native for other, existing in self.mappings.items()):
                raise RuntimeStateError("native reused a persistent pill ID")
        self.mappings.update(mappings)

    def register(self, info):
        self.platform.check_worker()
        if info is None: return
        if not isinstance(info, PillInfo): raise TypeError("PillRegistry.register requires PillInfo")
        if int(info.id) == -1 or 1 <= int(info.id) <= 15: raise ValueError("built-in pill IDs and -1 are reserved")
        if int(info.id) in self.entries: raise RuntimeStateError("pill is already registered; unregister it before replacing it")
        if not self.platform.supported("pillRegister"): raise UnsupportedSurfaceError("native provider does not export pillRegister")
        self.platform.loader.require_permission("ui", "pillRegister", plugin_id=self.platform.plugin_id)
        prototype = info.creator.create(self.platform.ui_context, None)
        if int32(prototype.getPillId()) != int(info.id): raise ValueError("PillInfo and BasePill Android IDs differ")
        interval = prototype.getRefreshInterval()
        if type(interval) is not int or not 0 <= interval <= 3_600_000: raise ValueError("pill interval must be 0...3600000 milliseconds")
        title = str(info.name)
        if len(title) > 128 or len(title.encode("utf-8")) > 512: raise ValueError("pill title exceeds native bounds")
        descriptor = {"androidId": int(info.id), "title": title, "refreshIntervalMs": interval}
        if isinstance(info.iconRes, str):
            symbol = str(info.iconRes).removeprefix("sf:")
            if not symbol or len(symbol.encode("utf-8")) > 128: raise ValueError("pill symbol must be bounded SF Symbol text")
            descriptor["symbol"] = symbol
        elif info.iconRes != 0:
            raise UnsupportedSurfaceError("numeric Android pill drawable IDs need an explicit SF Symbol mapping")
        lease = self.platform.callbacks.new("pill", lambda ident: self.call("pillUnregister", ident))
        entry = PillRegistration(self, info, prototype, lease)
        def retired():
            entry.retire_session()
            entry.prototype = None
            if self.entries.get(int(info.id)) is entry: self.entries.pop(int(info.id), None)
        lease.on_close = retired
        try:
            callbacks = {"start": lease.wrap(entry.start), "update": lease.wrap(lambda context, force: entry.event("update", context, force)),
                "tap": lease.wrap(lambda context: entry.event("tap", context)),
                "longPress": lease.wrap(lambda context: entry.event("longPress", context)), "stop": lease.wrap(entry.stop)}
            reply = self.call("pillRegister", descriptor, callbacks)
            lease.id = admitted_id(reply)
            lease.native_owned = True
            entry.native_id = int32(reply.get("nativeId"))
            if type(reply.get("androidId")) is not int or reply["androidId"] != int(info.id) or entry.native_id < 10000 or type(reply.get("mappingVersion")) is not int or reply["mappingVersion"] != 1:
                raise RuntimeStateError("invalid native pill registration identity")
            if type(reply.get("refreshIntervalMs")) is not int or not 0 <= reply["refreshIntervalMs"] <= 3_600_000:
                raise RuntimeStateError("invalid native pill refresh interval")
            self.accept_mappings({int(info.id): entry.native_id})
        except BaseException as error:
            if lease.id is not None:
                try: self.call("pillUnregister", lease.id)
                except BaseException as cleanup: error.add_note("pill admission cleanup failed: " + type(cleanup).__name__)
                finally: lease.close()
            else: lease.close()
            raise
        self.entries[int(info.id)] = entry
        info.nativeId, info.registrationId = entry.native_id, lease.id

    def unregister(self, android_id):
        self.platform.check_worker()
        entry = self.entries.get(int32(android_id))
        if entry is None: return
        try:
            result = self.call("pillUnregister", entry.lease.id)
            if type(result) is not bool: raise RuntimeStateError("pillUnregister must return Bool")
        finally: entry.lease.close()

    def clear(self):
        for entry in list(self.entries.values()): entry.retire_session()
        self.entries.clear()
        self.mappings.clear()
        self.layout = NativeLayout(self)


def install(platform, client):
    from virtualjava import get_registered, register_class
    pills = Pills(platform, client)
    platform.pills = pills

    class Registry(Object):
        PillInfo, PillCreator, PillType = PillInfo, PillCreator, PillType
        register = staticmethod(pills.register)
        unregister = staticmethod(pills.unregister)
        @staticmethod
        def getPillInfo(id):
            entry = pills.entries.get(int32(id))
            if entry is not None: return entry.info
            if 1 <= id <= 15: raise UnsupportedSurfaceError("wire v1 does not expose native-only PillInfo descriptors")
            return None
        @staticmethod
        def isRegistered(id): return Registry.getPillInfo(id) is not None
        @staticmethod
        def createPill(id, context, resourcesProvider=None):
            info = Registry.getPillInfo(id)
            return info.creator.create(context, resourcesProvider) if info is not None else None
        @staticmethod
        def getRegisteredPills(): raise UnsupportedSurfaceError("wire v1 has no global native pill descriptor enumeration")
        @staticmethod
        def getRegisteredIds(): raise UnsupportedSurfaceError("wire v1 has no global native pill registry enumeration")
        @staticmethod
        def beginTransaction(): raise UnsupportedSurfaceError("wire v1 has no native registration batching operation")
        endTransaction = beginTransaction

    config = get_registered("app.exteraless.pillstack.PillStackConfig")
    from ._config import ConfigItem, _number
    class LayoutValue(ConfigItem):
        def __init__(self, field, previous):
            super().__init__(previous._store, previous._identity)
            self.field, self._scalar_getter = field, previous._scalar_getter
        @property
        def value(self):
            pills.layout.refresh()
            if self.field == "lastActivePillId": return pills.layout.selected
            if self.field == "infiniteScrolling": return pills.layout.infinite
            values = pills.layout.draft.active if self.field == "activePillsRaw" else pills.layout.draft.hidden
            if len({int(value) for value in values}) != len(values):
                raise UnsupportedSurfaceError("raw pill layout aliases are ambiguous; use the typed mutable layout lists")
            return ",".join(str(int(value)) for value in values)
        def _set(self, value, kind):
            expected = "int" if self.field == "lastActivePillId" else "bool" if self.field == "infiniteScrolling" else "text"
            if kind != expected: raise TypeError(f"ConfigItem is not {kind}")
            _number(value, kind)
            if not pills.layout.draft.loaded: pills.layout.refresh()
            if self.field == "lastActivePillId": pills.layout.selected = value
            elif self.field == "infiniteScrolling": pills.layout.infinite = value
            else:
                values = [int32(int(item.strip())) for item in value.split(",") if item.strip()]
                if any(item in pills.mappings and item in pills.layout.known_native and pills.mappings[item] != item for item in values):
                    raise UnsupportedSurfaceError("raw pill layout ID is ambiguous; preserve the native ID object from the mutable list")
                target = pills.layout.draft.active if self.field == "activePillsRaw" else pills.layout.draft.hidden
                target[:] = values
            pills.layout.save()
    for field in ("activePillsRaw", "hiddenPillsRaw", "lastActivePillId", "infiniteScrolling"):
        type.__setattr__(config, field, LayoutValue(field, getattr(config, field)))
    def active(): pills.layout.refresh(); return pills.layout.draft.active
    def hidden(): pills.layout.refresh(); return pills.layout.draft.hidden
    def save_layout(active, hidden):
        if not pills.layout.draft.loaded: pills.layout.refresh()
        active, hidden = list(active), list(hidden)
        for value in active + hidden: int32(value)
        pills.layout.draft.active[:] = active
        pills.layout.draft.hidden[:] = hidden
        pills.layout.save()
    def set_active(id, enabled):
        if type(enabled) is not bool: raise TypeError("pill active flag must be Bool")
        if not pills.layout.draft.loaded: pills.layout.refresh()
        target = pills.layout.native_id(id)
        for values in (pills.layout.draft.active, pills.layout.draft.hidden):
            values[:] = [value for value in values if pills.layout.native_id(value) != target]
        (pills.layout.draft.active if enabled else pills.layout.draft.hidden).append(id)
        pills.layout.save()
    def last_active(): pills.layout.refresh(); return pills.layout.selected
    def save_last(id):
        if not pills.layout.draft.loaded: pills.layout.refresh()
        pills.layout.selected = id
        pills.layout.save()
    def load(force=False): pills.layout.refresh(force=bool(force))
    def unavailable(*args): raise UnsupportedSurfaceError("wire v1 does not expose global layout reset/registry invalidation")
    for name, fn in {"getActivePills": active, "getHiddenPills": hidden, "hasActivePills": lambda: bool(active()),
        "getLastActivePillId": last_active, "saveLastActivePillId": save_last, "savePillsLayout": lambda: pills.layout.save(),
        "saveLayout": save_layout, "setPillActive": set_active, "loadConfig": load, "init": load,
        "isConfigLoaded": lambda: pills.layout.draft.loaded, "sanitizePills": load,
        "resetLayout": unavailable, "notifySettingsChanged": unavailable}.items():
        type.__setattr__(config, name, staticmethod(fn))
    Registry.activatePill = staticmethod(lambda id: set_active(id, True))
    register_class("app.exteraless.pillstack.PillRegistry", Registry)
