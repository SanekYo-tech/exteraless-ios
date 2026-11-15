"""Compile/run the shipping Foundation-only UI contract, with a 25s total bound.

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


def main():
    compiler = shutil.which("swiftc")
    if compiler is None:
        print("PENDING: swiftc is not installed; native UI fixture was not run.")
        return 77
    root = Path(__file__).resolve().parent.parent
    sources = [root / name for name in (
        "PluginUIModel.swift", "PluginUIStyleModel.swift", "PluginUIMenuModel.swift", "PluginUILifecycle.swift",
        "PluginUINavigation.swift", "PluginUIRequest.swift", "PluginUIShareFiles.swift", "PluginManagerPreferences.swift",
        "PluginDeveloperProtocol.swift", "PluginRuntimeRecovery.swift", "PluginRuntimeMaintenance.swift",
        "PluginUIReleaseQueue.swift", "Tests/PluginUIFixture.swift",
    )]
    preferred = Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "opencode"
    deadline = time.monotonic() + 25
    with tempfile.TemporaryDirectory(prefix="plugin-ui-fixture-", dir=preferred if preferred.is_dir() else None) as temporary:
        binary = Path(temporary) / ("fixture.exe" if os.name == "nt" else "fixture")
        command = [compiler, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                   "-D", "PLUGIN_UI_FIXTURE", *map(str, sources), "-o", str(binary)]
        try:
            subprocess.run(command, check=True, timeout=min(20, deadline - time.monotonic()))
            subprocess.run([str(binary)], check=True, timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            print("FAIL: UI fixture exceeded its bounded deadline.", file=sys.stderr)
            return 1
        except subprocess.CalledProcessError as error:
            return error.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
