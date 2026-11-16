"""Compile the UI contract within 120s, then execute it within 25s.

No SDK corpus, Python plugin, account, UIKit presentation, CI or network is used.
The app glob sees an empty test file unless PLUGIN_UI_FIXTURE is explicitly set.
"""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[7]
sys.path.insert(0, str(REPO / "tools/compat/tests/tl_bridge"))
from run_shared_fixtures import run_bounded


def main():
    compiler = shutil.which("swiftc")
    if compiler is None:
        print("PENDING: swiftc is not installed; native UI fixture was not run.")
        return 77
    root = Path(__file__).resolve().parent.parent
    sources = [root / name for name in (
        "PluginUIModel.swift", "PluginUIStyleModel.swift", "PluginUIMenuModel.swift", "PluginUILifecycle.swift", "PluginUISettingsUpdate.swift",
        "PluginUINavigation.swift", "PluginUIRequest.swift", "PluginUIShareFiles.swift", "PluginManagerPreferences.swift",
        "PluginDeveloperProtocol.swift", "PluginRuntimeRecovery.swift", "PluginRuntimeMaintenance.swift",
        "PluginUIReleaseQueue.swift", "Tests/PluginUIFixture.swift",
    )]
    preferred = Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "opencode"
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="plugin-ui-fixture-", dir=preferred if preferred.is_dir() else None) as temporary:
        binary = Path(temporary) / ("fixture.exe" if os.name == "nt" else "fixture")
        command = [compiler, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                   "-D", "PLUGIN_UI_FIXTURE", *map(str, sources), "-o", str(binary)]
        phase = "compilation"
        try:
            result = run_bounded(command, timeout=120)
            if result:
                return result
            compiled = time.monotonic()
            phase = "execution"
            result = run_bounded([str(binary)], timeout=25)
            if result:
                return result
            print(f"UI fixture compile: {compiled - started:.3f}s; execution: {time.monotonic() - compiled:.3f}s")
        except subprocess.TimeoutExpired:
            print(f"FAIL: UI fixture {phase} exceeded its bounded deadline.", file=sys.stderr)
            return 1
        except subprocess.CalledProcessError as error:
            return error.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
