"""Trusted, data-only native Elyx startup probe; no plugin/archive execution."""

import json
import types

from ._platform import UnsupportedSurfaceError


ABI = "exteraless.elyx.source.v1"


def probe_json(challenge):
    if (type(challenge) is not str or len(challenge) != 64
            or any(character not in "0123456789abcdef" for character in challenge)):
        raise ValueError("native Elyx readiness challenge must be 64 lowercase hex")
    try:
        import _exteraless_bridge as bridge
    except ImportError as error:
        raise UnsupportedSurfaceError("Elyx readiness: built-in C bridge is unavailable") from error
    gate = getattr(bridge, "xt_elyx_source", None)
    if (type(bridge) is not types.ModuleType
            or getattr(getattr(bridge, "__spec__", None), "origin", None) != "built-in"
            or getattr(getattr(bridge, "__spec__", None), "name", None) != "_exteraless_bridge"
            or not isinstance(gate, types.BuiltinFunctionType)
            or getattr(gate, "__self__", None) is not bridge
            or getattr(gate, "__module__", None) != "_exteraless_bridge"
            or getattr(gate, "__name__", None) != "xt_elyx_source"):
        raise UnsupportedSurfaceError("Elyx readiness: xt_elyx_source is not this C module's built-in gate")
    from . import _archives
    if _archives.SOURCE_ABI != ABI:
        raise UnsupportedSurfaceError("Elyx readiness: archive SOURCE_ABI mismatch")
    hooks = {
        "manifest": getattr(_archives.ArchiveAdapter, "developer_manifest", None),
        "inspect": getattr(_archives, "inspect_developer_descriptor", None),
        "verifiedLoad": getattr(_archives, "verified_developer_load", None),
    }
    missing = sorted(name for name, function in hooks.items() if not callable(function))
    if missing:
        raise UnsupportedSurfaceError("Elyx readiness: missing archive hooks: " + ", ".join(missing))
    try:
        gate("check", json.dumps({"abi": ABI, "read_id": challenge}, separators=(",", ":")))
    except Exception as error:
        if str(error) != "bridge host error [Superseded]: native read ticket is unknown or released":
            raise UnsupportedSurfaceError("Elyx readiness: native registry challenge failed: " + str(error)) from error
    else:
        raise UnsupportedSurfaceError("Elyx readiness: unknown challenge unexpectedly acquired source authority")
    # Native Host ALSO checks that its own registry observed this exact challenge
    # on the issued inspector invocation. A fabricated Python reply is insufficient.
    return json.dumps({"abi": ABI, "challenge": challenge, "gate": "builtin",
                       "hooks": sorted(hooks), "rejected": True}, separators=(",", ":"))
