#!/usr/bin/env python3
"""Build and passively record the NORMAL Telegram first launch on one fresh simulator.

The full app build reuses the existing cached builder. No fixture app is launched,
no account is injected, and a successful recording is never a visual PASS.
"""

from __future__ import annotations

import argparse
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import json
import math
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

from client_ui_harness import (command, digest, load_packaging,
                               select_device_type_and_runtime, stop_process, write_json)
from client_ui_harness_build import build, pinned_xcode_app, preflight

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = "Payload/Telegram.app"
DEVICE_PREFIX = "EXL-Launch-"
CAPTURE_SECONDS = (2, 10, 20)
EXPECTED = {
    "beforeRecording": True,
    "expected": "Normal Telegram onboarding/login, or an explicit visible startup error, within 20 seconds.",
    "failure": "A black/empty app window at the settled endpoint, a crash, or a failed launch.",
    "review": "Review actual screenshots and PTS-labelled sheets; build/process survival is not visual acceptance.",
    "interactions": "None: no login, phone entry, message, URL, test account or plugin injection.",
    "network": "Normal built-in Telegram transport is permitted on the fresh simulator.",
}
PLIST_KEYS = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
              "CFBundleSupportedPlatforms", "DTPlatformName", "DTSDKName", "MinimumOSVersion",
              "UIApplicationSceneManifest", "UIMainStoryboardFile", "UILaunchStoryboardName",
              "UILaunchScreen", "LSRequiresIPhoneOS", "UIDeviceFamily")


def secrets_from_configuration(telegram):
    config = json.loads((telegram / "build-system/exteraless-configuration.json").read_text(encoding="utf-8"))
    return tuple(str(value) for value in (config.get("api_hash"), os.environ.get("TELEGRAM_APP_HASH")) if value)


def redact(text, secrets):
    for value in secrets:
        text = text.replace(value, "[REDACTED_API_HASH]")
    return text


def sanitize_diagnostics(output, secrets):
    # Explicit log/report types only; never touch the retained IPA or PNG/MP4 bytes.
    for pattern in ("*.log", "*.json"):
        for path in output.rglob(pattern):
            if path.name == "private-actions.json":
                path.unlink(missing_ok=True)
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            clean = redact(text, secrets)
            if clean != text:
                path.write_text(clean, encoding="utf-8")


def source_identity():
    sha = command(["git", "rev-parse", "HEAD"], cwd=ROOT).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected an exact Git commit")
    return {"gitSha": sha, "productionBaseSha": os.environ.get("PRODUCTION_BASE_SHA", sha),
            "driverSha256": digest(Path(__file__)), "configuration": "debug_sim_arm64"}


def check_toolchain(telegram):
    wanted = json.loads((telegram / "versions.json").read_text(encoding="utf-8"))["xcode"]
    actual = command(["xcodebuild", "-version"]).splitlines()[0].removeprefix("Xcode ")
    developer = Path(os.environ.get("DEVELOPER_DIR", ""))
    if actual != wanted or developer != pinned_xcode_app(telegram) / "Contents/Developer":
        raise ValueError("Select the exact versions.json Xcode through DEVELOPER_DIR")
    return {"xcode": actual, "developerDir": str(developer),
            "simulatorSDK": command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip()}


def main_app_info(ipa, expected_bundle):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate IPA entries")
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if (path.is_absolute() or ".." in path.parts or "\\" in item.filename
                    or stat.S_ISLNK(item.external_attr >> 16)):
                raise ValueError("Unsafe IPA entry")
        info = plistlib.loads(archive.read(APP_ROOT + "/Info.plist"))
        if (info.get("CFBundleIdentifier") != expected_bundle or info.get("CFBundleExecutable") != "Telegram"
                or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]):
            raise ValueError("Expected the unchanged normal Telegram simulator bundle, not a harness/device IPA")
        extensions = sorted(name for name in names if name.startswith(APP_ROOT + "/PlugIns/")
                            and name.count("/") == 4 and name.endswith("/Info.plist"))
        if len(extensions) != 6:
            raise ValueError("Expected all six application extensions; do not prune the deliverable")
        return {"plist": {key: info[key] for key in PLIST_KEYS if key in info},
                "infoPlistSha256": hashlib.sha256(archive.read(APP_ROOT + "/Info.plist")).hexdigest(),
                "extensions": [plistlib.loads(archive.read(name))["CFBundleIdentifier"] for name in extensions]}


def build_main(telegram, output, cache, bazel_root):
    output.mkdir(parents=True, exist_ok=True)
    secrets = secrets_from_configuration(telegram)
    report = {"status": "building", "visualReview": "not-recorded", "identity": source_identity()}
    try:
        report["toolchain"] = check_toolchain(telegram)
        checked = preflight(telegram)
        write_json(output / "preflight.json", checked)
        if checked["errors"]:
            raise ValueError("Full app preflight failed; see preflight.json")
        # Keep helper output private until redacted; its aquery is removed in its own finally.
        with (output / "wrapper.log").open("w", encoding="utf-8") as log, redirect_stdout(log), redirect_stderr(log):
            build(telegram, output, cache, bazel_root, 6600)
        fresh = telegram / "bazel-bin/Telegram/Telegram.ipa"
        retained = output / "Telegram.ipa"
        config = json.loads((telegram / "build-system/exteraless-configuration.json").read_text(encoding="utf-8"))
        report.update(main_app_info(fresh, config["bundle_id"]))
        packaging = load_packaging(telegram)
        manifest = packaging.load_staging_manifest(telegram)
        runtime = packaging.verify_runtime_ipa(fresh, manifest, target="simulator")
        write_json(output / "telegram-runtime.json", runtime)
        sha = digest(fresh)
        shutil.copyfile(fresh, retained)
        if digest(retained) != sha:
            raise ValueError("Retained main IPA differs from the immediately verified bazel-bin output")
        report.update(status="built", ipa=str(retained), ipaSha256=sha,
                      buildOutput=str(fresh), resolvedBuildOutput=str(fresh.resolve()),
                      buildOutputMtimeNs=fresh.stat().st_mtime_ns,
                      appGroup="group." + config["bundle_id"], runtimeVerified=True,
                      launched=False, extensionsPruned=False, signingModified=False)
    except BaseException as error:
        report.update(status="failed", error=redact(str(error), secrets), errorType=type(error).__name__)
        raise
    finally:
        write_json(output / "telegram-build.json", report)
        sanitize_diagnostics(output, secrets)


def extract_main(ipa, directory):
    # main_app_info validates every ZIP entry before this function is called.
    with zipfile.ZipFile(ipa) as archive:
        for item in archive.infolist():
            if not item.filename.startswith(APP_ROOT + "/"):
                continue
            archive.extract(item, directory)
            target = directory / item.filename
            if target.is_file():
                target.chmod((item.external_attr >> 16) & 0o777 or 0o644)
    app = directory / APP_ROOT
    for plist in app.rglob("Info.plist"):
        info = plistlib.loads(plist.read_bytes())
        executable = info.get("CFBundleExecutable")
        if executable:
            if PurePosixPath(executable).name != executable or "\\" in executable:
                raise ValueError("Unsafe executable name")
            binary = plist.parent / executable
            if binary.is_file():
                binary.chmod(binary.stat().st_mode | 0o111)
    return app


def owned_device(record, devices):
    try:
        uuid.UUID(record["udid"])
        uuid.UUID(record["name"].removeprefix(DEVICE_PREFIX))
    except (ValueError, KeyError, TypeError):
        return False
    return record["name"].startswith(DEVICE_PREFIX) and any(
        item.get("udid") == record["udid"] and item.get("name") == record["name"]
        and item.get("deviceTypeIdentifier") == record["deviceType"]
        for item in devices.get(record["runtime"], []))


def device_state(record):
    devices = json.loads(command(["xcrun", "simctl", "list", "devices", "-j"]))["devices"]
    if not owned_device(record, devices):
        raise ValueError("Refusing a simulator whose exact created UUID/name/type/runtime ownership changed")
    return next(item for item in devices[record["runtime"]] if item["udid"] == record["udid"])


def receipt(argv, output, name, timeout=15, check=True):
    """Preserve both simctl streams even when launch/installation fails."""
    args = [str(value) for value in argv]
    started = time.monotonic()
    with (output / (name + "-stdout.log")).open("w", encoding="utf-8") as stdout, \
            (output / (name + "-stderr.log")).open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen(args, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except BaseException:
            stop_process(process)
            raise
        finally:
            write_json(output / (name + "-command.json"), {"argv": args, "returncode": process.poll(),
                       "elapsedSeconds": time.monotonic() - started})
    if check and process.returncode:
        raise RuntimeError(name + " failed; see its stdout/stderr and command receipt")
    return process.returncode


def parse_launch_pid(text, bundle):
    match = re.search(r"^" + re.escape(bundle) + r":\s*(\d+)\s*$", text, re.M)
    if not match or int(match[1]) <= 0:
        raise ValueError("simctl launch did not return this bundle's PID")
    return int(match[1])


def process_state(record, bundle, pid, output, label):
    state = {"device": device_state(record), "pid": pid}
    receipt(["xcrun", "simctl", "spawn", record["udid"], "launchctl", "list"], output,
            label + "-process-list", timeout=5, check=False)
    path = output / (label + "-process-list-stdout.log")
    lines = [line for line in path.read_text(encoding="utf-8").splitlines()
             if ("UIKitApplication:" + bundle + "[") in line]
    # Retain only the application's launchctl rows, never other process inventory.
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    state["bundleRows"] = lines
    state["alive"] = any(line.split()[0] == str(pid) for line in lines if line.split())
    write_json(output / (label + "-process.json"), state)
    return state


def crash_paths(record, bundle, pid, since):
    """Read bounded new Telegram crash metadata; publish matching paths only."""
    folders = [Path.home() / "Library/Logs/DiagnosticReports",
               Path.home() / "Library/Developer/CoreSimulator/Devices" / record["udid"] / "data/Library/Logs/CrashReporter"]
    found = []
    for folder in folders:
        if not folder.is_dir():
            continue
        for path in folder.glob("Telegram*.*"):
            if path.is_symlink() or not path.is_file() or path.stat().st_mtime < since:
                continue
            with path.open("rb") as stream:
                text = stream.read(2 * 1024 * 1024).decode("utf-8", errors="replace")
            bundle_match = re.search(r'"(?:bundleID|CFBundleIdentifier)"\s*:\s*"' + re.escape(bundle) + r'"', text)
            bundle_match = bundle_match or re.search(r"^Identifier:\s*" + re.escape(bundle) + r"\s*$", text, re.M)
            pid_match = pid is not None and (re.search(r'"pid"\s*:\s*' + str(pid) + r'\b', text)
                                           or re.search(r"^Process:\s*Telegram\s+\[" + str(pid) + r"\]", text, re.M))
            device_match = record["udid"].lower() in text.lower()
            if bundle_match and (pid_match or (pid is None and device_match)):
                found.append({"path": str(path), "pid": pid, "bundle": bundle,
                              "modifiedUnix": path.stat().st_mtime, "bytes": path.stat().st_size})
    return found


def blank_metrics(path):
    from PIL import Image, ImageStat
    with Image.open(path) as image:
        # Exclude the status/home bars: their pixels must not make an empty window pass.
        gray = image.convert("L").crop((0, int(image.height * .10), image.width, int(image.height * .92)))
        stats = ImageStat.Stat(gray)
        histogram = gray.histogram()
        dark = sum(histogram[:13]) / sum(histogram)
        return {"centralLumaMean": stats.mean[0], "centralLumaStddev": stats.stddev[0],
                "centralDarkFraction": dark, "blackEmpty": dark > .995,
                "uniformEmpty": stats.stddev[0] < .5, "semanticAcceptance": False}


def analyze_video(output, telegram):
    video = output / "first-launch.mp4"
    raw = command(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                   "format=duration,size:stream=codec_name,width,height:frame=pts_time,best_effort_timestamp_time",
                   "-of", "json", video], timeout=20)
    info = json.loads(raw)
    write_json(output / "ffprobe.json", info)
    frames = info.get("frames", [])
    if not frames or len(info.get("streams", [])) != 1 or info["streams"][0].get("codec_name") != "h264":
        raise ValueError("No actual H.264 frame sequence")
    pts = [float(frame.get("pts_time", frame.get("best_effort_timestamp_time", "nan"))) for frame in frames]
    if not all(math.isfinite(value) for value in pts):
        raise ValueError("Recording is missing real frame PTS")
    with (output / "frame-analysis.log").open("w", encoding="utf-8") as log:
        command([sys.executable, telegram / "tools/animation_sheet.py", video, output / "frames",
                 "--scale", "3", "--tile-width", "240", "--columns", "4", "--rows", "4"],
                stdout=log, timeout=90)
    sheets = sorted((output / "frames").glob("sheet-*.png"))
    if not sheets or not (output / "frames/frames.tsv").is_file():
        raise ValueError("Missing PTS-labelled frame sheets")
    return {"sha256": digest(video), "frameCount": len(frames), "firstPTS": pts[0], "lastPTS": pts[-1],
            "timestampSource": "ffprobe frame PTS (not frame index/fps)",
            "sheets": [str(path.relative_to(output)) for path in sheets],
            "visualReview": "pending-recorded-frame-review"}


def launch_main(telegram, output, build_report):
    if output.exists() and any(output.iterdir()):
        raise ValueError("Launch output must be empty; stale frames are forbidden")
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "expected-before.json", EXPECTED)
    built = json.loads(build_report.read_text(encoding="utf-8"))
    bundle = built["plist"]["CFBundleIdentifier"]
    ipa = Path(built["ipa"])
    report = {"status": "running", "visualReview": "pending-recorded-frame-review", "visualPassed": False,
              "identity": source_identity(), "ipaSha256": digest(ipa), "bundle": bundle, "screenshots": [],
              "launchArguments": [], "physicalDeviceVerified": False}
    record = recorder = recorder_log = None
    pid = None
    failure = None
    launch_wall = time.time()
    try:
        if (built["status"] != "built" or report["ipaSha256"] != built["ipaSha256"]
                or report["identity"] != built["identity"]):
            raise ValueError("Main app build/source/IPA identity mismatch")
        report.update(main_app_info(ipa, bundle))
        report["toolchain"] = check_toolchain(telegram)
        types = json.loads(command(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]
        runtimes = json.loads(command(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
        runtime27 = [item for item in runtimes if str(item.get("version", "")).split(".")[0] == "27"]
        device_type, runtime = select_device_type_and_runtime(types, runtime27, report["toolchain"]["simulatorSDK"])
        name = DEVICE_PREFIX + str(uuid.uuid4())
        udid = command(["xcrun", "simctl", "create", name, device_type, runtime["identifier"]]).strip()
        uuid.UUID(udid)
        record = {"udid": udid, "name": name, "deviceType": device_type, "runtime": runtime["identifier"]}
        report["runtime"] = runtime
        write_json(output / "owned-device.json", record)
        device_state(record)
        receipt(["xcrun", "simctl", "boot", udid], output, "boot")
        receipt(["xcrun", "simctl", "bootstatus", udid, "-b"], output, "bootstatus", timeout=90)
        with tempfile.TemporaryDirectory(prefix="telegram-launch-app-", dir=output) as staging:
            app = extract_main(ipa, Path(staging))
            receipt(["xcrun", "simctl", "install", udid, app], output, "install", timeout=45)
        # Start passive recording before launch, so even the first transition is captured.
        recorder_log = (output / "record.log").open("w", encoding="utf-8")
        report["recordCommandUnix"] = time.time()
        recorder = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force",
                                     str(output / "first-launch.mp4")], stdout=recorder_log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        deadline = time.monotonic() + 4
        while "Recording started" not in (output / "record.log").read_text(encoding="utf-8"):
            if recorder.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("simctl recordVideo did not start within four seconds")
            time.sleep(.05)
        report["recordStartedObservedUnix"] = time.time()
        start, launch_wall = time.monotonic(), time.time()
        report["launchCommandUnix"] = launch_wall
        receipt(["xcrun", "simctl", "launch", "--stdout=" + str(output / "app-stdout.log"),
                 "--stderr=" + str(output / "app-stderr.log"), udid, bundle], output, "launch", timeout=8)
        pid = parse_launch_pid((output / "launch-stdout.log").read_text(encoding="utf-8"), bundle)
        report["pid"] = pid
        report["launchReturnedSeconds"] = time.monotonic() - start
        for target in CAPTURE_SECONDS:
            time.sleep(max(0, start + target - time.monotonic()))
            began = time.monotonic() - start
            path = output / ("screen-%02ds.png" % target)
            receipt(["xcrun", "simctl", "io", udid, "screenshot", path], output, "screen-%02ds" % target, timeout=4)
            shot = {"targetSeconds": target, "captureStartedSeconds": began,
                    "captureFinishedSeconds": time.monotonic() - start, "path": path.name, "sha256": digest(path)}
            report["screenshots"].append(shot)
            state = process_state(record, bundle, pid, output, "at-%02ds" % target)
            shot["processAlive"] = state["alive"]
            if not state["alive"]:
                raise RuntimeError("Original Telegram PID is no longer alive; screenshot is diagnostic only")
        report["observedSeconds"] = time.monotonic() - start
    except BaseException as error:
        failure = error
        report.update(status="failed", error=str(error), errorType=type(error).__name__)
    finally:
        # End app observation before slower video finalization/log collection.
        if record is not None and pid is not None:
            try:
                device_state(record)
                receipt(["xcrun", "simctl", "terminate", record["udid"], bundle], output, "terminate", timeout=4, check=False)
                report["terminateCommandFinishedUnix"] = time.time()
            except Exception as error:
                report["terminateError"] = str(error)
                failure = failure or error
        if recorder is not None:
            try:
                stop_process(recorder, interrupt=True)
                report["recorderReturncode"] = recorder.returncode
                report["recordStoppedUnix"] = time.time()
            except Exception as error:
                report["recordStopError"] = str(error)
                failure = failure or error
        if recorder_log is not None:
            recorder_log.close()
        if record is not None:
            try:
                write_json(output / "crash-paths.json", {"matchingReports": crash_paths(record, bundle, pid, launch_wall),
                           "contentsCopied": False, "scope": "new own bundle plus PID/created-device match"})
                write_json(output / "device-final.json", device_state(record))
                if pid is not None:
                    receipt(["xcrun", "simctl", "spawn", record["udid"], "log", "show", "--style", "compact",
                             "--last", "2m", "--predicate", "processIdentifier == " + str(pid)],
                            output, "app-unified", timeout=8, check=False)
            except Exception as error:
                report["diagnosticError"] = str(error)
            finally:
                try:
                    device_state(record)  # Exact ownership check immediately before cleanup.
                    receipt(["xcrun", "simctl", "shutdown", record["udid"]], output, "shutdown", timeout=15, check=False)
                    receipt(["xcrun", "simctl", "delete", record["udid"]], output, "delete", timeout=15)
                    report["ownedDeviceDeleted"] = True
                except Exception as error:
                    report["cleanupError"] = str(error)
                    failure = failure or error
        write_json(output / "launch-result.json", report)
        # Analyze any genuine partial recording, including one from a failed launch.
        # No substitute PNG is generated when simctl did not produce a screenshot.
        if (output / "first-launch.mp4").is_file():
            try:
                report["video"] = analyze_video(output, telegram)
            except Exception as error:
                report["frameError"] = str(error)
                failure = failure or error
        else:
            failure = failure or ValueError("No recording exists")
        for shot in report["screenshots"]:
            try:
                shot["metrics"] = blank_metrics(output / shot["path"])
            except Exception as error:
                report["metricsError"] = str(error)
                failure = failure or error
        if report["screenshots"] and report["screenshots"][-1].get("targetSeconds") == 20:
            metrics = report["screenshots"][-1].get("metrics", {})
            if metrics.get("blackEmpty") or metrics.get("uniformEmpty"):
                failure = failure or ValueError("Black/empty app-content region at the 20-second endpoint")
        if len(report["screenshots"]) != len(CAPTURE_SECONDS):
            failure = failure or ValueError("Incomplete 2/10/20-second evidence")
        report["status"] = "failed" if failure else "recorded-awaiting-visual-review"
        if failure:
            report.setdefault("error", str(failure))
        write_json(output / "launch-result.json", report)
        sanitize_diagnostics(output, secrets_from_configuration(telegram))
    if failure:
        raise RuntimeError("Normal Telegram smoke failed; inspect launch-result.json and preserved diagnostics")
    print("Normal Telegram recorded; actual frame review is pending: " + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("build", "launch"), required=True)
    parser.add_argument("--telegram-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--bazel-root", type=Path)
    parser.add_argument("--build-report", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Normal Telegram launch requires macOS/Xcode; no model fallback")
    def interrupted(signum, frame):
        raise SystemExit("normal launch smoke interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    telegram, output = args.telegram_root.resolve(), args.output.resolve()
    try:
        if args.phase == "build":
            if args.cache is None or args.bazel_root is None:
                parser.error("build requires --cache and --bazel-root")
            build_main(telegram, output, args.cache.resolve(), args.bazel_root.resolve())
        else:
            if args.build_report is None:
                parser.error("launch requires --build-report")
            launch_main(telegram, output, args.build_report.resolve())
    except Exception as error:
        raise SystemExit(redact(str(error), secrets_from_configuration(telegram))) from None


if __name__ == "__main__":
    main()
