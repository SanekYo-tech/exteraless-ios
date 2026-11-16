"""Build the shipping HNS helpers, then run their Foundation/Host executable.

The local SwiftPM dependency graph has its own build cache: a Core/Host package
cache is not assumed to supply this executable's objects. Compilation gets a
separate 480s budget (two packages); execution gets at most 30s. No UIKit, real
CPython, account, network or SDK plugin is executed by the fixture.
"""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from plugin_ui_postimage import MANIFEST as POSTIMAGE_MANIFEST, verify_postimage

UI = Path(__file__).resolve().parent.parent
REPO = UI.parents[5]
SOURCES = (
    "PluginUIModel.swift", "PluginUIStyleModel.swift", "PluginUIMenuModel.swift",
    "PluginUILifecycle.swift", "PluginUINavigation.swift", "PluginUIRequest.swift",
    "PluginUISettingsUpdate.swift",
    "PluginUISettingsActionGate.swift", "PluginUISettingsActionInvocation.swift",
    "PluginUISettingsReadInvocation.swift",
    "PluginUIRetainedEffect.swift", "PluginUIUnprovenSchemaCache.swift",
    "Tests/PluginUIRemediationFixture.swift",
)
COMPLETION = "PluginUI HNS fixture: 23 scenarios passed (Foundation + real Host worker with fixture engine; no UIKit, CPython, account or network execution)"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def source_inventory():
    files = {Path(__file__).resolve(), UI / "Tests/plugin_ui_postimage.py",
             REPO / POSTIMAGE_MANIFEST, REPO / "tools/runtime/check_swift_components.py"}
    files.update(UI / name for name in SOURCES)
    for name in ("PluginHost", "ExteralessCore"):
        package = REPO / "swift" / name
        files.add(package / "Package.swift")
        files.update(path for path in (package / "Sources").rglob("*")
                     if path.is_file() and path.suffix in (".swift", ".c", ".h", ".modulemap"))
    return {path.relative_to(REPO).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def check_component_reports(directory):
    if directory is None:
        return {}
    sys.path.insert(0, str(REPO / "tools/runtime"))
    from check_swift_components import package_fingerprint
    result = {}
    for name in ("PluginHost", "ExteralessCore"):
        report = json.loads((directory / name / "swift-component-tests.json").read_text(encoding="utf-8"))
        current = package_fingerprint(REPO / "swift" / name)
        if report.get("ok") is not True or report.get("phase") != "complete" or report.get("source_sha256") != current:
            raise ValueError("Core/Host compile-cache evidence is stale or unsuccessful: " + name)
        result[name] = hashlib.sha256(json.dumps(current, sort_keys=True).encode()).hexdigest()
    return result


def bounded(command, *, deadline, environment, log):
    options = {"env": environment, "stdout": log, "stderr": subprocess.STDOUT}
    if os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        options["start_new_session"] = True
    log.write("COMMAND " + json.dumps(command) + "\n")
    log.flush()
    process = subprocess.Popen(command, **options)
    try:
        result = process.wait(timeout=max(0.1, deadline - time.monotonic()))
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        if os.name == "nt":
            subprocess.run(["taskkill", "/pid", str(process.pid), "/T", "/F"], timeout=2, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        raise
    if result:
        raise subprocess.CalledProcessError(result, command)


def run_fixture(swift, output, scratch, compile_seconds, run_seconds, component_reports=None):
    report = {"ok": False, "phase": "inputs", "scenarios": 0,
              "compile_budget_seconds": compile_seconds, "execution_budget_seconds": run_seconds,
              "uikit_executed": False, "cpython_executed": False, "fixture_engine": True}
    write_json(output / "remediation-report.json", report)
    try:
        inputs = source_inventory()
        report["input_sha256"] = inputs
        report["applied_postimage"] = verify_postimage(REPO)
        report["component_fingerprints"] = check_component_reports(component_reports)
        report["source_fingerprint"] = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        package = output / "package"
        sources = package / "Sources"
        sources.mkdir(parents=True)
        for name in SOURCES:
            shutil.copyfile(UI / name, sources / Path(name).name)
        manifest = f'''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "PluginUIHNSFixture", platforms: [.macOS(.v12)],
    dependencies: [
        .package(name: "PluginHost", path: {json.dumps((REPO / "swift/PluginHost").as_posix())}),
        .package(name: "ExteralessCore", path: {json.dumps((REPO / "swift/ExteralessCore").as_posix())})
    ], targets: [.executableTarget(name: "Fixture", dependencies: [
        .product(name: "PluginHost", package: "PluginHost"),
        .product(name: "ExteralessCore", package: "ExteralessCore")
    ], path: "Sources", swiftSettings: [.define("PLUGIN_UI_REMEDIATION_FIXTURE")])])
'''
        (package / "Package.swift").write_text(manifest, encoding="utf-8")
        report["generated_package_sha256"] = hashlib.sha256(manifest.encode()).hexdigest()
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(scratch / "module-cache"),
                           SWIFTPM_MODULECACHE_OVERRIDE=str(scratch / "module-cache"))
        common = [swift, "build", "--package-path", str(package), "--scratch-path", str(scratch), "--jobs", "2"]
        report["phase"] = "compile"
        write_json(output / "remediation-report.json", report)
        started = time.monotonic()
        deadline = started + compile_seconds
        with (output / "compile.log").open("w", encoding="utf-8") as log:
            bounded([*common, "--product", "Fixture", "--disable-automatic-resolution"],
                    deadline=deadline, environment=environment, log=log)
            binary_dir = subprocess.check_output([*common, "--show-bin-path", "--disable-automatic-resolution"],
                text=True, env=environment, stderr=log, timeout=max(0.1, min(15, deadline - time.monotonic()))).strip()
        report["compile_seconds"] = round(time.monotonic() - started, 3)
        if source_inventory() != inputs:
            raise ValueError("HNS fixture inputs changed during compilation")
        if verify_postimage(REPO) != report["applied_postimage"]:
            raise ValueError("Applied UI composition changed during compilation")
        binary = Path(binary_dir) / ("Fixture.exe" if os.name == "nt" else "Fixture")
        report["executable_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        report["phase"] = "execute"
        write_json(output / "remediation-report.json", report)
        started = time.monotonic()
        with (output / "fixture.log").open("w", encoding="utf-8") as log:
            bounded([str(binary)], deadline=started + run_seconds, environment=environment, log=log)
        report["execution_seconds"] = round(time.monotonic() - started, 3)
        if COMPLETION not in (output / "fixture.log").read_text(encoding="utf-8").splitlines():
            raise ValueError("The executable did not confirm all 23 HNS scenarios")
        if source_inventory() != inputs or check_component_reports(component_reports) != report["component_fingerprints"]:
            raise ValueError("HNS source/component identity changed during execution")
        if verify_postimage(REPO) != report["applied_postimage"]:
            raise ValueError("Applied UI composition changed during execution")
        report.update(ok=True, phase="complete", scenarios=23)
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        write_json(output / "remediation-report.json", report)
    print(COMPLETION)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--component-reports", type=Path)
    parser.add_argument("--compile-seconds", type=int, default=480)
    parser.add_argument("--run-seconds", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.compile_seconds <= 480 or not 1 <= args.run_seconds <= 30:
        parser.error("Compilation must be 1...480 seconds; execution must be 1...30 seconds")
    swift = shutil.which("swift")
    if swift is None:
        print("PENDING: Swift unavailable; HNS native-helper/Host fixture was not run.")
        return 77
    def interrupted(signum, frame):
        raise KeyboardInterrupt("HNS fixture interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    with ExitStack() as stack:
        if args.output is None:
            preferred = Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "opencode"
            output = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="plugin-ui-hns-",
                dir=preferred if preferred.is_dir() else None)))
        else:
            output = args.output.resolve()
            if output.exists() and any(output.iterdir()):
                parser.error("--output must be fresh; the separate scratch cache may be reused")
            output.mkdir(parents=True, exist_ok=True)
        scratch = (args.scratch_path or output / "build").resolve()
        run_fixture(swift, output, scratch, args.compile_seconds, args.run_seconds, args.component_reports)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
