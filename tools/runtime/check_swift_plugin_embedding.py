"""Build/run the real Swift host + C bridge + SDK plugin integration on macOS.

Only the headless Telegram/account and UIKit service providers are strict test
fixtures. The CPython engine, NativeBridgeBinding, BridgeServices, disk settings,
SDK loader/serializer and the local nativeWaveProbe plugin execute real code.
Stage python/vendor with vendor_dependencies.py before running this probe; its
fixture imports the provided requests/cachetools packages without network I/O.
Each of the three fresh native child processes has a hard 30-second timeout; no corpus or
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
import uuid

from vendor_dependencies import digest, verify_bundle


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "python/runtime/smoke/plugins/native_wave_probe.plugin"
TIMEOUT = 30
JAVA_RUNTIME_INPUTS = (
    "virtualjava/arrays.py", "virtualjava/finder.py", "exteraless_runtime/_java_types.py",
    "exteraless_runtime/_tl.py", "exteraless_runtime/_codec.py",
)
JAVA_COHORT_INPUTS = (
    "tools/compat/tests/test_java_value_regressions.py",
    "tools/compat/tests/fixtures/java_values/schema.json",
    "tools/compat/tests/fixtures/java_values/native_codec.swift",
    "docs/wave-2/sdk-java-remediation.md",
)
REQUIRED_CHECKS = (
    "ok", "metadata_ast_only", "disabled_install", "native_bridge",
    "sdk_loader_and_serializer", "settings_unicode_and_nul", "settings_click",
    "owner_callback", "runtime_services", "provided_dependencies", "app_resume", "modify_with_params",
    "cancel_send", "permission_gate", "disabled_gate", "unload",
    "reload_persistence", "fresh_reload_interpreter", "finalized", "binding_uninstalled",
    "immutable_c_owner", "bulk_opaque_settings", "terminal_ui_lease", "owner_task_result",
    "request_response_dto", "extension_reflection", "removed_extension_unknown", "stale_owner_rejected",
    "async_callback_result",
    "transient_handles_released",
    "ui_live_models",
)
REQUIRED_TL_CHECKS = (
    "ok", "name_matching", "normalized_between_plugins", "modify_final", "cancel",
    "invalid_replacement_kept_original", "update_kinds", "post_error", "readonly_metadata",
    "native_bridge", "owner_epochs", "cleanup",
    "native_codec", "boolean_flags", "shared_flag_companions", "result_vectors",
    "request_cancel_winner", "native_text_routes", "legacy_text_origin",
    "root_config_bindings",
)
REQUIRED_HNS_CHECKS = (
    "ok", "permission_revocation", "account_revocation", "terminal_delivery", "fifo_releases",
    "nonterminal_maintenance", "sdk_unload", "retiring_no_admission", "stored_token_cleanup",
    "replacement_owner", "exact_cleanup", "native_bridge", "cleanup",
    "settings_account_scope",
    "idempotent_retiring_cleanup", "retired_owner_security", "stale_owner_security",
    "notification_registry",
)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def stage_java_sdk_cohort(python_root, output):
    """Retain exact source evidence and reject an older staged Java adapter slice.

    Native children still load the complete --python-root. These copies preserve
    the independent regression inputs; they are not an incomplete Python runtime.
    """
    inputs = []
    for relative in JAVA_RUNTIME_INPUTS:
        source = python_root / relative
        reference = ROOT / "python" / relative
        if not source.is_file() or digest(source) != digest(reference):
            raise RuntimeError("Staged Java SDK input differs from the current cohort: " + relative)
        inputs.append((source, "python/" + relative))
    inputs.extend((ROOT / relative, relative) for relative in JAVA_COHORT_INPUTS)
    rows = []
    for source, relative in inputs:
        destination = output / "java-sdk-cohort" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        rows.append({"source": str(source.resolve()), "staged": str(destination.resolve()), "sha256": digest(source)})
    return rows


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
    dto = report.get("sdk_dto_observation", {})
    if any(dto.get(key) != 0 for key in ("liveUI", "liveTasks", "liveRequests")) or len(set(dto.get("epochs", []))) != 2:
        raise RuntimeError("SDK DTO leases leaked or native owner epochs were reused")
    if report.get("sdk_dto_boundary") != "Foundation DTO recorders; no UIKit/network/server acceptance":
        raise RuntimeError("SDK DTO boundary must not claim UIKit/network delivery")
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
    epochs = [record["observation"].get("owner_token") for record in plugin_records]
    if any(not isinstance(epoch, str) for epoch in epochs) or len(set(epochs)) != 2:
        raise RuntimeError("Missing or reused native owner epoch")
    for epoch in epochs:
        uuid.UUID(epoch)  # The Host supplies independent random UUID epochs.
    if set(dto.get("epochs", [])) != set(epochs) or callbacks[0].get("owner_token") != epochs[0]:
        raise RuntimeError("C/SDK/provider/callback owner provenance differs")
    checks = plugin_records[0]["observation"].get("sdk_checks", {})
    if any(checks.get(key) is not True for key in (
        "immutable_c_owner", "bulk_opaque_settings", "terminal_ui_lease", "owner_task_result",
        "request_response_dto", "c_reflection_extension", "unadvertised_extension", "transient_handles_released", "ui_live_models")):
        raise RuntimeError("Missing real SDK/native helper observations")
    if plugin_records[0]["observation"].get("bridge_backend_calls", 0) < 1:
        raise RuntimeError("Extension reflection bypassed the actual C BridgeBackend")
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
        if observation.get("problems") or observation.get("handle_count") != 0 or observation.get("callback_leases") != 0 or observation.get("loaded_plugins") != []:
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


def validate_tl_report(report, python_root, work):
    if any(report.get(key) is not True for key in REQUIRED_TL_CHECKS):
        raise RuntimeError("Native SDK TL transform checks failed")
    if report.get("boundary") != "Foundation native TL codec and DTO recorders; no UIKit/network/state application":
        raise RuntimeError("Native SDK TL fixture boundary changed")
    traces = report.get("traces", [])
    if report.get("initializations") != 1 or report.get("finalizations") != 1 or len(traces) != 4:
        raise RuntimeError("Native SDK TL process/interpreter lifetime changed")
    if any(trace.get("destroyed") is not True or trace.get("own_gil") is not True for trace in traces):
        raise RuntimeError("Native SDK TL owner cleanup failed")
    observations = [trace["observation"] for trace in traces if trace.get("observation", {}).get("plugin_id") is not None]
    if {item["plugin_id"] for item in observations} != {"nativeTLSdkA", "nativeTLSdkZ"} or len(observations) != 2:
        raise RuntimeError("Native SDK TL fixture identities differ")
    if len({item["owner_token"] for item in observations}) != 2:
        raise RuntimeError("Native SDK TL fixtures reused their C owner epoch")
    for observation in observations:
        uuid.UUID(observation["owner_token"])
        if observation.get("bridge_builtin") is not True or observation.get("backend_installed") is not True:
            raise RuntimeError("Native SDK TL used a substituted bridge/backend")
        if any(observation.get(key) != 0 for key in ("handle_count", "callback_leases", "legacy_service_count", "mock_calls")) or observation.get("loaded_plugins") != []:
            raise RuntimeError("Native SDK TL leaked handles/SDK state or used legacy mocks")
        for key, expected in (
            ("runtime_source", python_root / "exteraless_runtime/__init__.py"),
            ("sdk_source", python_root / "sdk/extera_utils/plugin_loader.py"),
            ("plugin_source", work / "native-storage/plugins" / (observation["plugin_id"] + ".plugin")),
        ):
            if Path(observation.get(key, "")).resolve() != expected.resolve():
                raise RuntimeError("Wrong native SDK TL source: " + key)
    releases = report.get("boundary_releases", [])
    if len(releases) != 8 or len(set(releases)) != 8:
        raise RuntimeError("Native TL terminal handles were not released exactly once")
    text = report.get("legacy_text_records", [])
    if len(text) != 2 or text[0].get("originPluginIds") != ["nativeTLSdkZ"] or text[1].get("originPluginIds") is not None:
        raise RuntimeError("Legacy text lost its actual C worker ancestry")


def validate_hns_report(report, python_root, work):
    if any(report.get(key) is not True for key in REQUIRED_HNS_CHECKS):
        raise RuntimeError("Native HNS SDK lifecycle checks failed")
    if report.get("boundary") != "Real NativeServices/Host/C/SDK lifecycle; Foundation UI DTO recorder; no UIKit/network":
        raise RuntimeError("Native HNS fixture boundary changed")
    records = report.get("traces", [])
    if len(records) != 3 or report.get("initializations") != 1 or report.get("finalizations") != 1:
        raise RuntimeError("HNS maintenance changed the native process lifetime")
    observations = [row["observation"] for row in records if row.get("observation", {}).get("plugin_id") == "nativeHNSSdk"]
    if len(observations) != 2 or len({row.get("owner_token") for row in observations}) != 2:
        raise RuntimeError("HNS maintenance did not replace its actual C owner epoch")
    if report.get("hidden_owner_at_unload") != [True, True]:
        raise RuntimeError("SDK cleanup was not observed on retired interpreters")
    duplicates = report.get("retiring_duplicate_cleanups", [])
    if len(duplicates) != 8 or len(set(duplicates)) != 8:
        raise RuntimeError("Retiring production-route duplicate cleanup was not checked in both epochs")
    identities = report.get("release_identities", [])
    if len(identities) != 31 or len(set(identities)) != 31:
        raise RuntimeError("HNS native cleanup/release was not exactly once")
    if any(row.get("destroyed") is not True or row.get("own_gil") is not True for row in records):
        raise RuntimeError("HNS owner interpreter cleanup failed")
    for row in observations:
        uuid.UUID(row["owner_token"])
        if row.get("bridge_builtin") is not True or row.get("backend_installed") is not True:
            raise RuntimeError("HNS probe substituted the native C backend")
        if any(row.get(key) != 0 for key in ("handle_count", "callback_leases", "legacy_service_count", "mock_calls")) or row.get("loaded_plugins") != []:
            raise RuntimeError("HNS SDK/native state leaked or used mocks")
        for key, expected in (("runtime_source", python_root / "exteraless_runtime/__init__.py"),
                              ("sdk_source", python_root / "sdk/extera_utils/plugin_loader.py"),
                              ("plugin_source", work / "native-storage/plugins/nativeHNSSdk.plugin")):
            if Path(row.get(key, "")).resolve() != expected.resolve():
                raise RuntimeError("Wrong native HNS SDK source: " + key)


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
        "virtualjava/registry.py", "exteraless_runtime/_callbacks.py", "exteraless_runtime/_controllers.py", "exteraless_runtime/_notifications.py",
        "exteraless_runtime/_config.py", "exteraless_runtime/_config_manifest.py", "exteraless_runtime/_tl.py",
        "exteraless_runtime/_pills.py", "exteraless_runtime/_pill_types.py",
        "sdk/base_plugin.py", "sdk/android_utils.py", "sdk/ui/settings.py",
        "sdk/extera_utils/metadata_parser.py", "sdk/extera_utils/plugin_loader.py",
        "vendor/exteraless-dependencies.json",
    )]
    required_python.extend(python_root / relative for relative in JAVA_RUNTIME_INPUTS)
    schema = python_root / "tl-schema.json"
    if not schema.is_file():
        schema = python_root / "runtime/tl-schema.json"
    required_python.append(schema)
    for path in [plugin, *required_python]:
        if not path.is_file():
            parser.error("Missing integration input: " + str(path))
    schema_metadata = json.loads(schema.read_text(encoding="utf-8"))
    if any(not schema_metadata.get("hookNames", {}).get(name) for name in ("users.getUsers", "updateUserName", "updates", "messages.sendMessage", "stories.readStories", "messages.receivedQueue")):
        parser.error("TL phase 2 requires the generated hookNames table")
    dependency_lock = ROOT / "python/runtime/dependency-lock.json"
    dependencies = verify_bundle(python_root / "vendor", digest(dependency_lock))
    output.mkdir(parents=True, exist_ok=True)
    java_cohort = stage_java_sdk_cohort(python_root, output)
    report_path = output / "swift-plugin-smoke.json"
    write_json(report_path, {"ok": False, "phase": "build", "probe": "swift-plugin-embedding"})
    work = Path(tempfile.mkdtemp(prefix="run-", dir=output)).resolve()
    tl_work = Path(tempfile.mkdtemp(prefix="run-tl-", dir=output)).resolve()
    hns_work = Path(tempfile.mkdtemp(prefix="run-hns-", dir=output)).resolve()
    build = output / "build"
    build.mkdir()
    (work / "input").mkdir()
    (work / "probe-support").mkdir()
    staged_plugin = work / "input/native_wave_probe.plugin"
    shutil.copyfile(plugin, staged_plugin)
    helper_source = ROOT / "python/runtime/smoke/native_plugin_probe.py"
    helper = work / "probe-support/native_plugin_probe.py"
    shutil.copyfile(helper_source, helper)
    (tl_work / "input").mkdir()
    (tl_work / "probe-support").mkdir()
    tl_fixtures = [ROOT / "python/runtime/smoke/plugins" / name for name in ("native_tl_first.plugin", "native_tl_second.plugin")]
    for source in tl_fixtures:
        shutil.copyfile(source, tl_work / "input" / source.name)
    tl_helper_source = ROOT / "python/runtime/smoke/native_tl_probe.py"
    tl_helper = tl_work / "probe-support/native_tl_probe.py"
    shutil.copyfile(tl_helper_source, tl_helper)
    (hns_work / "input").mkdir()
    (hns_work / "probe-support").mkdir()
    hns_fixture = ROOT / "python/runtime/smoke/plugins/native_hns_probe.plugin"
    staged_hns = hns_work / "input/native_hns_probe.plugin"
    hns_helper_source = ROOT / "python/runtime/smoke/native_hns_probe.py"
    hns_helper = hns_work / "probe-support/native_hns_probe.py"
    shutil.copyfile(hns_fixture, staged_hns)
    shutil.copyfile(hns_helper_source, hns_helper)
    for source in [*tl_fixtures, hns_fixture]:
        if source.stat().st_size > 32_768:
            parser.error("Own native fixture exceeds 32 KiB: " + str(source))
    # Small declaration fixture only: no generated corpus manifest is loaded.
    write_json(work / "manifest.json", {"classes": {
        "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
        "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
    }})
    shutil.copyfile(work / "manifest.json", tl_work / "manifest.json")
    shutil.copyfile(work / "manifest.json", hns_work / "manifest.json")
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1")
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    native = ROOT / "python/runtime"
    shims = ROOT / "swift/PluginHost/Sources/CPluginHostShims"
    swift_sources = sorted((ROOT / "swift/PluginHost/Sources/PluginHost").glob("*.swift"))
    probe = native / "smoke/swift_plugin_probe.swift"
    dto_fixture = native / "smoke/swift_sdk_fixture.swift"
    tl_probe = native / "smoke/swift_sdk_tl_probe.swift"
    tl_fixture = native / "smoke/swift_sdk_tl_fixture.swift"
    hns_probe = native / "smoke/swift_sdk_hns_probe.swift"
    hns_native_fixture = native / "smoke/swift_sdk_hns_fixture.swift"
    config_fixture = native / "smoke/swift_sdk_config_root_fixture.swift"
    config_provider = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift"
    # Stage the actual consumed root expression, not a handpicked compatibility
    # registration. Missing SDK01 registration must fail before native compilation.
    sys.path.insert(0, str(ROOT))
    from tools.compat.sdk_config_manifest import root_registration
    root_pins = {}
    registered_root = root_registration(root_pins)
    root_fixture = build / "SDKConfigRootRegistration.swift"
    root_fixture.write_text("import ExteralessCore\n\nenum SDKConfigRootRegistration {\n"
        "    static var definitions: [ClientSettingDefinition] {\n"
        "        var result: [ClientSettingDefinition] = []\n" +
        "".join("        result.append(contentsOf: " + group + ")\n" for group in registered_root["groups"]) +
        "        return result\n    }\n}\n", encoding="utf-8")
    core_package = ROOT / "swift/ExteralessCore"
    core_sources = sorted((core_package / "Sources/ExteralessCore").glob("*.swift"))
    codec_root = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime"
    codec_sources = [codec_root / "TLCodec.swift", codec_root / "TLSchemaGenerated.swift",
                     codec_root / "TLTransformCodec.swift", codec_root / "TLUpdatePolicy.swift"]
    sdk_swift_sources = [probe, dto_fixture, tl_probe, tl_fixture, hns_probe, hns_native_fixture, config_fixture, config_provider, root_fixture, *codec_sources]
    # Compile only the reviewed version-pinned compatibility translation unit.
    compat_sources = [native / "cpython312_compat.c"]
    c_sources = [ROOT / "python/bridge/_exteraless_bridge.c", native / "register_bridge.c",
                 native / "engine.c", *compat_sources, shims / "ph_atomic.c"]
    python_sources = [path for package in ("sdk", "virtualjava", "exteraless_runtime")
                      for path in sorted((python_root / package).rglob("*.py"))]
    sources = set([*c_sources, *swift_sources, *core_sources, core_package / "Package.swift", ROOT / registered_root["path"],
                   *sdk_swift_sources, helper_source, tl_helper_source, hns_helper_source, hns_fixture, plugin, *tl_fixtures, *required_python,
                   *python_sources, dependency_lock,
                    *sorted((native / "include").glob("*.h")), native / "cpython312_compat.h"])
    sources.update(Path(row["source"]) for row in java_cohort)
    try:
        config = python_configuration(args.python.expanduser())
        write_json(output / "host-python.json", config)
        write_json(output / "build-inputs.json", {
            "source_sha256": {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(sources)},
            "dependency_bundle_sha256": dependencies["bundle_sha256"],
            "compat_sources": [str(path) for path in compat_sources],
            "python_root": str(python_root), "plugin": str(plugin), "work_directory": str(work),
            "runtime_timeout_seconds": TIMEOUT,
            "native_children": 3, "tl_work_directory": str(tl_work), "hns_work_directory": str(hns_work),
            "root_registration": registered_root, "root_source_sha256": root_pins,
            "java_sdk_cohort": java_cohort,
        })
        with (output / "swift-plugin-build.log").open("w", encoding="utf-8") as log:
            core_build = ["xcrun", "swift", "build", "--package-path", core_package,
                          "--scratch-path", build / "core-build", "--configuration", "debug"]
            run([*core_build, "--target", "ExteralessCore"], log=log, timeout=240, cwd=build, env=env)
            core_bin = Path(subprocess.check_output([str(item) for item in [*core_build, "--show-bin-path"]], text=True, timeout=15, cwd=build, env=env).strip())
            core_objects = sorted((core_bin / "ExteralessCore.build").glob("*.o"))
            if not core_objects or not (core_bin / "Modules/ExteralessCore.swiftmodule").exists():
                raise RuntimeError("Core build did not produce its actual module/objects for the root Config fixture")
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
                 "-module-name", "PluginHost", "-sdk", sdk, "-I", native / "include", "-I", modules, "-I", core_bin / "Modules",
                 *swift_sources, *sdk_swift_sources, *objects, *core_objects, "-Xlinker", library,
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
        report.update(ok=False, phase="tl-phase2")
        write_json(report_path, report)
        tl_report_path = output / "swift-sdk-tl-smoke.json"
        tl_started = time.monotonic()
        with (output / "swift-sdk-tl-console.log").open("w", encoding="utf-8") as log:
            run([executable, tl_report_path, config["home"], config["stdlib"], config["dynload"],
                 python_root, tl_work / "input", tl_work, tl_helper, "--tl-phase2"],
                log=log, timeout=TIMEOUT, cwd=tl_work, env=env)
        tl_report = json.loads(tl_report_path.read_text(encoding="utf-8"))
        validate_tl_report(tl_report, python_root, tl_work)
        if "EXTERALESS_SWIFT_SDK_TL_PROBE_OK" not in (output / "swift-sdk-tl-console.log").read_text(encoding="utf-8"):
            raise RuntimeError("Native TL SDK probe did not emit its completion marker")
        tl_report["native_process_seconds"] = round(time.monotonic() - tl_started, 3)
        tl_report["runtime_timeout_seconds"] = TIMEOUT
        write_json(tl_report_path, tl_report)
        report.update(ok=False, phase="hns-remediation", tl_phase2=True, tl_report=tl_report_path.name)
        write_json(report_path, report)
        hns_report_path = output / "swift-sdk-hns-smoke.json"
        hns_started = time.monotonic()
        with (output / "swift-sdk-hns-console.log").open("w", encoding="utf-8") as log:
            run([executable, hns_report_path, config["home"], config["stdlib"], config["dynload"],
                 python_root, staged_hns, hns_work, hns_helper, "--hns-remediation"],
                log=log, timeout=TIMEOUT, cwd=hns_work, env=env)
        hns_report = json.loads(hns_report_path.read_text(encoding="utf-8"))
        validate_hns_report(hns_report, python_root, hns_work)
        if "EXTERALESS_SWIFT_SDK_HNS_PROBE_OK" not in (output / "swift-sdk-hns-console.log").read_text(encoding="utf-8"):
            raise RuntimeError("Native HNS SDK probe did not emit its completion marker")
        hns_report.update(native_process_seconds=round(time.monotonic() - hns_started, 3), runtime_timeout_seconds=TIMEOUT)
        write_json(hns_report_path, hns_report)
        report.update(ok=True, phase="complete", hns_remediation=True, hns_report=hns_report_path.name, native_children=3)
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
