"""JSON snapshots at the worker boundary; no synthetic Java objects."""

import base64
import json
import math


class Snapshot(dict):
    """A supplied hook snapshot supports both ``params.message`` and mapping access.

    Missing fields raise AttributeError. This is data, not a Java API emulator.
    """

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None

    def __setattr__(self, name, value):
        self[name] = value


def _bad_constant(value):
    raise ValueError(f"non-JSON numeric constant: {value}")


def loads(source):
    return json.loads(source, parse_constant=_bad_constant)


def decode(value, bridge):
    if isinstance(value, list):
        return [decode(item, bridge) for item in value]
    if not isinstance(value, dict):
        return value
    keys = set(value)
    if keys in ({"__handle__"}, {"__handle__", "__fqcn__"},
                {"__handle__", "__fqcn"}, {"__handle__", "__fqcn__", "__fqcn"}):
        if "__fqcn__" in value and "__fqcn" in value and value["__fqcn__"] != value["__fqcn"]:
            raise ValueError("conflicting native handle type tags")
        handle = value["__handle__"]
        if type(handle) is not int:
            raise TypeError("__handle__ must be an integer")
        result = bridge.xt_resolve_handle(handle)
        if result is None:
            raise LookupError(f"unknown callback argument handle {handle}")
        return result
    if keys == {"__bytes__"}:
        return base64.b64decode(value["__bytes__"], validate=True)
    if keys == {"__float__"}:
        token = value["__float__"]
        if token not in ("inf", "-inf", "nan"):
            raise ValueError(f"unknown __float__ tag: {token!r}")
        return float(token)
    return Snapshot((key, decode(item, bridge)) for key, item in value.items())


def _encode(value, bridge):
    from ._tl import TLObject, to_wire
    if isinstance(value, TLObject):
        return to_wire(value)
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, int):
        if not -(2 ** 63) <= value < 2 ** 63:
            raise OverflowError("runtime JSON integer does not fit int64")
        return value
    if isinstance(value, float):
        if math.isfinite(value):
            return value
        return {"__float__": "nan" if math.isnan(value) else str(value)}
    if isinstance(value, bytes):
        return {"__bytes__": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (list, tuple)):
        return [_encode(item, bridge) for item in value]
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise TypeError("runtime JSON object keys must be strings")
        return {key: _encode(item, bridge) for key, item in value.items()}
    if bridge is None:
        raise TypeError(f"not JSON data: {type(value).__name__}")
    # Match the C transport's identity markers. The interpreter owns these refs.
    try:
        fqcn = object.__getattribute__(value, "_fqcn")
    except AttributeError:
        fqcn = None
    return {"__handle__": bridge.xt_register_handle(value),
            "__fqcn__": fqcn if isinstance(fqcn, str) else None}


def dumps(value, bridge=None):
    return json.dumps(_encode(value, bridge), ensure_ascii=False, allow_nan=False)
