#!/usr/bin/env python3
"""Bazel resource generator: fingerprint the actual declared domain source inputs."""

import argparse
import hashlib
import json
from pathlib import Path


def source_key(path):
    text = str(path).replace("\\", "/")
    for anchor, prefix in (("submodules/", "telegram-ios/"), ("Tests/ExteralessHarness/", "telegram-ios/"),
                           ("Tests/ComposerHarness/", "telegram-ios/"), ("swift/ExteralessCore/", "")):
        position = text.find(anchor)
        if position >= 0 and (position == 0 or text[position - 1] == "/"):
            key = prefix + text[position:]
            if ".." in Path(key).parts:
                break
            return key
    raise ValueError("Unexpected domain source input: " + text)


def manifest(paths):
    files = {}
    for path in paths:
        path = Path(path)
        key = source_key(path)
        if key in files:
            raise ValueError("Duplicate domain source key: " + key)
        files[key] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not files:
        raise ValueError("No domain source inputs")
    canonical = "".join(sha + "  " + key + "\n" for key, sha in sorted(files.items()))
    return {"format": "exteraless-ui-domain-sources/1", "files": files,
            "sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("sources", nargs="+", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(manifest(args.sources), sort_keys=True, indent=2) + "\n", encoding="utf-8")
