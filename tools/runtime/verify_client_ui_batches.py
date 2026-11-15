"""Join the three explicit serial UIKit batches against their single compiled IPA."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import uuid

from client_ui_harness_domains import check_manifest
from client_ui_harness_visuals import BUILD_SELECTION, VISUAL_SCENARIOS, check_visual_sources
from native_test_plan import digest, verify_native_results

BASELINE = ("core-light", "core-dark", "sdk-ui")
DOMAINS = ("feed-render", "player-render", "pill-render")
FINAL_VISUALS = VISUAL_SCENARIOS
BATCHES = (("baseline", "baseline-3", BASELINE), ("domains", "domains-3", DOMAINS),
           ("final-visuals", "final-visuals-2", FINAL_VISUALS))


def verify_batch(report, expected, packaging, batch_name):
    if (report.get("status") != "recorded-awaiting-visual-review" or report.get("semanticPassed") is not True
            or report.get("ownedDeviceDeleted") is not True
            or report.get("visualReview") != "pending-recorded-frame-review"):
        raise ValueError("Incomplete UIKit batch or unsupported visual-pass claim")
    if (report.get("requestedScenarios") != list(expected) or report.get("batch") != batch_name
            or type(report.get("processLimit")) is not int or report["processLimit"] != 3
            or report.get("buildSelection") != BUILD_SELECTION):
        raise ValueError("UIKit batch selection/process limit/build host differs from the frozen contract")
    scenarios = report.get("scenarios", [])
    recordings = report.get("recordings", [])
    if tuple(item.get("scenario") for item in scenarios) != expected or tuple(item.get("scenario") for item in recordings) != expected:
        raise ValueError("A declared scenario or recording was omitted, duplicated or reordered")
    for item in scenarios:
        seconds = item.get("processSeconds")
        if (item.get("semanticPassed") is not True or type(seconds) not in (int, float)
                or not math.isfinite(seconds) or not 0 < seconds <= 30):
            raise ValueError("UIKit app process exceeded its fixed 30-second cap or did not pass")
    if any(type(item.get("frameCount")) is not int or item["frameCount"] <= 0 for item in recordings):
        raise ValueError("UIKit recording contains no observed frames")
    bundle = report.get("bundle", {})
    if (bundle.get("ipaSha256") != packaging.get("ipaSha256")
            or bundle.get("clientSourcePatches") != packaging.get("clientSourcePatches")):
        raise ValueError("UIKit batches do not belong to the single compiled IPA/source fingerprint")


def verify(build, native_tests, baseline, domains, final_visuals, batch_identities=None, *, native_results_sha256=None):
    if build.get("status") != "built" or build.get("configuration") != "debug_sim_arm64":
        raise ValueError("A completed debug simulator build is required")
    if build.get("buildSelection") != BUILD_SELECTION:
        raise ValueError("The compiled app does not have the frozen visual build-selection identity")
    packaging = build["packaging"]
    identity = build.get("acceptanceIdentity", {})
    if (set(identity) != {"nativePlanSha256", "harnessInputsSha256", "stagingSourceSha256", "ipaSha256"}
            or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in identity.values())
            or identity["ipaSha256"] != packaging.get("ipaSha256")
            or identity["nativePlanSha256"] != build.get("nativeTestPlan", {}).get("source_fingerprint")):
        raise ValueError("Incomplete compiled acceptance source/staging identity")
    native = verify_native_results(native_tests, build["nativeTestPlan"], identity)
    if (not isinstance(packaging.get("ipaSha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", packaging["ipaSha256"])
            or not isinstance(packaging.get("clientSourcePatches"), dict)
            or not re.fullmatch(r"[0-9a-f]{64}", packaging["clientSourcePatches"].get("source_fingerprint", ""))):
        raise ValueError("Missing compiled IPA/client source fingerprint")
    for report, (_, name, expected) in zip((baseline, domains, final_visuals), BATCHES):
        verify_batch(report, expected, packaging, name)
    sources = check_manifest(build.get("domainSources", {}))
    check_visual_sources(sources, FINAL_VISUALS)
    for report in (domains, final_visuals):
        if check_manifest(report.get("domainSources", {})) != sources:
            raise ValueError("Recording source manifest differs from the built IPA")
    if batch_identities is None or len(batch_identities) != len(BATCHES):
        raise ValueError("Every recording batch requires its compiled source/staging identity receipt")
    native_sha = native_results_sha256 or hashlib.sha256(
        (json.dumps(native_tests, indent=2, sort_keys=True) + "\n").encode()).hexdigest()
    for receipt, (_, name, expected) in zip(batch_identities, BATCHES):
        if (receipt.get("schema") != 1 or receipt.get("acceptanceIdentity") != identity
                or receipt.get("nativeResultsSha256") != native_sha or receipt.get("nativeEvidence") != native
                or receipt.get("batch") != name or receipt.get("requestedScenarios") != list(expected)
                or receipt.get("driverSha256") != build.get("driverSha256")
                or not re.fullmatch(r"[0-9a-f]{64}", receipt.get("driverSha256", ""))
                or check_manifest(receipt.get("domainSources", {})) != sources):
            raise ValueError("Recording batch source/staging/native evidence identity differs")
    return {"status": "recorded-awaiting-visual-review", "semanticPassed": True,
            "visualReview": "pending-recorded-frame-review", "ipaSha256": packaging["ipaSha256"],
            "domainSourceSha256": sources["sha256"], "clientSourcePatches": packaging["clientSourcePatches"],
            "buildSelection": BUILD_SELECTION,
            "acceptanceIdentity": identity, "nativeEvidence": native, "nativeResultsSha256": native_sha,
            "batches": [{"directory": directory, "scenarios": list(expected)} for directory, _, expected in BATCHES],
             "processDeadlineSeconds": 30, "maximumSimultaneousSimulators": 1}


def verify_devices(devices):
    if len(devices) != 3:
        raise ValueError("Three serial batch device receipts are required")
    identifiers = [str(uuid.UUID(device["udid"])) for device in devices]
    if len(set(identifiers)) != 3:
        raise ValueError("Each serial driver batch must create its own fresh simulator")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-report", type=Path, required=True)
    parser.add_argument("--native-tests", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--domains", type=Path, required=True)
    parser.add_argument("--final-visuals", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    read = lambda path: json.loads(path.read_text(encoding="utf-8"))
    result = verify(read(args.build_report), read(args.native_tests),
                      read(args.baseline / "acceptance.json"), read(args.domains / "acceptance.json"),
                     read(args.final_visuals / "acceptance.json"),
                     [read(path / "batch-identity.json") for path in (args.baseline, args.domains, args.final_visuals)],
                     native_results_sha256=digest(args.native_tests))
    devices = [read(path / "owned-device.json") for path in (args.baseline, args.domains, args.final_visuals)]
    verify_devices(devices)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("\nNativeIntegrationTests passed; baseline (3), domains (3), and Avatar/Composer (2) "
                          "recorded serially from one IPA. "
                          "Evidence: `evidence/baseline/`, `evidence/domains/`, `evidence/final-visuals/`, `evidence/batches.json`. "
                         "Each process kept the 30s cap. Recorded-frame visual review remains pending.\n")


if __name__ == "__main__":
    main()
