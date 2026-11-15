#!/usr/bin/env python3
"""Run only the owned FakeEngine / PluginHooks suite, at most 30 seconds total."""

import argparse
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SUITES = {
    "host": ("PluginHost", "PluginTLHostTests"),
    "hooks": ("PluginHooks", "PluginTL(Transform|SubmissionOrder)Tests"),
}


def run_bounded(command, timeout):
    """Kill compiler/test descendants as well as swift's driver on expiry."""
    options = {"start_new_session": True} if os.name != "nt" else {
        "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP,
    }
    process = subprocess.Popen(command, cwd=ROOT, **options)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name != "nt":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        else:
            try:
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.5)
            finally:
                process.kill()
        process.wait(timeout=0.5)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=SUITES)
    args = parser.parse_args()
    swift = shutil.which("swift")
    if swift is None:
        print("SKIP: swift is unavailable; shared fixtures were not compiled or run")
        return 77
    package, test_filter = SUITES[args.suite]
    started = time.monotonic()
    try:
        result = run_bounded(
            [swift, "test", "--package-path", str(ROOT / "swift" / package),
             "--filter", test_filter], timeout=28.5,
        )
    except subprocess.TimeoutExpired:
        print("TIMEOUT: compile/test budget exceeded; this is not a passing run")
        return 124
    print(f"{args.suite} fixture wall time: {time.monotonic() - started:.3f}s")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
