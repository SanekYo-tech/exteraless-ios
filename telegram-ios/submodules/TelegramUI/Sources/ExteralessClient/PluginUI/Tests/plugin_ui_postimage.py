"""Scoped source receipt for the applied UI follow-up, never an execution proof."""

import hashlib
import json
from pathlib import Path
import time


MANIFEST = "docs/wave-2/plugin-ui-darwin-compiler-postimage.json"
RUNTIME = "telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift"
HARNESS = "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift"


def normalized(text):
    return text.replace("\r\n", "\n").replace("\r", "\n")


def digest(text):
    return hashlib.sha256(normalized(text).encode("utf-8")).hexdigest()


def region_text(source, pin):
    source = normalized(source)
    start, end = pin["start"], pin["end"]
    if source.count(start) != 1:
        raise ValueError("Postimage start anchor is missing or ambiguous: " + pin["id"])
    offset = source.index(start)
    boundary = source.find(end, offset + len(start))
    if boundary < 0:
        raise ValueError("Postimage end anchor is missing: " + pin["id"])
    return source[offset:boundary]


def verify_postimage(repo):
    repo = Path(repo)
    deadline = time.monotonic() + 20

    def read(path):
        if time.monotonic() >= deadline:
            raise ValueError("Postimage verification exceeded 20 seconds")
        return (repo / path).read_text(encoding="utf-8")

    manifest_text = read(MANIFEST)
    manifest = json.loads(manifest_text)
    if manifest.get("schema_version") != 1 or manifest.get("normalization") != "utf8-lf":
        raise ValueError("Unsupported UI postimage receipt")
    files = manifest["files"]
    regions = manifest["regions"]
    if not 1 <= len(files) <= 32 or not 1 <= len(regions) <= 16:
        raise ValueError("Unexpected UI postimage scope")
    if RUNTIME in files or HARNESS in files:
        raise ValueError("Shared composition files require scoped region pins, not whole-file pins")
    actual_files = {}
    actual_regions = {}
    for path, expected in files.items():
        actual_files[path] = digest(read(path))
        if actual_files[path] != expected:
            raise ValueError("UI postimage source changed; review and refresh its pin: " + path)
    for pin in regions:
        if pin["path"] not in (RUNTIME, HARNESS) or pin["id"] in actual_regions:
            raise ValueError("Unexpected or duplicate composition region: " + pin["id"])
        actual_regions[pin["id"]] = digest(region_text(read(pin["path"]), pin))
        if actual_regions[pin["id"]] != pin["sha256"]:
            raise ValueError("Applied composition region changed; review its postimage: " + pin["id"])
    return {"manifest_sha256": digest(manifest_text), "files": actual_files, "regions": actual_regions}
