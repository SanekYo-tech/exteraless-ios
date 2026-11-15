#!/usr/bin/env python3
"""Generate named traps from the CURRENT protocols, following ComposerHarness.

Bazel owns the generated output. This never patches a production protocol or
provides default values. Swift conformance checking remains the authority.
"""

import re
import sys
from pathlib import Path

PROVIDED = {
    "AccountContext": ("ClientHarnessAccountContext", {"account", "sharedContext", "engine",
        "currentContentSettings", "currentAppConfiguration", "animationCache", "animationRenderer",
        "lottieRenderingSettings", "peerNameColors", "getAppConfigValue", "fetchManager",
        "currentLimitsConfiguration", "userLimits", "isPremium", "isFrozen", "animatedEmojiStickersValue"}),
    "SharedAccountContext": ("ClientHarnessSharedContext", {
        "accountManager", "mainWindow", "currentPresentationData", "presentationData",
        "energyUsageSettings", "currentAutomaticMediaDownloadSettings",
        "immediateExperimentalUISettings", "currentChatSettings",
    }),
}


def generate(text):
    imports = list(dict.fromkeys(re.findall(r"^import (\w+)$", text, re.M) + ["Postbox", "AccountContext"]))
    lines = ["// Generated from AccountContext.swift; unprovided services MUST trap."]
    lines += ["import " + name for name in imports]
    for protocol, (conformer, provided) in PROVIDED.items():
        start = re.search(r"^public protocol " + protocol + r": AnyObject \{", text, re.M)
        if start is None:
            raise ValueError("Protocol signature changed: " + protocol)
        body, depth = [], 1
        for line in text[start.end():].splitlines():
            depth += line.count("{") - line.count("}")
            if depth == 0:
                break
            body.append(line)
        else:
            raise ValueError("Unterminated protocol: " + protocol)
        lines += ["", "extension " + conformer + " {"]
        index, found = 0, set()
        while index < len(body):
            match = re.match(r"    (var|func)\s+(\w+)\s*(.*)$", body[index])
            index += 1
            if not match:
                continue
            kind, name, rest = match.groups()
            found.add(name)
            while rest.count("(") > rest.count(")") and index < len(body):
                rest += " " + body[index].strip()
                index += 1
            if name in provided:
                continue
            rest = " ".join(rest.split())
            trap = 'fatalError("client-ui-harness: ' + protocol + "." + name + ' is not provided")'
            if kind == "var":
                if not re.search(r"\{ get \}$", rest):
                    raise ValueError("Unsupported property requirement: " + name)
                signature = "var " + name + " " + re.sub(r"\{ get \}$", "", rest).rstrip()
            else:
                signature = "func " + name + rest
            lines += ["    public " + signature + " {", "        " + trap, "    }"]
        if not provided <= found:
            raise ValueError("Provided members disappeared: " + repr(provided - found))
        lines.append("}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_context_stubs.py AccountContext.swift")
    sys.stdout.write(generate(Path(sys.argv[1]).read_text(encoding="utf-8")))
