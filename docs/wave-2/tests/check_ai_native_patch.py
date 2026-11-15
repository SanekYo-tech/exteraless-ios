"""Dry-apply native-remediation hunks in memory. This is not a Swift test/typecheck."""
from pathlib import Path
import json


def check(root: Path) -> dict:
    patch = root / "docs/wave-2/ai-native-remediation.patch"
    sections = []
    paths = set()
    path = None
    hunks = []
    hunk = []
    for line in patch.read_text(encoding="utf-8").splitlines():
        if line.startswith("*** Update File: "):
            if path is not None:
                if hunk:
                    hunks.append(hunk)
                sections.append((path, hunks))
            path, hunks, hunk = line[17:], [], []
            if path in paths:
                raise ValueError(f"Duplicate file operation: {path}")
            paths.add(path)
        elif line.startswith("@@"):
            if hunk:
                hunks.append(hunk)
            hunk = []
        elif line == "*** End Patch":
            if path is not None:
                if hunk:
                    hunks.append(hunk)
                sections.append((path, hunks))
            path, hunk = None, []
        elif path is not None:
            if not line.startswith((" ", "+", "-")):
                raise ValueError(f"Malformed hunk line: {line!r}")
            hunk.append(line)
    results = {}
    failures = []
    applied = 0
    for path, hunks in sections:
        source = results.get(path)
        if source is None:
            source = (root / path).read_text(encoding="utf-8")
        cursor = 0
        for number, hunk in enumerate(hunks, 1):
            old = "\n".join(line[1:] for line in hunk if line[0] in " -") + "\n"
            new = "\n".join(line[1:] for line in hunk if line[0] in " +") + "\n"
            count = source.count(old)
            if count != 1:
                failures.append({"path": path, "hunk": number, "matches": count, "anchor": old[:160]})
                continue
            position = source.find(old, cursor)
            if position < 0:
                failures.append({"path": path, "hunk": number, "error": "out-of-order hunk"})
                continue
            source = source.replace(old, new, 1)
            cursor = position + len(new)
            applied += 1
        results[path] = source
    return {"check": "patch applicability only", "files": len(results), "hunks": applied, "failures": failures}


if __name__ == "__main__":
    result = check(Path(__file__).resolve().parents[3])
    print(json.dumps(result, indent=2, ensure_ascii=False))
    raise SystemExit(bool(result["failures"]))
