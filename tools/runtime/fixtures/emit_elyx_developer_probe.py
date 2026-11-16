"""Tiny owned v1 archives/commands for the fifth native C/Swift/CPython child."""

import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile


PLUGIN_ID = "native_elyx_dev"
WHEEL_NAME = "wheels/elyxprobe-1.0-py3-none-any.whl"
ENTRY = '''from base_plugin import BasePlugin
import helpers
import elyxprobe
from elyx import assets
class NativeElyxDeveloperProbe(BasePlugin):
    def on_plugin_load(self):
        self.set_setting("loads", self.get_setting("loads", 0) + 1)
        self.set_setting("seen", [helpers.VALUE, assets["value.txt"].content_string(), elyxprobe.VALUE])
    def on_plugin_unload(self):
        self.set_setting("unloads", self.get_setting("unloads", 0) + 1)
'''


def zipped(values):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, value in sorted(values.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, value)
    return output.getvalue()


def wheel(value, requires_python=None):
    metadata = "Metadata-Version: 2.1\nName: elyxprobe\nVersion: 1.0\n"
    if requires_python:
        metadata += "Requires-Python: " + requires_python + "\n"
    return zipped({"elyxprobe/__init__.py": "VALUE = " + repr(value) + "\n",
        "elyxprobe-1.0.dist-info/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        "elyxprobe-1.0.dist-info/METADATA": metadata})


def emit(directory):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        raise ValueError("fifth-child fixture output must be empty")
    first = {"refmap.json": json.dumps({"main": "main.py", "metainfo": "meta.json", "assets": "assets", "wheels": "wheels"}),
        "meta.json": json.dumps({"id": PLUGIN_ID, "name": "Owned native Elyx developer probe", "version": "1.0", "permissions": []}),
        "main.py": ENTRY, "helpers.py": "VALUE = 'first'\n", "assets/value.txt": "asset-first", WHEEL_NAME: wheel("wheel-first")}
    first = {name: value.encode() if isinstance(value, str) else value for name, value in first.items()}
    next_metadata = json.loads(first["meta.json"])
    next_metadata.update(version="2.0", permissions=["network"])
    next_values = dict(first, **{"helpers.py": b"VALUE = 'next'\n", "assets/value.txt": b"asset-next", WHEEL_NAME: wheel("wheel-next"),
        "main.py": ENTRY.replace("NativeElyxDeveloperProbe(", "NativeElyxDeveloperProbeNext(").encode(),
        "meta.json": json.dumps(next_metadata).encode()})
    (root / "owned.elyx").write_bytes(zipped(first))
    (root / "expected-next.elyx").write_bytes(zipped(next_values))
    changes = [{"#": "modified", "path": name, "content": base64.b64encode(next_values[name]).decode()}
               for name in ("main.py", "meta.json", "helpers.py", "assets/value.txt", WHEEL_NAME)]
    (root / "changes.json").write_text(json.dumps({"@": "elyx_changes", "plugin_id": PLUGIN_ID, "changes": changes}), encoding="utf-8")
    (root / "compare-next.json").write_text(json.dumps({"@": "elyx_compare_folder", "plugin_id": PLUGIN_ID,
        "hashes": {name: hashlib.sha256(value).hexdigest() for name, value in next_values.items()}}), encoding="utf-8")
    unsupported = json.loads(first["meta.json"])
    unsupported["requires"] = {PLUGIN_ID: None}
    for name, path, content in (("requires", "meta.json", json.dumps(unsupported).encode()),
                                ("python", WHEEL_NAME, wheel("must-not-load", requires_python=">=99"))):
        (root / ("reject-" + name + ".json")).write_text(json.dumps({"@": "elyx_changes", "plugin_id": PLUGIN_ID,
            "changes": [{"#": "modified", "path": path, "content": base64.b64encode(content).decode()}]}), encoding="utf-8")
    artifacts = sorted(root.iterdir())
    assert sum(path.stat().st_size for path in artifacts) < 32768
    print(json.dumps({path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in artifacts}, sort_keys=True))


if __name__ == "__main__":
    emit(sys.argv[1])
