"""Portable PillInfo/BasePill data. Native providers own IDs, scopes and rendering.

Source: app/exteraless/pillstack/{PillRegistry,PillType}.java,
pills/BasePill.java and ExteralessCore/PillModel.swift. No Android View inheritance.
"""

import math
import time

from ._java_types import ArrayList, Object
from ._platform import UnsupportedSurfaceError


class AccessorInt(int):
    def __call__(self): return int(self)


class AccessorString(str):
    def __call__(self): return str(self)


def int32(value):
    if not isinstance(value, int) or isinstance(value, bool) or not -(2 ** 31) <= value < 2 ** 31:
        raise ValueError("pill ID must be an Int32")
    return int(value)


class PillCreator(Object):
    def __init__(self, creator=None): self._creator = creator
    def __call__(self): return self
    def create(self, context, resources_provider):
        if self._creator is None:
            raise UnsupportedSurfaceError("native-only pill creators do not expose Android views")
        callback = getattr(self._creator, "create", None)
        value = callback(context, resources_provider) if callable(callback) else self._creator(context, resources_provider)
        if not isinstance(value, BasePill):
            raise UnsupportedSurfaceError("pill creator must return a portable BasePill DTO adapter")
        return value


class PillInfo(Object):
    def __init__(self, id, name, iconRes, iconColorTop, iconColorBottom, creator):
        self.id, self.name = AccessorInt(int32(id)), AccessorString(name)
        if not self.name: raise ValueError("pill name must be nonempty")
        self.iconRes = AccessorString(iconRes) if isinstance(iconRes, str) else AccessorInt(int32(iconRes))
        self.iconColorTop, self.iconColorBottom = AccessorInt(iconColorTop), AccessorInt(iconColorBottom)
        self.creator = creator if isinstance(creator, PillCreator) else PillCreator(creator)


class PillType(Object):
    _values = []
    def __new__(cls): raise TypeError("use the declared PillType constants")
    def name(self): return self._name
    def ordinal(self): return self._values.index(self)
    def getId(self): return int(self.id)
    @classmethod
    def values(cls): return ArrayList(cls._values)
    @classmethod
    def valueOf(cls, name):
        for value in cls._values:
            if value.name() == name: return value
        raise ValueError("unknown PillType constant")


for _number, _name in enumerate(("WEATHER", "GRAM", "BTC", "USD", "CACHE", "PROXY", "GHOST", "RAM", "CPU",
                               "NET_SPEED", "DC_PING", "GOLD", "ETH", "EUR", "LAST_SEEN"), 1):
    _value = object.__new__(PillType)
    _value._name, _value.id = _name, AccessorInt(_number)
    setattr(PillType, _name, _value)
    PillType._values.append(_value)
del _number, _name, _value


def content(value):
    """Validate an explicit portable reading; absent time/progress stay absent."""
    if not isinstance(value, dict): raise TypeError("pill content must be a DTO object")
    allowed = {"title", "value", "detail", "source", "phase", "updatedAtMs", "progress", "isHighlighted"}
    if set(value) - allowed: raise UnsupportedSurfaceError("unknown pill content fields: " + ", ".join(sorted(set(value) - allowed)))
    result = dict(value)
    for key, limit in (("title", 128), ("value", 256), ("detail", 2048), ("source", 256)):
        if key in result and (not isinstance(result[key], str) or len(result[key]) > limit):
            raise ValueError(f"pill {key} must be bounded text")
    if "source" in result and not result["source"]: raise ValueError("pill source must be nonempty")
    if "title" in result and not result["title"]: raise ValueError("pill title must be nonempty")
    if "phase" in result and result["phase"] not in ("idle", "loading", "ready", "stale", "failed", "unavailable"):
        raise ValueError("unknown pill phase")
    if result.get("updatedAtMs") is not None and (type(result["updatedAtMs"]) is not int or not 0 < result["updatedAtMs"] < 2 ** 63 - 1):
        raise ValueError("pill updatedAtMs must be positive Unix milliseconds")
    if result.get("progress") is not None:
        progress = result["progress"]
        if isinstance(progress, bool) or not isinstance(progress, (int, float)) or not math.isfinite(progress) or not 0 <= progress <= 1:
            raise ValueError("pill progress must be finite and 0...1")
    if "isHighlighted" in result and type(result["isHighlighted"]) is not bool:
        raise TypeError("pill isHighlighted must be Bool")
    return result


class BasePill(Object):
    def __init__(self, context, resourcesProvider=None):
        if resourcesProvider is not None:
            raise UnsupportedSurfaceError("BasePill Android ResourcesProvider needs a portable native theme contract")
        self._context, self.resourcesProvider = context, resourcesProvider
        self.loading = False
        self._content = {"value": "", "phase": "idle"}
        self._publish = None
        self._last_update = None
        self._stack_visible = None
        self._phase_before_loading = None

    def getContext(self): return self._context
    def getPillId(self): raise NotImplementedError("override BasePill.getPillId")
    def getRefreshInterval(self): raise NotImplementedError("override BasePill.getRefreshInterval (milliseconds)")
    def onUpdateData(self, force): raise NotImplementedError("override BasePill.onUpdateData")
    def onPillClicked(self): raise NotImplementedError("override BasePill.onPillClicked")
    def onPillLongClicked(self): raise NotImplementedError("override BasePill.onPillLongClicked")
    def updateColors(self): raise NotImplementedError("override BasePill.updateColors")
    def onPillSelected(self): pass
    def onPillUnselected(self): pass
    def onStackVisibilityChanged(self, visible):
        if type(visible) is not bool: raise TypeError("pill visibility must be Bool")
        self._stack_visible = visible

    def setContent(self, value):
        updated = content(dict(self._content, **content(value)))
        if self._publish is not None: self._publish(updated)
        self._content = updated

    def to_pill_content(self): return dict(self._content)
    def startLoading(self):
        if not self.loading: self._phase_before_loading = self._content.get("phase", "idle")
        self.setContent({"phase": "loading"})
        self.loading = True
    def stopLoading(self):
        if self.loading and self._content.get("phase") == "loading": self.setContent({"phase": self._phase_before_loading})
        self.loading = False
    def markDataUpdated(self):
        self.setContent({"updatedAtMs": time.time_ns() // 1_000_000})
        self._last_update = time.monotonic_ns()
    def isRefreshDue(self):
        interval = self.getRefreshInterval()
        if type(interval) is not int: raise TypeError("getRefreshInterval must return milliseconds")
        return interval <= 0 or self._last_update is None or (time.monotonic_ns() - self._last_update) // 1_000_000 >= interval
    def setLoadingTargetView(self, view):
        raise UnsupportedSurfaceError("BasePill.setLoadingTargetView requires Android View geometry")
    def animateSizeChange(self):
        raise UnsupportedSurfaceError("BasePill.animateSizeChange requires Android View geometry; native content updates own transitions")


class LayoutDraft:
    """Stable mutable ADTs populated by native layout, committed only on save."""
    def __init__(self):
        self.active, self.hidden = ArrayList(), ArrayList()
        self.loaded = False
        self._saved = None

    @property
    def dirty(self): return self.loaded and self._saved != self._signature()

    def _signature(self):
        return tuple((type(value), value) for value in self.active), tuple((type(value), value) for value in self.hidden)

    def accept(self, active, hidden, *, force=False):
        if self.dirty and not force: return
        active, hidden = list(active), list(hidden)
        for value in active + hidden: int32(value)
        self.active[:] = active
        self.hidden[:] = hidden
        self.loaded = True
        self._saved = self._signature()

    def values(self):
        if not self.loaded: raise RuntimeError("native pill layout has not been read")
        return [int32(value) for value in self.active], [int32(value) for value in self.hidden]


def install():
    from virtualjava import register_class
    for fqcn, cls in {
        "app.exteraless.pillstack.PillType": PillType,
        "app.exteraless.pillstack.PillRegistry$PillInfo": PillInfo,
        "app.exteraless.pillstack.PillRegistry$PillCreator": PillCreator,
        "app.exteraless.pillstack.pills.BasePill": BasePill,
    }.items():
        cls._fqcn = fqcn
        register_class(fqcn, cls)
