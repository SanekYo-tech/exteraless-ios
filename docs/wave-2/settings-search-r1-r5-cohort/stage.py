"""Stage pinned real Swift sources for 16 baseline + 6 closure tests; never run Swift."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new caller-owned directory outside the checkout")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    manifest_path = root / "docs/wave-2/settings-search-r1-r5-cohort.json"
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    output = args.output.resolve()
    if output.exists() or output == root or root in output.parents:
        raise ValueError("output must be a new caller-owned directory outside the checkout")
    members = {}
    for item in manifest["files"]:
        source_name, member = PurePosixPath(item["source"]), PurePosixPath(item["member"])
        if any(p.is_absolute() or ".." in p.parts or "\\" in str(p) for p in (source_name, member)):
            raise ValueError("non-relative cohort path")
        if str(member) in members:
            raise ValueError("duplicate cohort member")
        source = root / source_name
        if source.is_symlink() or root not in source.resolve().parents:
            raise ValueError("cohort source escaped the checkout")
        data = source.read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("cohort source drift: " + item["source"])
        members[str(member)] = data
    members["cohort.json"] = manifest_bytes
    members["SHA256SUMS"] = "".join(hashlib.sha256(data).hexdigest() + "  " + name + "\n"
                                  for name, data in sorted(members.items())).encode("ascii")
    output.mkdir(parents=True, exist_ok=False)
    for member, data in members.items():
        path = output / member
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as file:
            file.write(data)
    print(json.dumps({"output": str(output), "members": len(members), "tests": manifest["test_count"],
                      "swift_executed": False, "commands": manifest["commands"]}, indent=2))


if __name__ == "__main__":
    main()
