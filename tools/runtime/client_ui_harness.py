#!/usr/bin/env python3
"""Run the real UIKit app on ONE newly created simulator, then extract recorded frames.

No UDID/template/account/plugin input is accepted. The app process (including
native fixture plugin startup) gets 30 seconds per scenario. This gate reports
semantic success and frame availability; a human must still review the frames.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

from client_ui_harness_domains import (DOMAIN_SCENARIOS, batch_name, check_manifest, complete_batch,
                                       manifest_from_ipa, selected_scenarios, validate_domain)
from client_ui_harness_visuals import (VISUAL_SCENARIOS, BUILD_SELECTION, copy_visual_artifacts,
                                       recorded_frame_index, validate_visual)

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "org.exteraless.ClientUIHarness"
APP_ROOT = "Payload/ClientUIHarness.app"
RUNTIME_SECONDS = 30
DEVICE_PREFIX = "EXL-UI-"
SCENARIOS = ("core-light", "core-dark", "sdk-ui")
CORE_PROBES = ["home", "settings-root", "toggle-confirmed", "selector-open", "selector-committed",
               "text-keyboard", "text-committed", "number-error", "number-committed", "core-cleanup"]
SDK_PROBES = ["home", "plugin-manager", "plugin-settings", "alert-shown", "alert-keyboard",
              "alert-dark-draft", "alert-closed", "sheet-widgets", "sheet-closed", "menu-shown", "menu-closed",
              "sdk-navigation", "sdk-leases-clean", "fixture-reloaded", "sdk-cleanup"]


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def stop_process(process, *, interrupt=False):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGINT if interrupt else signal.SIGTERM)
        process.wait(timeout=5)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def command(args, *, timeout=15, log=None, cwd=None, stdout=None, stderr=None):
    args = [str(arg) for arg in args]
    if timeout <= 0:
        raise TimeoutError("command deadline expired")
    if log is not None:
        log.write("COMMAND " + json.dumps(args) + "\n")
        log.flush()
    process = subprocess.Popen(args, cwd=cwd, stdout=stdout or subprocess.PIPE,
                               stderr=stderr if stderr is not None else (subprocess.STDOUT if stdout is not None else subprocess.PIPE),
                               text=True, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=timeout)
    except BaseException:
        stop_process(process)
        raise
    if log is not None:
        log.write((output or "") + (errors or ""))
        log.flush()
    if process.returncode:
        raise RuntimeError("command failed ({}): {}\n{}".format(process.returncode, " ".join(args), (errors or "")[-4000:]))
    return output or ""


def load_packaging(telegram):
    spec = importlib.util.spec_from_file_location("client_harness_packaging", telegram / "build-system/Make/RuntimePackaging.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_ipa(ipa, manifest_path, telegram):
    """Use the existing Mach-O reader; check the harness's actual bundle paths."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    spec = manifest["targets"]["simulator"]
    packaging = load_packaging(telegram)
    source_patches = packaging.validate_patch_provenance(manifest.get("client_source_patches"))
    if packaging.verify_client_sources(telegram) != source_patches:
        raise ValueError("Harness client source patch inputs changed since staging")
    expected = dict(spec["resources"], **manifest["assets"])
    frameworks = ["Python", *spec["extension_frameworks"], *(item["framework"] for item in spec.get("native_frameworks", []))]
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate entries")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("IPA contains an unsafe path")
            if name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name:
                raise ValueError("Harness IPA must use unsigned packaging")
        info = plistlib.loads(archive.read(APP_ROOT + "/Info.plist"))
        if info.get("CFBundleIdentifier") != BUNDLE or info.get("CFBundleExecutable") != "ClientUIHarness":
            raise ValueError("IPA is not the dedicated harness app")
        actual = {name[len(APP_ROOT) + 1:] for name in names if not name.endswith("/") and
                  (name.startswith(APP_ROOT + "/python/") or name.startswith(APP_ROOT + "/python-stdlib/"))}
        if actual != set(expected):
            raise ValueError("Full Python resource paths differ from runtime staging")
        for name, sha in expected.items():
            with archive.open(APP_ROOT + "/" + name) as stream:
                value = hashlib.file_digest(stream, "sha256").hexdigest()
            if value != sha:
                raise ValueError("Runtime resource hash differs: " + name)
        fixture = "Tests/ExteralessHarness/Fixtures/client_ui_fixture.plugin"
        if archive.read(APP_ROOT + "/client_ui_fixture.plugin") != (telegram / fixture).read_bytes():
            raise ValueError("Bundled plugin is not the owned fixture source")
        for resource in ("PresentationStrings.data", "en.lproj/Localizable.strings", "Assets.car"):
            if APP_ROOT + "/" + resource not in names:
                raise ValueError("Required UIKit/string resource missing: " + resource)
        binary = packaging.macho_loads(archive, APP_ROOT + "/ClientUIHarness", 7)
        ui = packaging.macho_loads(archive, APP_ROOT + "/Frameworks/TelegramUIFramework.framework/TelegramUIFramework", 7)
        if "@executable_path/Frameworks" not in binary["rpaths"] or "@loader_path/.." not in ui["rpaths"]:
            raise ValueError("MainApp/TelegramUI sibling framework rpath missing")
        if "@rpath/Python.framework/Python" not in ui["loads"]:
            raise ValueError("TelegramUIFramework did not link the real Python runtime")
        for name in frameworks:
            path = APP_ROOT + "/Frameworks/{0}.framework/{0}".format(name)
            packaging.macho_loads(archive, path, spec["platform_id"])
        packaging.verify_dependency_archive(archive, APP_ROOT, manifest)
    return {"ipaSha256": digest(ipa), "bundle": BUNDLE, "frameworks": frameworks,
            "clientSourcePatches": source_patches,
            "runtimeResources": len(expected), "simulatorPlatform": 7, "runtimeExecutionVerified": False}


def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid SDK/runtime version")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def select_device_type_and_runtime(types, runtimes, sdk):
    matches = [item for item in types if item.get("name") == "iPhone 17"]
    if len(matches) != 1:
        raise RuntimeError("Exactly one iPhone 17 device TYPE is required; no template fallback")
    device_type = matches[0]["identifier"]
    candidates = []
    for runtime in runtimes:
        if (runtime.get("isAvailable") is not True or
                not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+(?:-\d+){0,2}", runtime.get("identifier", ""))):
            continue
        if not (15, 0, 0) <= version(runtime["version"]) <= version(sdk):
            continue
        supported = runtime.get("supportedDeviceTypes")
        if supported and not any(item.get("identifier") == device_type for item in supported):
            continue
        candidates.append(runtime)
    if not candidates:
        raise RuntimeError("No available generic iOS runtime compatible with the selected SDK and iPhone 17")
    return device_type, max(candidates, key=lambda item: version(item["version"]))


def validate_state(state, scenario, run_id):
    if (state.get("format") != "exteraless-client-ui-harness/1" or state.get("runId") != run_id or
            state.get("scenario") != scenario or state.get("phase") != "completed" or state.get("semanticPassed") is not True):
        raise ValueError("Harness did not complete this exact run")
    expected = SDK_PROBES if scenario == "sdk-ui" else CORE_PROBES
    if scenario not in DOMAIN_SCENARIOS + VISUAL_SCENARIOS and [probe.get("name") for probe in state.get("probes", [])] != expected:
        raise ValueError("Missing/reordered UIKit probes; a zero-scenario pass is forbidden")
    if state.get("unexpectedServices") != [] or state.get("visualReview") != "pending-recorded-frame-review":
        raise ValueError("Unexpected service effect or unsupported visual-pass claim")
    for probe in state["probes"]:
        if not probe.get("elements") or not probe.get("controllers") or probe.get("scale", 0) <= 0:
            raise ValueError("Probe contains no observed UIKit hierarchy")
    if scenario in DOMAIN_SCENARIOS:
        validate_domain(state, scenario)
    elif scenario in VISUAL_SCENARIOS:
        check_manifest(state.get("facts", {}).get("domainSources", {}))
        bootstrap = state.get("facts", {}).get("bootstrap", {})
        if (bootstrap.get("apiIdentity") != "synthetic-private-fixture-store" or bootstrap.get("systemKeychain") is not False
                or bootstrap.get("retention") != "registered-main-application-snapshot-before-writer"):
            raise ValueError("Final visual fixture did not establish the Account/bootstrap boundary")
        validate_visual(state, scenario)
    elif scenario == "sdk-ui":
        runtime = state.get("facts", {}).get("runtime", {})
        engine = runtime.get("engine", {})
        created, destroyed = engine.get("created", []), engine.get("destroyed", [])
        if (runtime.get("realPython") is not True or runtime.get("stopped") is not True or
                engine.get("initializations") != 1 or engine.get("finalizations") != 1 or
                len(created) != 3 or len(set(created)) != 3 or created != destroyed or engine.get("scriptCalls", 0) < 1):
            raise ValueError("Actual CPython inspector + two plugin lifetimes did not clean up")
        epochs, c_epochs = runtime.get("hostEpochs", []), runtime.get("ui", {}).get("cEpochs", [])
        if len(epochs) != 2 or len(set(epochs)) != 2 or set(epochs) != set(c_epochs):
            raise ValueError("Reload did not use fresh observed C/Host epochs")
        if runtime.get("ui", {}).get("nativeUICalls", 0) < 5:
            raise ValueError("Actual C -> native UIKit provider was not exercised")
    elif state.get("facts", {}).get("realPython") is not False:
        raise ValueError("Core-only scenario incorrectly claimed Python execution")


def wait_state(path, scenario, run_id, phase, deadline):
    while time.monotonic() < deadline:
        if path.is_file():
            if path.stat().st_size > 8 * 1024 * 1024:
                raise ValueError("Harness report exceeds 8 MiB")
            state = json.loads(path.read_text(encoding="utf-8"))
            if state.get("runId") != run_id or state.get("scenario") != scenario:
                raise ValueError("Stale/wrong harness report")
            if state.get("phase") == "failed":
                raise RuntimeError("UIKit scenario failed: " + str(state.get("error")))
            if state.get("phase") == phase:
                return state
        time.sleep(0.05)
    raise TimeoutError("Harness {} deadline expired".format(phase))


def extract_app(ipa, directory):
    with zipfile.ZipFile(ipa) as archive:
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in item.filename:
                raise ValueError("Unsafe IPA extraction path")
            if not item.filename.startswith(APP_ROOT + "/"):
                continue
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ValueError("Unexpected symlink in thin iOS app")
            archive.extract(item, directory)
            target = directory / item.filename
            if target.is_file():
                target.chmod(mode & 0o777 or 0o644)
    app = directory / APP_ROOT
    (app / "ClientUIHarness").chmod(0o755)
    return app


def owned_device(record, devices):
    try:
        uuid.UUID(record.get("udid", ""))
        uuid.UUID(record.get("name", "").removeprefix(DEVICE_PREFIX))
    except (ValueError, TypeError, AttributeError):
        return False
    if not record.get("name", "").startswith(DEVICE_PREFIX):
        return False
    return any(item.get("udid") == record["udid"] and item.get("name") == record["name"]
               and item.get("deviceTypeIdentifier") == record["deviceType"]
               for item in devices.get(record["runtime"], []))


def delete_owned_device(record, log):
    devices = json.loads(command(["xcrun", "simctl", "list", "devices", "-j"], log=log))["devices"]
    if not owned_device(record, devices):
        raise RuntimeError("Refusing to clean up an unowned or changed simulator")
    try:
        command(["xcrun", "simctl", "shutdown", record["udid"]], log=log, timeout=15)
    except RuntimeError:
        pass  # A device that never completed boot is already shut down.
    command(["xcrun", "simctl", "delete", record["udid"]], log=log, timeout=15)


def run_scenario(udid, scenario, output, log):
    destination = output / scenario
    destination.mkdir()
    run_id = str(uuid.uuid4())
    data = Path(command(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"], log=log).strip())
    state_path = data / "Documents/client-ui-harness" / run_id / "state.json"
    start, wall_start = time.monotonic(), time.time()
    deadline = start + RUNTIME_SECONDS
    recorder = None
    recorder_log = None
    timing = {"runId": run_id, "scenario": scenario, "launchHostWallTime": wall_start,
              "processDeadlineSeconds": RUNTIME_SECONDS, "frameTimestamps": "ffprobe PTS, never index/fps"}
    try:
        command(["xcrun", "simctl", "launch", "--terminate-running-process",
                 "--stdout=" + str(destination / "app-stdout.log"), "--stderr=" + str(destination / "app-stderr.log"),
                 udid, BUNDLE, "-client-ui-harness", "1", "-client-run-id", run_id, "-client-scenario", scenario],
                log=log, timeout=min(8, deadline - time.monotonic()))
        wait_state(state_path, scenario, run_id, "ready", min(start + 10, deadline))
        recorder_log = (destination / "record.log").open("w", encoding="utf-8")
        timing["recordCommandHostWallTime"] = time.time()
        recorder = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force",
                                     str(destination / "recording.mp4")], stdout=recorder_log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        recording_deadline = min(time.monotonic() + 4, deadline)
        while "Recording started" not in (destination / "record.log").read_text(encoding="utf-8"):
            if recorder.poll() is not None or time.monotonic() >= recording_deadline:
                raise RuntimeError("simctl recordVideo did not start within 4 seconds")
            time.sleep(0.05)
        timing["recordStartedObservedHostWallTime"] = time.time()
        time.sleep(0.25)
        timing["runURLHostWallTime"] = time.time()
        command(["xcrun", "simctl", "openurl", udid, "exteraless-ui-harness://run/" + run_id],
                log=log, timeout=min(4, deadline - time.monotonic()))
        state = wait_state(state_path, scenario, run_id, "completed", deadline)
        timing["completedHostWallTime"] = time.time()
        timing["processSeconds"] = time.monotonic() - start
        validate_state(state, scenario, run_id)
        time.sleep(0.4)  # Passive settled tail; SDK plugin has already finalized.
        return {"scenario": scenario, "runId": run_id, "semanticPassed": True,
                "processSeconds": timing["processSeconds"], "visualReview": "pending-recorded-frame-review"}
    finally:
        # Stop ONLY the bundle on the device created by this driver. Retain a
        # failure screenshot and partial JSON too, without copying account data.
        if recorder is not None:
            stop_process(recorder, interrupt=True)
        if recorder_log is not None:
            recorder_log.close()
        try:
            command(["xcrun", "simctl", "io", udid, "screenshot", str(destination / "last-screen.png")], log=log, timeout=4)
        finally:
            try:
                command(["xcrun", "simctl", "terminate", udid, BUNDLE], log=log, timeout=4)
            except RuntimeError:
                pass
            finally:
                write_json(destination / "timing.json", timing)
                if state_path.is_file() and state_path.stat().st_size <= 8 * 1024 * 1024:
                    shutil.copyfile(state_path, destination / "state.json")
                    if scenario in VISUAL_SCENARIOS:
                        evidence = json.loads((destination / "state.json").read_text(encoding="utf-8"))
                        if evidence.get("facts", {}).get("visualArtifacts"):
                            copy_visual_artifacts(evidence, state_path.parent, destination)


def analyze_recording(folder, telegram, log):
    video = folder / "recording.mp4"
    if not video.is_file() or video.stat().st_size == 0:
        raise ValueError("No finalized recording to evaluate: " + folder.name)
    raw = command(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                   "stream=codec_name,width,height:frame=pts_time,best_effort_timestamp_time", "-of", "json", video],
                  timeout=20, log=log)
    info = json.loads(raw)
    frames = info.get("frames", [])
    if len(frames) < 2 or len(info.get("streams", [])) != 1 or info["streams"][0].get("codec_name") != "h264":
        raise ValueError("Recording contains no real H.264 frame sequence")
    write_json(folder / "ffprobe.json", info)
    state = json.loads((folder / "state.json").read_text(encoding="utf-8"))
    scales = {probe["scale"] for probe in state.get("probes", [])}
    if not scales and state.get("facts", {}).get("screenScale") is not None:
        scales.add(state["facts"]["screenScale"])
    if len(scales) != 1:
        raise ValueError("Missing/inconsistent observed screen scale")
    scale = scales.pop()
    with (folder / "animation-analysis.log").open("w", encoding="utf-8") as analysis:
        command([sys.executable, telegram / "tools/animation_sheet.py", video, folder / "frames",
                 "--scale", str(scale), "--tile-width", "201", "--columns", "4", "--rows", "4"],
                timeout=90, log=analysis)
    if not list((folder / "frames").glob("sheet-*.png")) or not (folder / "frames/frames.tsv").is_file():
        raise ValueError("animation_sheet produced no labelled frame evidence")
    if state.get("scenario") in VISUAL_SCENARIOS:
        timing = json.loads((folder / "timing.json").read_text(encoding="utf-8"))
        handles = recorded_frame_index(state, timing, info)
        if any(not (folder / frame["frame"]).is_file() or not (folder / frame["sheet"]).is_file() for frame in handles["frames"]):
            raise ValueError("Indexed PTS frame/sheet handle is missing")
        write_json(folder / "frame-handles.json", handles)
    return {"scenario": folder.name, "recordingSha256": digest(video), "frameCount": len(frames),
            "timestampSource": "ffprobe", "visualReview": "pending-recorded-frame-review"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--staging-manifest", type=Path, required=True)
    parser.add_argument("--telegram-root", type=Path, default=ROOT / "telegram-ios")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scenario", choices=SCENARIOS + DOMAIN_SCENARIOS + VISUAL_SCENARIOS, action="append")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Real UIKit recording requires macOS/Xcode; no model fallback exists")
    try:
        selected = selected_scenarios(args.scenario, SCENARIOS)
    except ValueError as error:
        parser.error(str(error))
    def interrupted(signum, frame):
        raise SystemExit("driver interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be empty; stale artifacts are not acceptance evidence")
    output.mkdir(parents=True, exist_ok=True)
    report = {"status": "running", "semanticPassed": False, "visualReview": "pending-recorded-frame-review", "scenarios": [],
              "requestedScenarios": list(selected), "batch": batch_name(selected, SCENARIOS), "processLimit": 3,
              "buildSelection": BUILD_SELECTION}
    record = None
    failure = None
    try:
        report["bundle"] = verify_ipa(args.ipa, args.staging_manifest, args.telegram_root)
        if set(selected) & set(DOMAIN_SCENARIOS + VISUAL_SCENARIOS):
            with zipfile.ZipFile(args.ipa) as archive:
                sources = manifest_from_ipa(archive, APP_ROOT, selected)
            report["domainSources"] = sources
            write_json(output / "domain-source-fingerprints.json", sources)
        with (output / "driver.log").open("w", encoding="utf-8") as log:
            try:
                types = json.loads(command(["xcrun", "simctl", "list", "devicetypes", "-j"], log=log))["devicetypes"]
                runtimes = json.loads(command(["xcrun", "simctl", "list", "runtimes", "-j"], log=log))["runtimes"]
                sdk = command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], log=log).strip()
                device_type, runtime = select_device_type_and_runtime(types, runtimes, sdk)
                name = DEVICE_PREFIX + str(uuid.uuid4())
                udid = command(["xcrun", "simctl", "create", name, device_type, runtime["identifier"]], log=log).strip()
                uuid.UUID(udid)
                record = {"udid": udid, "name": name, "deviceType": device_type, "runtime": runtime["identifier"]}
                write_json(output / "owned-device.json", record)
                with tempfile.TemporaryDirectory(prefix="client-ui-app-", dir=output) as staging:
                    app = extract_app(args.ipa, Path(staging))
                    command(["xcrun", "simctl", "boot", udid], log=log)
                    command(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=90, log=log)
                    command(["xcrun", "simctl", "install", udid, app], timeout=45, log=log)
                for scenario in selected:
                    result = run_scenario(udid, scenario, output, log)
                    if scenario in DOMAIN_SCENARIOS + VISUAL_SCENARIOS:
                        state = json.loads((output / scenario / "state.json").read_text(encoding="utf-8"))
                        if state["facts"]["domainSources"] != report["domainSources"]:
                            raise ValueError("Running native app source manifest differs from the built IPA")
                    report["scenarios"].append(result)
            finally:
                if record is not None:
                    delete_owned_device(record, log)
                    report["ownedDeviceDeleted"] = True
    except BaseException as error:
        failure = error
        report["status"] = "failed"
        report["error"] = str(error)
    finally:
        # Produce failure frame sheets too, after the owned simulator is gone.
        # Existing partial reports cannot accidentally count as passed scenarios.
        report["recordings"] = []
        with (output / "frame-driver.log").open("w", encoding="utf-8") as log:
            for scenario in selected:
                folder = output / scenario
                if not (folder / "recording.mp4").is_file():
                    continue
                try:
                    report["recordings"].append(analyze_recording(folder, args.telegram_root, log))
                except Exception as error:
                    report.setdefault("frameErrors", []).append({"scenario": scenario, "error": str(error)})
                    failure = failure or error
        if failure is None and complete_batch(selected, report["scenarios"], report["recordings"]):
            report["semanticPassed"] = True
            report["status"] = "recorded-awaiting-visual-review"
        else:
            report["status"] = "failed"
            report.setdefault("error", str(failure or "incomplete recorded evidence"))
        write_json(output / "acceptance.json", report)
    if report["status"] == "failed":
        raise SystemExit("Client UIKit gate failed; inspect " + str(output) + ": " + report["error"])
    print("Semantic scenarios completed; recorded-frame visual review is REQUIRED: " + str(output))


if __name__ == "__main__":
    main()
