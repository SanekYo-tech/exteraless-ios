"""Join the two serial, bounded UIKit batches against their single compiled IPA."""

import argparse
import json
import math
from pathlib import Path
import re

from client_ui_harness_domains import check_manifest

BASELINE = ("core-light", "core-dark", "sdk-ui")
DOMAINS = ("feed-render", "player-render", "pill-render")


def verify_batch(report, expected, packaging):
    if (report.get("status") != "recorded-awaiting-visual-review" or report.get("semanticPassed") is not True
            or report.get("ownedDeviceDeleted") is not True
            or report.get("visualReview") != "pending-recorded-frame-review"):
        raise ValueError("Incomplete UIKit batch or unsupported visual-pass claim")
    scenarios = report.get("scenarios", [])
    recordings = report.get("recordings", [])
    if tuple(item.get("scenario") for item in scenarios) != expected or tuple(item.get("scenario") for item in recordings) != expected:
        raise ValueError("A baseline/domain scenario or recording was omitted, duplicated or reordered")
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


def verify(build, native_tests, baseline, domains):
    if build.get("status") != "built" or build.get("configuration") != "debug_sim_arm64":
        raise ValueError("A completed debug simulator build is required")
    if native_tests.get("status") != "passed" or native_tests.get("native_execution_verified") is not True:
        raise ValueError("Required NativeIntegrationTests did not pass")
    packaging = build["packaging"]
    if (not isinstance(packaging.get("ipaSha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", packaging["ipaSha256"])
            or not isinstance(packaging.get("clientSourcePatches"), dict)
            or not re.fullmatch(r"[0-9a-f]{64}", packaging["clientSourcePatches"].get("source_fingerprint", ""))):
        raise ValueError("Missing compiled IPA/client source fingerprint")
    verify_batch(baseline, BASELINE, packaging)
    verify_batch(domains, DOMAINS, packaging)
    sources = check_manifest(build.get("domainSources", {}))
    if check_manifest(domains.get("domainSources", {})) != sources:
        raise ValueError("Domain recording source manifest differs from the built IPA")
    return {"status": "recorded-awaiting-visual-review", "semanticPassed": True,
            "visualReview": "pending-recorded-frame-review", "ipaSha256": packaging["ipaSha256"],
            "domainSourceSha256": sources["sha256"], "clientSourcePatches": packaging["clientSourcePatches"],
            "batches": [{"directory": "baseline", "scenarios": list(BASELINE)},
                        {"directory": "domains", "scenarios": list(DOMAINS)}],
            "processDeadlineSeconds": 30, "maximumSimultaneousSimulators": 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-report", type=Path, required=True)
    parser.add_argument("--native-tests", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--domains", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    read = lambda path: json.loads(path.read_text(encoding="utf-8"))
    result = verify(read(args.build_report), read(args.native_tests),
                    read(args.baseline / "acceptance.json"), read(args.domains / "acceptance.json"))
    devices = [read(path / "owned-device.json") for path in (args.baseline, args.domains)]
    if devices[0]["udid"] == devices[1]["udid"]:
        raise ValueError("Each serial driver batch must create its own fresh simulator")
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("\nNativeIntegrationTests passed; baseline core-light/core-dark/sdk-ui and domain "
                         "feed-render/player-render/pill-render recorded serially from one IPA. "
                         "Evidence: `evidence/baseline/`, `evidence/domains/`, `evidence/batches.json`. "
                         "Each process kept the 30s cap. Recorded-frame visual review remains pending.\n")


if __name__ == "__main__":
    main()
