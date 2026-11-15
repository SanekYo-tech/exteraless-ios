#!/usr/bin/env python3
"""Build/run only our Foundation Swift fixtures; whole operation has a 30s budget.

No Telegram account, app launch, SDK/plugin import, network or XCTest host. Use on
the coordinator's Swift host after the Windows-side generator fixtures pass.
"""

import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from run_shared_fixtures import run_bounded


ROOT = Path(__file__).resolve().parents[4]
NATIVE = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime"
HOOKS = ROOT / "swift/PluginHooks/Sources/PluginHooks"
APPROVED_TEMP = Path.home() / "AppData/Local/Temp/opencode"


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        print("SKIP: swiftc is unavailable; native fixtures were not run")
        return 77
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="tl-native-fixtures-", dir=APPROVED_TEMP if APPROVED_TEMP.is_dir() else None) as temporary:
        executable = Path(temporary) / ("tl-fixtures.exe" if sys.platform == "win32" else "tl-fixtures")
        command = [compiler, "-swift-version", "6", "-parse-as-library",
                   str(NATIVE / "TLCodec.swift"), str(NATIVE / "TLSchemaGenerated.swift"),
                    str(NATIVE / "TLRequestRegistry.swift"), str(NATIVE / "TLTransformCodec.swift"), str(NATIVE / "TLUpdatePolicy.swift"),
                    str(NATIVE / "TLEnqueueCommit.swift"),
                   str(HOOKS / "PluginHookPayloads.swift"), str(HOOKS / "PluginTLTransform.swift"), str(HOOKS / "PluginTLSubmissionOrder.swift"),
                   str(Path(__file__).with_name("NativeFixtures.swift")),
                   "-o", str(executable)]
        result = run_bounded(command, timeout=25)
        if result:
            raise subprocess.CalledProcessError(result, command)
        remaining = 28.5 - (time.monotonic() - started)
        if remaining <= 0:
            print("TIMEOUT: compile/test budget exceeded; this is not a passing run")
            return 124
        result = run_bounded([str(executable)], timeout=remaining)
        if result:
            raise subprocess.CalledProcessError(result, [str(executable)])
    print(f"Native fixture wall time: {time.monotonic() - started:.3f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
