"""Build/run the real Swift host + C bridge + SDK plugin integration on macOS.

Only the headless Telegram/account and UIKit service providers are strict test
fixtures. The CPython engine, NativeBridgeBinding, BridgeServices, disk settings,
SDK loader/serializer and the local nativeWaveProbe plugin execute real code.
Stage python/vendor with vendor_dependencies.py before running this probe; its
fixture imports the provided requests/cachetools packages without network I/O.
The single native child process has a hard 30-second timeout; no corpus or
network operation is used. --output must be empty; its run-* directory retains
the isolated install/settings files and helper for inspection after the run.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from vendor_dependencies import digest, verify_bundle


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "python/runtime/smoke/plugins/native_wave_probe.plugin"
TIMEOUT = 30
REQUIRED_CHECKS = (
    "ok", "metadata_ast_only", "disabled_install", "native_bridge",
    "sdk_loader_and_serializer", "settings_unicode_and_nul", "settings_click",
    "owner_callback", "runtime_services", "provided_dependencies", "app_resume", "modify_with_params",
    "cancel_send", "permission_gate", "disabled_gate", "unload",
    "reload_persistence", "fresh_reload_interpreter", "finalized", "binding_uninstalled",
)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(command, *, log, timeout=180, **kwargs):
    command = [str(item) for item in command]
    log.write("COMMAND " + json.dumps(command, ensure_ascii=False) + "\n")
    log.flush()
    return subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=timeout, **kwargs)


def python_configuration(python):
    query = (
        "import json,sys,sysconfig; "
        "print(json.dumps(dict(version=list(sys.version_info[:3]), full_version=sys.version, "
        "home=sys.base_prefix, include=sysconfig.get_path('include'), stdlib=sysconfig.get_path('stdlib'), "
        "dynload=sysconfig.get_config_var('DESTSHARED'), libdir=sysconfig.get_config_var('LIBDIR'), "
        "library=sysconfig.get_config_var('LDLIBRARY'))))"
    )
    config = json.loads(subprocess.check_output([str(python), "-I", "-S", "-c", query], text=True, timeout=15))
    if config["version"][:2] != [3, 12]:
        raise RuntimeError("The native embedding requires matching CPython 3.12 headers and library")
    home = Path(config["home"])
    candidates = [
        Path(config["libdir"] or home / "lib") / (config["library"] or "libpython3.12.dylib"),
        home / "lib/libpython3.12.dylib", home / "Python",
    ]
    library = next((path.resolve() for path in candidates if path.is_file()), None)
    if library is None:
        raise RuntimeError("Cannot locate host CPython library: " + repr(candidates))
    config["linked_library"] = str(library)
    config["dynload"] = config["dynload"] or str(Path(config["stdlib"]) / "lib-dynload")
    return config


def validate_report(report, python_root, work):
    missing = [key for key in REQUIRED_CHECKS if report.get(key) is not True]
    if missing:
        raise RuntimeError("Native integration checks did not pass: " + ", ".join(missing))
    if report.get("uikit_executed") is not False or report.get("telegram_services_executed") is not False:
        raise RuntimeError("Headless provider results must be labeled as test fixtures")
    if report.get("unexpected_effects") != [] or report.get("completed_callbacks") != 1:
        raise RuntimeError("Unexpected native UI/network effect or incomplete callback")
    callbacks = report.get("callback_requests", [])
    if len(callbacks) != 1 or callbacks[0].get("arrived_on_main_thread") is not False:
        raise RuntimeError("The actual C -> Swift callback was not observed on its owner worker")
    trace = report.get("native_trace", {})
    records = trace.get("interpreters", [])
    if trace.get("initializations") != 1 or trace.get("finalizations") != 1 or len(records) != 3:
        raise RuntimeError("Expected one process lifetime, one metadata inspector and two real plugin interpreters")
    if any(record.get("destroyed") is not True or record.get("own_gil") is not True or record.get("errors") for record in records):
        raise RuntimeError("Native interpreter cleanup/OWN_GIL/source execution failed")
    plugin_records = [record for record in records if record.get("observation", {}).get("plugin_id") == "nativeWaveProbe"]
    if len(plugin_records) != 2:
        raise RuntimeError("Missing native plugin interpreter observations")
    ids = [record["native_reference"] for record in plugin_records]
    if ids != report.get("plugin_interpreter_ids") or len(set(ids)) != 2:
        raise RuntimeError("Reload did not use a new native C interpreter token")
    loader_path = (python_root / "sdk/extera_utils/plugin_loader.py").resolve()
    for record in plugin_records:
        observation = record["observation"]
        if observation.get("bridge_builtin") is not True or observation.get("backend_installed") is not True:
            raise RuntimeError("Plugin used something other than the built-in native bridge")
        if observation.get("transport_calls", 0) <= 0 or observation.get("legacy_service_count") != 0 or observation.get("mock_calls") != 0:
            raise RuntimeError("Native xt_call_host transport was not exercised without mocks")
        if observation.get("problems") or observation.get("handle_count") != 0 or observation.get("loaded_plugins") != []:
            raise RuntimeError("The owner profiler or SDK/native unload failed")
        sources = observation.get("sources", {})
        for function in ("load_plugin", "unload_plugin", "get_settings_json", "_serialize_setting_item"):
            if Path(sources.get(function, "")).resolve() != loader_path:
                raise RuntimeError("SDK function did not execute from its real source: " + function)
        fixture_source = Path(sources.get("fixture.on_plugin_load", "")).resolve()
        if fixture_source != (work / "native-storage/plugins/nativeWaveProbe.plugin").resolve():
            raise RuntimeError("The installed fixture source did not execute")
        for module, relative in (
            ("base_plugin", "sdk/base_plugin.py"), ("ui.settings", "sdk/ui/settings.py"),
            ("exteraless_runtime", "exteraless_runtime/__init__.py"), ("virtualjava", "virtualjava/__init__.py"),
        ):
            if Path(observation.get("module_paths", {}).get(module, "")).resolve() != (python_root / relative).resolve():
                raise RuntimeError("Wrong SDK/runtime module source: " + module)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, default=Path(sys.executable))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--python-root", type=Path, default=ROOT / "python")
    parser.add_argument("--plugin", type=Path, default=FIXTURE,
                        help="Local source fixture implementing the nativeWaveProbe contract")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native Swift/CPython integration compilation requires macOS and Xcode")
    output = args.output.expanduser().resolve()
    python_root = args.python_root.expanduser().resolve()
    plugin = args.plugin.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be empty to exclude stale build/probe results")
    required_python = [python_root / name for name in (
        "virtualjava/__init__.py", "exteraless_runtime/__init__.py", "exteraless_runtime/_platform.py",
        "sdk/base_plugin.py", "sdk/android_utils.py", "sdk/ui/settings.py",
        "sdk/extera_utils/metadata_parser.py", "sdk/extera_utils/plugin_loader.py",
        "vendor/exteraless-dependencies.json",
    )]
    for path in [plugin, *required_python]:
        if not path.is_file():
            parser.error("Missing integration input: " + str(path))
    dependency_lock = ROOT / "python/runtime/dependency-lock.json"
    dependencies = verify_bundle(python_root / "vendor", digest(dependency_lock))
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "swift-plugin-smoke.json"
    write_json(report_path, {"ok": False, "phase": "build", "probe": "swift-plugin-embedding"})
    work = Path(tempfile.mkdtemp(prefix="run-", dir=output)).resolve()
    build = output / "build"
    build.mkdir()
    (work / "input").mkdir()
    (work / "probe-support").mkdir()
    staged_plugin = work / "input/native_wave_probe.plugin"
    shutil.copyfile(plugin, staged_plugin)
    helper_source = ROOT / "python/runtime/smoke/native_plugin_probe.py"
    helper = work / "probe-support/native_plugin_probe.py"
    shutil.copyfile(helper_source, helper)
    # Small declaration fixture only: no generated corpus manifest is loaded.
    write_json(work / "manifest.json", {"classes": {
        "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
        "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
    }})
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1")
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    native = ROOT / "python/runtime"
    shims = ROOT / "swift/PluginHost/Sources/CPluginHostShims"
    swift_sources = sorted((ROOT / "swift/PluginHost/Sources/PluginHost").glob("*.swift"))
    probe = native / "smoke/swift_plugin_probe.swift"
    # Compile only the reviewed version-pinned compatibility translation unit.
    compat_sources = [native / "cpython312_compat.c"]
    c_sources = [ROOT / "python/bridge/_exteraless_bridge.c", native / "register_bridge.c",
                 native / "engine.c", *compat_sources, shims / "ph_atomic.c"]
    python_sources = [path for package in ("sdk", "virtualjava", "exteraless_runtime")
                      for path in sorted((python_root / package).rglob("*.py"))]
    sources = set([*c_sources, *swift_sources, probe, helper_source, plugin, *required_python,
                   *python_sources, dependency_lock,
                   *sorted((native / "include").glob("*.h")), native / "cpython312_compat.h"])
    try:
        config = python_configuration(args.python.expanduser())
        write_json(output / "host-python.json", config)
        write_json(output / "build-inputs.json", {
            "source_sha256": {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(sources)},
            "dependency_bundle_sha256": dependencies["bundle_sha256"],
            "compat_sources": [str(path) for path in compat_sources],
            "python_root": str(python_root), "plugin": str(plugin), "work_directory": str(work),
            "runtime_timeout_seconds": TIMEOUT,
        })
        with (output / "swift-plugin-build.log").open("w", encoding="utf-8") as log:
            objects = []
            for source in c_sources:
                obj = build / (source.stem + ".o")
                run(["xcrun", "--sdk", "macosx", "clang", "-std=c11", "-O1",
                     "-DEXL_ENGINE_DEBUG_MEMORY=1", "-Werror=implicit-function-declaration",
                     "-I", config["include"], "-I", native / "include", "-I", shims / "include",
                     "-c", source, "-o", obj], log=log, cwd=build, env=env)
                objects.append(obj)
            modules = build / "CPluginHostShims"
            modules.mkdir()
            (modules / "module.modulemap").write_text(
                "module CPluginHostShims {\n  header " + json.dumps(str(shims / "include/ph_atomic.h")) + "\n  export *\n}\n",
                encoding="utf-8")
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, timeout=15).strip()
            executable = build / "swift-plugin-probe"
            library = Path(config["linked_library"])
            run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "6", "-parse-as-library",
                 "-module-name", "PluginHost", "-sdk", sdk, "-I", native / "include", "-I", modules,
                 *swift_sources, probe, *objects, "-Xlinker", library,
                 "-Xlinker", "-rpath", "-Xlinker", library.parent, "-o", executable],
                log=log, timeout=240, cwd=build, env=env)
        started = time.monotonic()
        with (output / "swift-plugin-console.log").open("w", encoding="utf-8") as log:
            run([executable, report_path, config["home"], config["stdlib"], config["dynload"],
                 python_root, staged_plugin, work, helper], log=log, timeout=TIMEOUT, cwd=work, env=env)
        elapsed = time.monotonic() - started
        report = json.loads(report_path.read_text(encoding="utf-8"))
        validate_report(report, python_root, work)
        if "EXTERALESS_SWIFT_PLUGIN_PROBE_OK" not in (output / "swift-plugin-console.log").read_text(encoding="utf-8"):
            raise RuntimeError("Native probe did not emit its completion marker")
        report["native_process_seconds"] = round(elapsed, 3)
        report["runtime_timeout_seconds"] = TIMEOUT
        report["build_inputs"] = "build-inputs.json"
        report["work_directory"] = str(work)
        write_json(report_path, report)
        print("Swift + C bridge + SDK plugin integration passed: " + str(report_path))
    except Exception as error:
        report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.is_file() else {}
        report.update(ok=False, driver_error=str(error), work_directory=str(work), runtime_timeout_seconds=TIMEOUT)
        write_json(report_path, report)
        raise SystemExit("Swift plugin integration failed; inspect " + str(output) + ": " + str(error)) from error


if __name__ == "__main__":
    main()
