"""Fifth-child staging and receipt validation for the coordinator-owned driver.

No native execution is emulated here. The caller compiles the real Swift/C engine
and launches --elyx-developer as a fresh process with its existing 30 s bound.
"""

from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[3]
SWIFT_PROBE = ROOT / "tools/runtime/fixtures/swift_sdk_elyx_developer_probe.swift"
HELPER = ROOT / "tools/runtime/fixtures/native_elyx_developer_probe.py"
EMITTER = ROOT / "tools/runtime/fixtures/emit_elyx_developer_probe.py"
CONTRACT = ROOT / "docs/wave-2/elyx-source-descriptor-v1.json"
NFD02 = ROOT / "docs/wave-2/elyx-nfd02-inputs.json"
PYTHON_INPUTS = ("exteraless_runtime/_elyx_readiness.py", "exteraless_runtime/_elyx_developer.py",
                 "exteraless_runtime/_archives.py", "exteraless_runtime/_dependencies.py")
REQUIRED_CHECKS = (
    "ok", "actual_readiness", "missing_readiness_rejected", "verified_inspection",
    "native_changes_persisted", "new_owner_verified_load", "clean_compare",
    "stale_owner_session_epoch_rejected", "old_capability_rejected", "cleanup",
    "load_policy_refused_before_retirement", "zero_old_retirement", "consent_preserved", "stale_source_rejected",
)
BOUNDARY = "Real public Host activation/FD registry/C/CPython Elyx SDK; owned local fixtures; no UIKit/network"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_inputs(python_root):
    if sha(CONTRACT) != "7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c":
        raise RuntimeError("Elyx developer child requires the sealed v1 descriptor ABI")
    sealed = json.loads(NFD02.read_text(encoding="utf-8"))
    if (sealed.get("finding") != "NFD-02"
            or sha(python_root / "exteraless_runtime/_archives.py") != sealed["sha256"]["python/exteraless_runtime/_archives.py"]):
        raise RuntimeError("Elyx developer child requires the archive owner's sealed load-policy preflight")
    paths = [SWIFT_PROBE, HELPER, EMITTER, Path(__file__), CONTRACT, NFD02]
    for name in PYTHON_INPUTS:
        actual, reference = python_root / name, ROOT / "python" / name
        if not actual.is_file() or sha(actual) != sha(reference):
            raise RuntimeError("Staged Elyx developer production input differs: " + name)
        paths.append(actual)
    return paths


def stage(work, python):
    inputs = work / "input"
    subprocess.run([str(python), "-I", "-S", "-B", str(EMITTER), str(inputs)],
                   check=True, timeout=20, stdout=subprocess.DEVNULL)
    names = {"owned.elyx", "expected-next.elyx", "changes.json", "compare-next.json", "reject-requires.json", "reject-python.json"}
    files = {path.name: path for path in inputs.iterdir()}
    if set(files) != names or any(not path.is_file() for path in files.values()):
        raise RuntimeError("Elyx developer child requires exactly its six owned input artifacts")
    support = work / "probe-support"
    support.mkdir()
    helper = support / HELPER.name
    shutil.copyfile(HELPER, helper)
    if sha(helper) != sha(HELPER) or helper.stat().st_size + sum(path.stat().st_size for path in files.values()) >= 32768:
        raise RuntimeError("Elyx developer observer/input artifacts differ or exceed the aggregate 32 KiB bound")
    return helper, {name: sha(path) for name, path in sorted(files.items())}


def validate_report(report, python_root, work):
    if any(report.get(name) is not True for name in REQUIRED_CHECKS) or report.get("boundary") != BOUNDARY:
        raise RuntimeError("Real Elyx developer activation/publication checks did not pass")
    if report.get("initializations") != 1 or report.get("finalizations") != 1 or report.get("unexpected_effects") != []:
        raise RuntimeError("Elyx developer child changed process lifetime or attempted an external effect")
    if any(report.get(name) != 0 for name in ("source_receipts", "stages", "read_tickets", "capabilities", "file_authorities")):
        raise RuntimeError("Elyx developer native custody was not reclaimed")
    if report.get("gate_bytes", 0) <= 0 or any(report.get("gate_operations", {}).get(name, 0) <= 0
                                             for name in ("claim", "manifest", "read", "check", "release")):
        raise RuntimeError("Elyx developer receipt omitted actual registry operations/bytes")
    traces = report.get("traces", [])
    if len(traces) != 12 or len({row.get("reference") for row in traces}) != 12:
        raise RuntimeError("Expected twelve actual inspector/owner lifetimes in the fifth child")
    tags = Counter(tag for row in traces for tag in row.get("scripts", []))
    for name, count in {"readiness": 5, "metadata_json": 2, "fd-inspection": 3,
                        "owner-bootstrap": 2, "load_json": 1, "_elyx_developer.load_verified_json": 1, "unload": 2}.items():
        if tags[name] != count:
            raise RuntimeError("Wrong real Host script count: " + name)
    owners = []
    hooks = Counter()
    for row in traces:
        observation = row.get("observation", {})
        if (row.get("destroyed") is not True or row.get("own_gil") is not True or row.get("observation_error")
                or observation.get("builtin") is not True or observation.get("plugins") != [] or observation.get("network") != []
                or any(observation.get(name) != 0 for name in ("handles", "leases", "legacy_services", "mock_calls"))):
            raise RuntimeError("Fifth-child native/SDK cleanup or built-in backend evidence failed")
        for name, count in observation.get("hooks", {}).items():
            if Path(observation.get("hook_sources", {}).get(name, "")).resolve() != (python_root / "exteraless_runtime/_archives.py").resolve():
                raise RuntimeError("Fifth child executed a substituted archive hook")
            hooks[name] += count
        if row.get("plugin_id") is None:
            if (row.get("allow_threads") is not False or observation.get("plugin") is not None
                    or any(observation.get(name) != 0 for name in ("entry_calls", "load_calls", "unload_calls"))):
                raise RuntimeError("A trusted metadata/readiness worker entered plugin code")
        else:
            owners.append(row)
            if (row["plugin_id"] != "native_elyx_dev" or observation.get("plugin") != row["plugin_id"]
                    or observation.get("backend_installed") is not True
                    or any(observation.get(name) != 1 for name in ("entry_calls", "load_calls", "unload_calls"))):
                raise RuntimeError("Fifth child did not execute exactly one entry/load/unload per real owner")
    if len(owners) != 2 or any(hooks[name] <= 0 for name in ("developer_manifest", "inspect_developer_descriptor", "verified_developer_load")):
        raise RuntimeError("Fifth child did not observe two owners and all three actual Python hooks")
    snapshots = report.get("snapshots", {})
    if set(snapshots) != {"first", "next"}:
        raise RuntimeError("Missing actual fifth-child SDK snapshots")
    for label, value in snapshots.items():
        uuid.UUID(value["owner"])
        if (value.get("seen") != [label, "asset-" + label, "wheel-" + label] or value.get("entry_calls") != 1
                or value.get("class_name") != "NativeElyxDeveloperProbe" + ("Next" if label == "next" else "")):
            raise RuntimeError("Changed entry/helper/asset/same-filename wheel did not execute")
        for key, relative in (("runtime_source", "exteraless_runtime/__init__.py"), ("archive_source", "exteraless_runtime/_archives.py")):
            if Path(value.get(key, "")).resolve() != (python_root / relative).resolve():
                raise RuntimeError("Fifth-child SDK snapshot has the wrong production source")
        for name in ("helper", "wheel", "extract"):
            if not Path(value[name]).resolve().is_relative_to((work / "native-storage/cache").resolve()):
                raise RuntimeError("Fifth-child code/resource escaped its native owner cache")
        if Path(value["extract"]).exists():
            raise RuntimeError("A retired fifth-child extraction survived Host uninstall")
    for key in ("owner", "digest", "helper", "wheel"):
        if snapshots["first"][key] == snapshots["next"][key]:
            raise RuntimeError("Native Elyx developer replacement reused " + key)
    if snapshots["first"]["digest"] != sha(work / "input/owned.elyx"):
        raise RuntimeError("Initial native owner did not load the emitted source image")
    refusals = report.get("refusals", {})
    if set(refusals) != {"requires", "python"}:
        raise RuntimeError("Fifth child omitted known unsupported candidate witnesses")
    for name, value in refusals.items():
        if (value.get("ok") is not False or value.get("reloaded") is not False or value.get("source_changed") is not False
                or value.get("publication_outcome") != "refused" or value.get("plugin_id") != "native_elyx_dev"):
            raise RuntimeError("Unsupported " + name + " candidate did not preserve zero old retirement/publication")
    if list((work / "native-storage/.elyx-developer-staging").iterdir()):
        raise RuntimeError("Fifth-child native staging did not drain")
