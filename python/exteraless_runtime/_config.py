"""Source-pinned Config classes reading the actual public native settings store.

No Android default or inventory candidate key supplies an absent iOS setting.
Unsupported utility/storage operations retain their exact source method names.
"""

import math
import struct
import json
from collections.abc import Set

from . import _config_manifest as manifest
from ._java_types import ArrayList, Boolean, Object
from ._platform import RuntimeStateError, UnsupportedSurfaceError


def _number(value, kind):
    if kind == "bool":
        if isinstance(value, Boolean): return value.booleanValue()
        if type(value) is not bool: raise TypeError("Config Bool requires a boolean")
        return value
    if kind in ("int", "long"):
        if not isinstance(value, int) or isinstance(value, bool): raise TypeError("Config integer requires an integer")
        bits = 32 if kind == "int" else 64
        if not -(2 ** (bits - 1)) <= value < 2 ** (bits - 1): raise OverflowError("Config integer is out of range")
        return int(value)
    if kind == "float":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise TypeError("Config Float requires a finite number")
        try: result = struct.unpack("!f", struct.pack("!f", value))[0]
        except OverflowError: raise OverflowError("Config Float is out of range") from None
        if not math.isfinite(result): raise OverflowError("Config Float is out of range")
        return result
    if kind == "text":
        if not isinstance(value, str): raise TypeError("Config String requires text")
        return str(value)
    raise UnsupportedSurfaceError(f"ConfigItem {kind} needs an explicit native data codec")


class ConfigItem(Object):
    _fqcn = "tw.nekomimi.nekogram.config.ConfigItem"
    configTypeBool, configTypeInt, configTypeString = 0, 1, 2
    configTypeSetInt, configTypeMapIntInt, configTypeLong, configTypeFloat, configTypeBoolLinkInt = 3, 4, 5, 6, 7
    _types = {"bool": 0, "int": 1, "text": 2, "set<int>": 3, "map<int,int>": 4, "long": 5, "float": 6}

    def __init__(self, store, identity=None, *args):
        if not isinstance(store, ConfigStore) or identity not in manifest.BINDINGS:
            raise UnsupportedSurfaceError("ConfigItem construction requires a registered native ClientSettings definition")
        self._store, self._identity, self._scalar_getter = store, identity, False

    @property
    def key(self): return manifest.BINDINGS[self._identity]["source_key"]

    @property
    def type(self): return self._types[manifest.BINDINGS[self._identity]["type"]]

    @property
    def value(self): return self._store.read(self._identity)

    @property
    def defaultValue(self):
        return self._store.default(self._identity)

    def getKey(self): return self.key
    def Bool(self): return self._typed("bool")
    def Int(self): return self._typed("int")
    def Long(self): return self._typed("long")
    def Float(self): return self._typed("float")
    def String(self):
        value = self.value
        return ("true" if value else "false") if type(value) is bool else str(value)

    def _typed(self, kind):
        if manifest.BINDINGS[self._identity]["type"] != kind: raise TypeError(f"ConfigItem is not {kind}")
        return _number(self.value, kind)

    def _set(self, value, kind):
        if manifest.BINDINGS[self._identity]["type"] != kind: raise TypeError(f"ConfigItem is not {kind}")
        self._store.write(self._identity, _number(value, kind))

    def setConfigBool(self, value): self._set(value, "bool")
    def setConfigInt(self, value): self._set(value, "int")
    def setConfigLong(self, value): self._set(value, "long")
    def setConfigFloat(self, value): self._set(value, "float")
    def setConfigString(self, value): self._set("" if value is None else value, "text")
    def toggleConfigBool(self):
        value = not self.Bool()
        self.setConfigBool(value)
        return value

    def __call__(self):
        if not self._scalar_getter:
            raise TypeError("this ConfigItem has no source scalar getter; use Bool/Int/String")
        return self.value

    def changed(self, value):
        raise UnsupportedSurfaceError("ConfigItem.changed stages Android cache state; use a typed native setter")

    def saveConfig(self):
        raise UnsupportedSurfaceError("ConfigItem.saveConfig has no detached Android cache; typed setters persist natively")


class ConfigMeta(type):
    def __getattr__(cls, name):
        aliases = type.__getattribute__(cls, "_field_aliases")
        if name in aliases:
            target = aliases[name]
            return getattr(cls, target[0] if isinstance(target, (tuple, list)) else target)()
        raise AttributeError(f"{cls._fqcn} has no registered member {name!r}")

    def __setattr__(cls, name, value):
        alias = type.__getattribute__(cls, "_field_aliases").get(name)
        if isinstance(alias, (tuple, list)) and len(alias) == 2:
            getattr(cls, alias[1])(value)
            return
        raise AttributeError(f"{cls._fqcn}.{name} is not a writable native setting field")


class ConfigClass(Object, metaclass=ConfigMeta):
    _fqcn = "Config"
    _field_aliases = {}
    def __new__(cls): raise TypeError("Config classes expose their source static/singleton members")
    def __setattr__(self, name, value): raise AttributeError("Config singleton fields are read-only; use a typed setter")


class ConfigStore:
    def __init__(self, platform):
        self.platform = platform
        self.enums = {}

    def require(self):
        self.platform.check_worker()
        self.platform.loader.require_permission("settings", "client Config access", plugin_id=self.platform.plugin_id)

    def binding(self, identity):
        self.require()
        spec = manifest.BINDINGS[identity]
        if spec["secret"]: raise PermissionError(f"{spec['symbol']}: native credentials are private")
        if spec["key"] is None: raise UnsupportedSurfaceError(f"{spec['symbol']}: {spec['reason']}")
        return spec

    def read(self, identity):
        spec = self.binding(identity)
        value = self.platform.call("getClientSetting", spec["key"])
        if value is None:
            raise UnsupportedSurfaceError(f"{spec['symbol']}: native setting is not registered: {spec['key']}")
        return self.decode_value(spec, value)

    @staticmethod
    def decode_value(spec, value):
        if spec.get("value_codec") == "front_rear_bool":
            value = _number(value, "int")
            if value == 2:
                raise UnsupportedSurfaceError(f"{spec['symbol']}: native Ask camera mode has no legacy Front/Rear Bool value")
            if value not in (0, 1): raise RuntimeStateError("native video-message camera facing must be Front, Rear or Ask")
            return value == 1
        return _number(value, spec["type"])

    @staticmethod
    def encode_value(spec, value):
        value = _number(value, spec["type"])
        return int(value) if spec.get("value_codec") == "front_rear_bool" else value

    def write(self, identity, value):
        spec = self.binding(identity)
        value = self.encode_value(spec, value)
        if self.platform.call("setClientSetting", spec["key"], value) is not None:
            raise RuntimeStateError("setClientSetting must return null after a durable public write")

    def default(self, identity):
        spec = self.binding(identity)
        raw = self.platform.call("getClientSettingMetadata", spec["key"])
        if raw is None: raise UnsupportedSurfaceError(f"{spec['symbol']}: native setting definition is not registered")
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > 262_144:
            raise RuntimeStateError("native setting metadata must be bounded opaque JSON")
        from ._codec import loads
        metadata = loads(raw)
        expected_type = "int" if spec["type"] == "long" or spec.get("value_codec") == "front_rear_bool" else spec["type"]
        if not isinstance(metadata, dict) or metadata.get("key") != spec["key"] or metadata.get("scope") != "global" or metadata.get("type") != expected_type or "default" not in metadata:
            raise RuntimeStateError("native setting metadata disagrees with its registered binding")
        return self.decode_value(spec, metadata["default"])

    def write_many(self, values):
        native = {}
        for identity, value in values.items():
            spec = self.binding(identity)
            native[spec["key"]] = self.encode_value(spec, value)
        if self.platform.call("setClientSettings", json.dumps(native, ensure_ascii=False, allow_nan=False)) is not None:
            raise RuntimeStateError("setClientSettings must return null after an atomic public batch")

    def matches(self, kind, value):
        if kind == "boolean": return type(value) is bool or isinstance(value, Boolean)
        if kind in ("int", "long"): return isinstance(value, int) and not isinstance(value, bool)
        if kind == "float": return isinstance(value, (float, int)) and not isinstance(value, bool)
        if kind == "String": return value is None or isinstance(value, str)
        if kind in self.enums: return value is None or isinstance(value, self.enums[kind])
        return True  # Unimplemented reference-type overloads still fail by exact name.

    def invoke(self, options, args):
        found = [spec for spec in options if len(spec["parameters"]) == len(args)
                 and all(self.matches(kind, value) for kind, value in zip(spec["parameters"], args))]
        if len(found) != 1:
            raise TypeError("expected one of: " + ", ".join(spec["id"] for spec in options))
        spec = found[0]
        self.require()
        if spec["route"] == "unavailable": raise UnsupportedSurfaceError(f"{spec['id']}: {spec['reason']}")
        args = tuple(_number(value, {"boolean": "bool", "String": "text"}.get(kind, kind))
                     if kind in ("boolean", "int", "long", "float", "String") and value is not None else value
                     for kind, value in zip(spec["parameters"], args))
        if spec["route"] == "manager_get":
            value = self.platform.call("getPluginConfig", spec["field"])
            if spec["field"] == "pinned":
                if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
                    raise RuntimeStateError("native pinned plugins must be an array of IDs")
                from ._java_types import HashSet
                return HashSet(value)
            return _number(value, "bool")
        if spec["route"] == "manager_set":
            value = args[0]
            if spec["field"] == "pinned":
                if value is None: value = []
                if not isinstance(value, (Set, list, tuple)) or len(value) > 4096 or any(not isinstance(item, str) for item in value):
                    raise TypeError("pinned plugins require a bounded Set of string IDs")
                value = sorted(set(value))
            reply = self.platform.call("setPluginConfig", spec["field"], value)
            if not isinstance(reply, dict) or reply.get("accepted") is not True or not isinstance(reply.get("operationId"), str) or not reply["operationId"]:
                raise RuntimeStateError("native plugin config setter did not admit its operation")
            return None  # Java void: accepted native work, not completed mode delivery.
        if spec["route"] == "read":
            value = self.read(spec["targets"][0])
            transform = spec["transform"]
            if transform == "not": return not value
            if transform == "percent": return _number(value / 100, "float")
            if transform == "equals_one": return value == 1
            if transform == "float": return _number(value, "float")
            if transform == "enum":
                enum = self.enums[spec["enum"]]
                return enum.values()[value] if 0 <= value < len(enum.values()) else getattr(enum, spec["fallback"])
            if transform == "camera_enum": return self.enums["VideoMessagesCamera"].REAR if value else self.enums["VideoMessagesCamera"].FRONT
            return value
        if spec["route"] == "write":
            value, transform = args[0], spec["transform"]
            if transform == "not": value = not value
            elif transform in ("percent", "round"): value = math.floor(_number(value * (100 if transform == "percent" else 1), "float") + 0.5)
            elif transform == "enum": value = value.ordinal()
            elif transform == "camera_enum": value = value is self.enums["VideoMessagesCamera"].REAR
            elif value is None and spec["parameters"] == ["String"]: value = ""
            self.write(spec["targets"][0], value)
            return None
        return self.computed(spec["route"], args)

    def squareness(self): return max(0.0, min(1.0, 1.0 - self.read("appearance.avatarCorners") / 28.0))

    def dp(self, value, fractional=False):
        return self.platform.call("dpf2" if fractional else "dp", value, fqcn="org.telegram.messenger.AndroidUtilities")

    def avatar_radius(self, size, in_pixels=False, corner_type=None, has_stories=False):
        corners = self.read("appearance.avatarCorners")
        if corners <= 0: return 0
        value = (size if in_pixels else self.dp(size)) * corners / 56.0
        if has_stories: value -= self.dp(2.5, fractional=True)
        if not self.read("appearance.singleCornerRadius"):
            if corner_type is self.enums["AvatarCornerType"].FORUM: value = int(value) * 42.0 / 64.0
            elif corner_type is self.enums["AvatarCornerType"].COMMUNITY: value *= 40.0 / 72.0
        return max(0, math.ceil(value))

    def computed(self, route, args):
        if route == "force_snow":
            value = 1 if args[0] else 0
            self.write_many({"neko.actionBarDecoration": value, "nagram.chatDecoration": value})
            return None
        if route == "avatar_radius":
            size = args[0]
            in_pixels = args[1] if len(args) > 1 else False
            corner_type = args[2] if len(args) > 2 else self.enums["AvatarCornerType"].DEFAULT
            if type(corner_type) is bool:
                corner_type = self.enums["AvatarCornerType"].FORUM if corner_type else self.enums["AvatarCornerType"].DEFAULT
            return self.avatar_radius(size, in_pixels, corner_type, args[3] if len(args) > 3 else False)
        if route == "squareness": return self.squareness()
        if route == "pill_radius": return max(min(args[0], 6.0), args[0] * (1.0 - self.squareness()))
        if route == "dot_inner": return self.dp(self.squareness() + 5.0)
        if route == "dot_outer": return self.dp(self.squareness() * 2.0 + 7.0)
        if route == "dot_offset": return args[0] + (args[1] / math.sqrt(2.0) - args[0]) * self.squareness()
        if route == "section_radius": return self.read("appearance.sectionRadius")
        if route in ("separate_headers", "set_separate_headers"):
            segments = self.read("appearance.dividerStyle") == 2
            if route == "separate_headers": return segments or self.read("appearance.separateHeaders")
            self.write("appearance.separateHeaders", segments or args[0])
            return None
        if route == "language_name": return self.read("nagram.preferredTranslateTargetLang") or "app"
        if route == "seek_duration":
            value = self.read("chats.doubleTapSeekDuration")
            return (value + 1) * 5000 if 0 <= value <= 2 else 30000
        if route in ("proxy_condition", "set_proxy_condition"):
            if args[0] is None: return False if route == "proxy_condition" else None
            flag = args[0].getFlag()
            value = self.read("openextera.proxyDisableConditions")
            if route == "proxy_condition": return bool(value & flag)
            self.write("openextera.proxyDisableConditions", value | flag if args[1] else value & ~flag)
            return None
        raise UnsupportedSurfaceError(f"unimplemented Config computation: {route}")


def install(platform):
    from virtualjava import register_class
    store = ConfigStore(platform)
    platform.config_store = store
    register_class(ConfigItem._fqcn, ConfigItem)
    for name, values in manifest.ENUMS.items():
        def no_constructor(cls): raise TypeError("use the declared Java enum constants")
        attrs = {"_fqcn": "com.exteragram.messenger." + name,
                 "name": lambda self: self._name, "ordinal": lambda self: self._ordinal,
                 "__str__": lambda self: self._name, "__new__": no_constructor}
        if name == "ProxyDisableCondition": attrs["getFlag"] = lambda self: self._flag
        enum = type(name, (Object,), attrs)
        instances = []
        for ordinal, (label, flag) in enumerate(values):
            value = object.__new__(enum)
            value._name, value._ordinal, value._flag = label, ordinal, flag
            setattr(enum, label, value)
            instances.append(value)
        def values_getter(items):
            def get(): return ArrayList(items)
            return get
        enum.values = staticmethod(values_getter(tuple(instances)))
        def value_of(enum):
            def get(name):
                for value in enum.values():
                    if value.name() == name: return value
                raise ValueError("unknown " + enum._fqcn + " constant")
            return get
        enum.valueOf = staticmethod(value_of(enum))
        store.enums[name] = enum
        register_class(enum._fqcn, enum)

    installed = {}
    def item_getter(item):
        def get(): return item
        return staticmethod(get)
    def scalar_getter(identity):
        def get(): return store.read(identity)
        return staticmethod(get)
    def unsupported(name):
        def call(*args): raise UnsupportedSurfaceError(f"{name}: no reviewed native Config operation")
        return staticmethod(call)
    for fqcn, spec in manifest.CLASSES.items():
        attrs = {"_fqcn": fqcn, "_field_aliases": {}, **spec["constants"]}
        items = {identity: ConfigItem(store, identity) for identity in spec["fields"].values()}
        attrs.update({name: items[identity] for name, identity in spec["fields"].items()})
        for name, identity in spec["getters"].items():
            attrs[name] = item_getter(items[identity])
        for name, identity in spec["scalar"].items():
            if name in spec["fields"]:
                items[identity]._scalar_getter = True
            else:
                attrs[name] = scalar_getter(identity)
        for name in spec["unsupported"]:
            if name not in attrs: attrs[name] = unsupported(fqcn + "." + name)
        cls = ConfigMeta(fqcn.rsplit(".", 1)[-1], (ConfigClass,), attrs)
        if spec["singleton"]: type.__setattr__(cls, "INSTANCE", object.__new__(cls))
        installed[fqcn] = cls
        register_class(fqcn, cls)

    groups = {}
    for spec in manifest.APIS: groups.setdefault(spec["name"], []).append(spec)
    attrs = {"_fqcn": "com.exteragram.messenger.ExteraConfig", "_field_aliases": manifest.FIELD_ALIASES}
    def method(name, options):
        def call(*args): return store.invoke(options, args)
        call.__name__ = name
        return staticmethod(call)
    attrs.update({name: method(name, options) for name, options in groups.items()})
    extera = ConfigMeta("ExteraConfig", (ConfigClass,), attrs)
    register_class(extera._fqcn, extera)
    appearance = installed["app.exteraless.appearance.AppearanceConfig"]
    type.__setattr__(appearance, "centerTitle", staticmethod(extera.getCenterTitle))
    type.__setattr__(appearance, "setCenterTitle", staticmethod(extera.setCenterTitle))
    def radius(size, cornerType=0, hasStories=False):
        size = _number(size, "float")
        cornerType = _number(cornerType, "int")
        hasStories = _number(hasStories, "bool")
        types = store.enums["AvatarCornerType"].values()
        return store.avatar_radius(size, True, types[cornerType] if 0 <= cornerType < len(types) else types[0], hasStories)
    type.__setattr__(appearance, "getAvatarCorners", staticmethod(radius))
