"""Run reviewed legacy SDK/bridge tests in separate bounded UTF-8 processes.

Only this repository's SDK and local fixtures execute. The optional bridge path
must be an already-built extension for the chosen interpreter; no build/download.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
SUITES = (
    "test_virtualjava.py", "test_bridge.py", "test_bridge_isolation.py",
    "test_sdk_nx_port.py", "test_reflection_gate.py", "test_plugin_settings_types.py",
    "test_class_alias_bridge.py", "test_regressions.py",
    "test_sdk_surface.py::test_sdk_surface_is_not_empty",
    "test_sdk_surface.py::test_base_plugin_surface_is_complete",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--bridge", type=Path)
    parser.add_argument("--manifest", type=Path, default=ROOT / "build/compat/manifest.json")
    parser.add_argument("--suite", action="append", choices=SUITES)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    results = []
    for suite in options.suite or SUITES:
        key = suite.replace(".py", "").replace("::", "-")
        arguments = [str(ROOT / "tools/compat/tests" / suite), "-q", "--tb=short",
                     "--basetemp=" + str(options.output / key)]
        code = ""
        if options.bridge and suite.startswith(("test_bridge.py", "test_bridge_isolation.py")):
            code = ("import importlib.util,sys; "
                    "s=importlib.util.spec_from_file_location('python.bridge._exteraless_bridge',"
                    + repr(str(options.bridge.resolve())) + "); "
                    "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.modules[s.name]=m; ")
        code += "import pytest; raise SystemExit(pytest.main(" + repr(arguments) + "))"
        env = dict(os.environ, EXTERALESS_PLUGIN_CORPUS=str(ROOT / "tools/compat/tests/fixtures/ios_runtime"),
                   EXTERALESS_MANIFEST=str(options.manifest.resolve()))
        try:
            result = subprocess.run([options.python, "-X", "utf8", "-B", "-c", code],
                                    cwd=ROOT, env=env, text=True, encoding="utf-8", errors="replace",
                                    capture_output=True, timeout=20)
            output, status = result.stdout + result.stderr, result.returncode
            summary = result.stdout.splitlines()[-1:]
        except subprocess.TimeoutExpired as error:
            output, status, summary = str(error), 124, ["hard 20-second timeout"]
        (options.output / (key + ".log")).write_text(output, encoding="utf-8")
        results.append({"suite": suite, "returncode": status, "summary": summary})
        print(f"{suite}: {status} {' '.join(summary)}")
        if status:
            print(output)
    (options.output / "report.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return int(any(item["returncode"] for item in results))


if __name__ == "__main__":
    raise SystemExit(main())
