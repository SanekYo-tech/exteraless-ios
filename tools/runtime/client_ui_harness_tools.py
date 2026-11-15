#!/usr/bin/env python3
"""Install only the two pinned CI frame tools, checking archive AND binary hashes."""

import argparse
import gzip
import json
from pathlib import Path
import platform
import subprocess
import sys

from pinned_download import digest, fetch

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "telegram-ios/Tests/ExteralessHarness/Tools/frame-tools-lock.json"


def install(output, cache):
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("Pinned frame tools require macOS arm64")
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=True)
    versions = {}
    for item in lock["binaries"]:
        archive = fetch(item, cache, transport="curl")
        binary = output / item["name"]
        if binary.is_symlink():
            raise ValueError("Frame tool output must not be a symlink")
        # Bound decompression independently of the compressed archive size.
        with gzip.open(archive, "rb") as source, binary.open("wb") as target:
            remaining = item["binary_size"]
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError("Truncated pinned frame binary")
                target.write(chunk)
                remaining -= len(chunk)
            if source.read(1):
                raise ValueError("Oversized pinned frame binary")
        if digest(binary) != item["binary_sha256"]:
            raise ValueError("Frame binary checksum mismatch: " + item["name"])
        binary.chmod(0o755)
        version = subprocess.check_output([str(binary), "-version"], text=True, timeout=5).splitlines()[0]
        versions[item["name"]] = {"sha256": digest(binary), "version": version}
    (output / "frame-tools.json").write_text(json.dumps(versions, indent=2) + "\n", encoding="utf-8")
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    install(args.output.resolve(), args.cache.resolve())


if __name__ == "__main__":
    main()
