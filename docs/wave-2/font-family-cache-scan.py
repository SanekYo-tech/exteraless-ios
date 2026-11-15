"""Bounded PFM-01 source inventory and companion hunks; never edits consumers.

The three directly owned consumers have dedicated layout fixes. This captures
other one-line, process-wide Display.Font requests as exact source hunks for the
coordinator. Computed getters retain the original request and native Font cache.
This is source analysis, not Swift execution or a claim about rendered pixels.
"""

import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.compat.feature_inventory import mask_source

OWNED = {
    "telegram-ios/submodules/ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift",
    "telegram-ios/submodules/ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift",
    "telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift",
}
REQUEST = r"Font\.(?:regular|medium|semibold|bold|light|heavy|italic|mediumItalic|semiboldItalic|with)\("
DECLARATION = re.compile(
    r"^(?P<prefix>(?:(?:private|fileprivate|internal|public) )?|[ \t]+(?:(?:private|fileprivate|internal|public) )?static )"
    r"let (?P<name>\w+)(?:\s*:\s*UIFont)?\s*=\s*(?P<request>" + REQUEST + r"[^\n]*\))(?P<tail>[ \t]*(?://[^\n]*)?)$",
    re.MULTILINE,
)


def collect():
    # One bounded rg-equivalent git query includes new source files, but no
    # vendored font data, generated SDK output, resources or test fixtures.
    candidates = subprocess.run(
        ["git", "grep", "--untracked", "--exclude-standard", "-l", "-E",
         r"^(private |fileprivate |internal |public )?let .*Font\.|^[[:blank:]]+(private |fileprivate |internal |public )?static let .*Font\.",
         "--", "telegram-ios/submodules/**/*.swift"],
        cwd=ROOT, check=False, capture_output=True, encoding="utf-8", timeout=15,
    )
    if candidates.returncode not in (0, 1):
        raise RuntimeError(candidates.stderr)
    paths = sorted(set(candidates.stdout.splitlines()))
    if len(paths) > 512:
        raise RuntimeError("candidate-file bound exceeded")
    records, patches = [], []
    total_bytes = 0
    for relative in paths:
        path = ROOT / relative
        if not ({"Source", "Sources"} & set(path.parts)) or "Tests" in path.parts:
            continue
        raw = path.read_bytes()
        total_bytes += len(raw)
        if len(raw) > 4 * 1024 * 1024 or total_bytes > 64 * 1024 * 1024:
            raise RuntimeError("source-byte bound exceeded")
        text = raw.decode("utf-8-sig")
        code = mask_source(text, strings=True, nested_comments=True)
        after = text
        selected = []
        for match in DECLARATION.finditer(text):
            name, request = match["name"], match["request"]
            if not re.search(r"\blet\s+" + re.escape(name) + r"\b", code[match.start():match.start("request")]):
                continue
            record = {"path": relative, "line": text.count("\n", 0, match.start()) + 1,
                      "symbol": name, "request": request, "source_sha256": hashlib.sha256(raw).hexdigest()}
            if relative in OWNED:
                reason = "direct consumer fix owns layout-time resolution"
            elif re.search(r"design:\s*\.(?!regular\b)\w+|width:\s*\.(?:compressed|expanded)\b|\.alternateDollarSign\b", request):
                reason = "explicit native design/width/glyph role"
            elif re.search(r"code|fixed|math|emoji|crown", name, re.IGNORECASE) or name.lower() == "iconfont":
                reason = "explicit code/emoji/icon role requires its own consumer review"
            elif any(part in relative for part in ("/RichTextEditor/", "/EmojisChatInputPanelItem.swift", "/CallControllerKeyButton.swift")):
                reason = "editor/art/emoji role outside the ordinary-sans cohort"
            elif "import UIKit" not in text:
                reason = "no direct UIKit import; owner must review the module edge"
            else:
                reason = None
            if reason:
                record.update(disposition="excluded", reason=reason)
            else:
                replacement = match["prefix"] + "var " + name + ": UIFont { return " + request + " }" + match["tail"]
                selected.append((match.start(), match.end(), replacement))
                record.update(disposition="companion-hunk")
            records.append(record)
            if len(records) > 600:
                raise RuntimeError("declaration bound exceeded")
        for start, end, replacement in reversed(selected):
            after = after[:start] + replacement + after[end:]
        if after != text:
            patches.append("diff --git a/" + relative + " b/" + relative + "\n" + "".join(difflib.unified_diff(
                text.splitlines(True), after.splitlines(True), fromfile="a/" + relative, tofile="b/" + relative)))
    report = {
        "scope": "Production Source/Sources .swift files under telegram-ios/submodules; one-line global or static Display.Font requests only",
        "bounds": {"candidate_files": 512, "source_bytes": 64 * 1024 * 1024, "per_file_bytes": 4 * 1024 * 1024, "declarations": 600, "git_seconds": 15},
        "candidate_files": len(paths), "source_bytes": total_bytes,
        "companion_declarations": sum(record["disposition"] == "companion-hunk" for record in records),
        "companion_files": len(patches), "records": records,
        "proof": "Source-only inventory. Does not claim per-instance cache invalidation, native compilation or UI pixels.",
    }
    return "".join(patches), report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-handoff", action="store_true", help="Create two new derived artifacts; refuse to overwrite existing work")
    args = parser.parse_args()
    patch, report = collect()
    if args.write_handoff:
        outputs = {
            ROOT / "docs/wave-2/font-family-global-cache-hunks.patch": patch,
            ROOT / "docs/wave-2/font-family-global-cache-scan.json": json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        }
        if any(path.exists() for path in outputs):
            raise RuntimeError("handoff artifact already exists; preserve it")
        for path, content in outputs.items():
            path.write_text(content, encoding="utf-8", newline="\n")
    print(json.dumps({key: value for key, value in report.items() if key != "records"}, indent=2))


if __name__ == "__main__":
    main()
