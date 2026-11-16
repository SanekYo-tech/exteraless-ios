"""Branch-only sealed Mode ABA execution observer; never rewrites fixture inputs."""

import collections
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SEAL = "docs/wave-2/native-elyx-mode-aba-inputs.json"
CI_PINS = "docs/wave-2/elyx-mode-aba-ci-pins.json"
DRIVER = "tools/compat/tests/test_native_elyx_mode_aba.py"
HELPER = "tools/compat/tests/test_sdk_developer_native.py"
TEST_SOURCE = "tools/compat/tests/fixtures/native_elyx_mode/ModeABATests.swift"
CLASS = "NativeElyxModeABATests"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class FilePins:
    """A read-only, allowlisted guard; mismatches always identify their path."""

    def __init__(self):
        self.ci = json.loads((ROOT / CI_PINS).read_bytes())
        self.pins = self.ci["source_sha256"]
        self.seal = json.loads(self.read(SEAL))

    def read(self, name):
        expected = self.pins[name]
        data = (ROOT / name).read_bytes()
        if sha(data) != expected:
            raise RuntimeError("sealed source drift: " + name)
        return data

    def verify(self):
        actual = {name: sha(self.read(name)) for name in sorted(self.pins)}
        sources = {p.relative_to(ROOT).as_posix() for p in (ROOT / "swift/PluginHost/Sources").rglob("*") if p.is_file()}
        expected = {name for name in self.seal["fixture_input_sha256"] if name.startswith("swift/PluginHost/Sources/")}
        if sources != expected:
            raise RuntimeError("Host source inventory drift: " + ", ".join(sorted(sources ^ expected)))
        return actual


def cli_prepare(directory):
    original = sys.argv
    sys.argv = [str(ROOT / DRIVER), "--prepare", str(directory)]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT / DRIVER), run_name="__main__")
    finally:
        sys.argv = original
    return json.loads((directory / "inputs.json").read_bytes())


def check_receipt(receipt, guard):
    for key, expected_key in (("source_sha256", "fixture_input_sha256"), ("exact_span_sha256", "exact_production_span_sha256")):
        expected = guard.seal[expected_key]
        actual = receipt[key]
        bad = [name for name in sorted(set(expected) | set(actual)) if expected.get(name) != actual.get(name)]
        if bad:
            raise RuntimeError("fixture " + key + " drift: " + ", ".join(bad))
    assert len(receipt["source_sha256"]) == 64 and len(receipt["exact_span_sha256"]) == 13


def verify(evidence, phase):
    guard = FilePins()
    actual = guard.verify()
    directory = Path(os.environ["RUNNER_TEMP"]) / ("elyx-mode-aba-" + os.environ["GITHUB_RUN_ID"] + "-" + phase)
    receipt = cli_prepare(directory)
    check_receipt(receipt, guard)
    copied = {}
    prefix = "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/"
    for name, expected in receipt["source_sha256"].items():
        if name.startswith(prefix):
            target = directory / "Sources/NativeElyxModeRoot" / Path(name).name
            assert sha(target.read_bytes()) == expected, name
            copied[name] = expected
    assert len(copied) == 8
    assert guard.verify() == actual
    write_json(evidence / ("source-span-" + phase + ".json"), {
        "verified": True, "cohort_sha": os.environ["GITHUB_SHA"], "source_sha256": actual,
        "fixture_source_sha256": receipt["source_sha256"], "exact_span_sha256": receipt["exact_span_sha256"],
        "byte_identical_ui_copies": copied,
    })
    if not (evidence / "inputs.json").exists():
        shutil.copyfile(directory / "inputs.json", evidence / "inputs.json")
    shutil.copyfile(ROOT / SEAL, evidence / Path(SEAL).name)
    shutil.copyfile(ROOT / CI_PINS, evidence / Path(CI_PINS).name)
    print(f"{phase}: {len(actual)} scoped file pins, 64 fixture inputs, 13 exact spans, 8 exact UI/store copies verified", flush=True)


def run(evidence):
    assert sys.platform == "linux", "This manual gate must execute on Linux"
    guard = FilePins()
    guard.verify()
    directory = Path(os.environ["RUNNER_TEMP"]) / ("elyx-mode-aba-" + os.environ["GITHUB_RUN_ID"] + "-native")
    assert not directory.exists(), "native output must be fresh"
    calls = []
    active = {}
    helper_path = str(ROOT / HELPER)
    communicate_code = subprocess.Popen.communicate.__code__
    for phase in ("build", "test"):
        (evidence / (phase + ".stdout.log")).touch()

    def save_output(record, output):
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        if isinstance(output, str):
            (evidence / (record["phase"] + ".stdout.log")).write_text(output, encoding="utf-8")

    def profile(frame, event, arg):
        is_helper = frame.f_code.co_filename == helper_path and frame.f_code.co_name == "run_bounded"
        if is_helper and event == "call":
            command = frame.f_locals["command"]
            record = {"phase": command[1], "command": command, "timeout_seconds": frame.f_locals["timeout"],
                      "started": True, "completed": False, "returncode": None}
            calls.append(record)
            active[id(frame)] = (record, time.monotonic())
            write_json(evidence / "commands.json", calls)
        elif frame.f_code is communicate_code and event == "return" and id(frame.f_back) in active:
            record = active[id(frame.f_back)][0]
            if isinstance(arg, tuple):
                save_output(record, arg[0])
            else:
                # Also retain bytes gathered before TimeoutExpired. The supplied
                # helper then kills its process group and drains communicate().
                process = frame.f_locals["self"]
                chunks = getattr(process, "_fileobj2output", {}).get(process.stdout, [])
                if chunks:
                    save_output(record, b"".join(chunks))
        elif is_helper and event == "return":
            record, started = active.pop(id(frame))
            process = frame.f_locals.get("process")
            record.update(seconds=round(time.monotonic() - started, 3),
                          returncode=process.returncode if process is not None else None,
                          completed=isinstance(arg, str))
            save_output(record, arg if isinstance(arg, str) else frame.f_locals.get("output"))
            write_json(evidence / "commands.json", calls)

    original = sys.argv
    sys.argv = [str(ROOT / DRIVER), str(directory)]
    sys.setprofile(profile)
    try:
        runpy.run_path(str(ROOT / DRIVER), run_name="__main__")
    except BaseException:
        (evidence / "driver-error.log").write_text(traceback.format_exc(), encoding="utf-8")
        raise
    finally:
        sys.setprofile(None)
        sys.argv = original
        write_json(evidence / "commands.json", calls)
        for name in ("inputs.json", "native-results.json", "Package.swift"):
            if (directory / name).exists():
                shutil.copyfile(directory / name, evidence / name)
        for name in ("Sources", "Tests"):
            if (directory / name).exists():
                shutil.copytree(directory / name, evidence / "generated" / name)
        guard.verify()
        if (evidence / "inputs.json").exists():
            check_receipt(json.loads((evidence / "inputs.json").read_bytes()), guard)
    assert [(c["phase"], c["timeout_seconds"], c["returncode"], c["completed"]) for c in calls] == [
        ("build", 120, 0, True), ("test", 30, 0, True)]


def report(evidence):
    guard = FilePins()
    names = re.findall(r"\bfunc (test\w+)\(", guard.read(TEST_SOURCE).decode("utf-8"))
    assert len(names) == 4 and len(set(names)) == 4
    expected = {CLASS + "." + name for name in names}
    log = evidence / "test.stdout.log"
    for phase in ("build", "test"):
        (evidence / (phase + ".stdout.log")).touch(exist_ok=True)
    raw = log.read_bytes()
    text = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode("utf-8", "replace"))
    normalize = lambda name: ".".join(name.rsplit(".", 2)[-2:])
    starts = [normalize(n) for n in re.findall(r"^Test Case '([A-Za-z0-9_.]+\.test[A-Za-z0-9_]+)' started at .+$", text, re.M)]
    finished = [(normalize(n), status, seconds) for n, status, seconds in re.findall(
        r"^Test Case '([A-Za-z0-9_.]+\.test[A-Za-z0-9_]+)' (passed|failed|skipped) \(([0-9.]+) seconds\)$", text, re.M)]
    summary = re.search(r"^Test Suite 'Selected tests' (passed|failed) at [^\n]+\n\s*Executed (\d+) tests, with (\d+) failures \((\d+) unexpected\) in ([0-9.]+) \([0-9.]+\) seconds", text, re.M)
    calls = json.loads((evidence / "commands.json").read_bytes()) if (evidence / "commands.json").exists() else []
    issues = []
    inventory = collections.Counter({name: 1 for name in expected})
    if collections.Counter(starts) != inventory:
        issues.append("Native starts differ from the four source test names")
    if collections.Counter(n for n, _, _ in finished) != inventory:
        issues.append("Native finishes differ from the four source test names")
    if summary is None or summary[1] != "passed" or int(summary[2]) != 4 or int(summary[3]) != 0 or int(summary[4]) != 0:
        issues.append("Missing or nonpassing complete four-case native summary")
    if any(status != "passed" for _, status, _ in finished):
        issues.append("Native failures/skips present")
    if [(c["phase"], c["timeout_seconds"], c["returncode"], c["completed"]) for c in calls] != [("build", 120, 0, True), ("test", 30, 0, True)]:
        issues.append("Sealed compile/test commands did not both complete successfully")
    for phase in ("before", "after"):
        check = evidence / ("source-span-" + phase + ".json")
        if not check.exists() or not json.loads(check.read_bytes())["verified"]:
            issues.append("Missing " + phase + " source/span verification")
    result_path = evidence / "native-results.json"
    supplied_result = result_path.exists()
    if supplied_result:
        result = json.loads(result_path.read_bytes())
        if not result.get("native_execution") or set(result.get("passed_test_cases", [])) != set(names):
            issues.append("Supplied driver result does not confirm all four cases")
        check_receipt(result, guard)
    else:
        issues.append("Supplied driver did not write native-results.json")
        write_json(result_path, {"origin": "CI failure recorder; supplied driver wrote no result",
            "native_execution": any(c["phase"] == "test" for c in calls), "driver_completed": False,
            "passed_test_cases": [n.split(".")[-1] for n, status, _ in finished if status == "passed"],
            "compile_timeout_seconds": 120, "test_timeout_seconds": 30, "commands": calls,
            "boundary": guard.seal["fixture"]["boundary"]})
    cases = [{"class": n.rsplit(".", 1)[0], "name": n.rsplit(".", 1)[1], "status": status, "seconds": seconds} for n, status, seconds in finished]
    diagnostics = []
    for phase in ("build", "test"):
        for line in (evidence / (phase + ".stdout.log")).read_text(encoding="utf-8", errors="replace").splitlines():
            if "error:" in line or re.search(r"\.swift:\d+", line):
                diagnostics.append(line)
    counts = {"expected": 4, "tests": len(finished), "started": len(starts),
              "passed": sum(status == "passed" for _, status, _ in finished),
              "failures": sum(status == "failed" for _, status, _ in finished),
              "skipped": sum(status == "skipped" for _, status, _ in finished),
              "errors": 0 if not issues else 1, "seconds": summary[5] if summary else None,
              "cohort_sha": os.environ["GITHUB_SHA"], "log_sha256": sha(raw), "cases": cases,
              "expected_case_ids": sorted(expected), "report_errors": issues, "commands": calls,
              "native_diagnostic_lines": diagnostics, "supplied_driver_result": supplied_result,
              "provenance": "Actual native XCTest start/finish events and complete Selected tests summary"}
    document = ET.Element("testsuites")
    suite = ET.SubElement(document, "testsuite", name=CLASS, tests=str(len(cases)), failures=str(counts["failures"]),
                          skipped=str(counts["skipped"]), errors="0", time=counts["seconds"] or "0")
    properties = ET.SubElement(suite, "properties")
    for name, value in (("source", "test.stdout.log native XCTest events"), ("source_sha256", counts["log_sha256"]), ("cohort_sha", counts["cohort_sha"])):
        ET.SubElement(properties, "property", name=name, value=value)
    for case in cases:
        item = ET.SubElement(suite, "testcase", classname=case["class"], name=case["name"], time=case["seconds"])
        if case["status"] == "failed":
            ET.SubElement(item, "failure", message="Actual native XCTest failure").text = "\n".join(diagnostics)
        elif case["status"] == "skipped":
            ET.SubElement(item, "skipped")
    if issues:
        ET.SubElement(suite, "system-err").text = "\n".join(issues)
    ET.ElementTree(document).write(evidence / "native-xctest.xml", encoding="utf-8", xml_declaration=True)
    write_json(evidence / "counts.json", counts)
    checksums = {p.relative_to(evidence).as_posix(): sha(p.read_bytes()) for p in evidence.rglob("*") if p.is_file() and p.name != "artifact-sha256.json"}
    write_json(evidence / "artifact-sha256.json", checksums)
    print(json.dumps({key: value for key, value in counts.items() if key not in ("cases", "native_diagnostic_lines")}, indent=2), flush=True)
    if issues:
        raise SystemExit("Incomplete/failed native execution; retained logs identify actual outcomes")


if __name__ == "__main__":
    evidence = Path(os.environ["EVIDENCE"])
    evidence.mkdir(parents=True, exist_ok=True)
    if sys.argv[1] == "verify":
        verify(evidence, sys.argv[2])
    elif sys.argv[1] == "run":
        run(evidence)
    elif sys.argv[1] == "report":
        report(evidence)
    else:
        raise SystemExit("expected verify, run or report")
