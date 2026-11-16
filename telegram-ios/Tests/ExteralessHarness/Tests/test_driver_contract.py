"""Host driver contracts, NOT UIKit/renderer evidence.

Synthetic reports here test rejection of stale/partial artifacts. Only the
separate native app + recorded simulator frames can establish UI acceptance.
"""

import copy
import hashlib
import importlib.util
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/runtime"))
import client_ui_harness as driver
from client_ui_harness_domains import REQUIRED_SOURCE_SUFFIXES
from native_fd_evidence import IOS_FD_HELPER

spec = importlib.util.spec_from_file_location("client_context_stubs", ROOT / "telegram-ios/Tests/ExteralessHarness/Tools/generate_context_stubs.py")
stubs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stubs)


def synthetic_report(scenario, run_id):
    names = driver.SDK_PROBES if scenario == "sdk-ui" else driver.CORE_PROBES
    report = {"format": "exteraless-client-ui-harness/1", "scenario": scenario, "runId": run_id,
              "phase": "completed", "semanticPassed": True, "unexpectedServices": [],
              "visualReview": "pending-recorded-frame-review",
              "probes": [{"name": name, "elements": [{"class": "CONTRACT_TEST_ONLY"}],
                          "controllers": ["CONTRACT_TEST_ONLY"], "scale": 3} for name in names],
              "facts": {"realPython": False}}
    if scenario == "sdk-ui":
        files = {"telegram-ios/fixture" + suffix: "a" * 64 for suffix in REQUIRED_SOURCE_SUFFIXES}
        files[IOS_FD_HELPER] = "b" * 64
        manifest = {"format": "exteraless-ui-domain-sources/1", "files": files,
                    "sha256": hashlib.sha256("".join(value + "  " + name + "\n" for name, value in sorted(files.items())).encode()).hexdigest()}
        report["facts"] = {"runtime": {"realPython": True, "stopped": True,
            "engine": {"initializations": 1, "finalizations": 1, "created": [1, 2, 3], "destroyed": [1, 2, 3], "scriptCalls": 8},
            "hostEpochs": ["old", "new"], "ui": {"cEpochs": ["new", "old"], "nativeUICalls": 8}}}
        report["facts"]["domainSources"] = manifest
        report["facts"]["runtime"]["engine"].update(fdProbeScriptCalls=4, fdPaths=[
            {"nativeReference": index + 2, "ownerToken": epoch, "platform": "ios", "bridgeBuiltin": True,
             "helperSHA256": files[IOS_FD_HELPER], "checks": {"actual_ios_fd_paths": True, "darwin_family_fd_paths": True}}
            for index, epoch in enumerate(("old", "new"))])
    return report


class DriverOwnershipTests(unittest.TestCase):
    def test_selects_type_not_an_existing_device_or_future_hardware_runtime(self):
        device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
        types = [{"name": "iPhone 17", "identifier": device_type}]
        def runtime(suffix, release, available=True):
            return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + suffix,
                    "version": release, "isAvailable": available, "supportedDeviceTypes": [{"identifier": device_type}]}
        expected = runtime("26-6", "26.6")
        choices = [runtime("27-1", "27.1"), runtime("26-7", "26.7", False),
                   runtime("27-1-iPhoneDuo", "27.1"), expected]
        self.assertEqual(driver.select_device_type_and_runtime(types, choices, "26.6"), (device_type, expected))
        with self.assertRaises(RuntimeError):
            driver.select_device_type_and_runtime([], choices, "26.6")

    def test_cleanup_requires_exact_created_uuid_name_type_and_runtime(self):
        record = {"name": driver.DEVICE_PREFIX + str(uuid.uuid4()), "udid": str(uuid.uuid4()),
                  "runtime": "runtime", "deviceType": "type"}
        item = {"name": record["name"], "udid": record["udid"], "deviceTypeIdentifier": "type"}
        self.assertTrue(driver.owned_device(record, {"runtime": [item]}))
        for key in ("name", "udid", "deviceTypeIdentifier"):
            changed = dict(item, **{key: "user-device"})
            self.assertFalse(driver.owned_device(record, {"runtime": [changed]}))
        self.assertFalse(driver.owned_device(record, {"other-runtime": [item]}))
        self.assertFalse(driver.owned_device(dict(record, name="iPhone 17"), {"runtime": [item]}))
        self.assertFalse(driver.owned_device(dict(record, udid="booted"), {"runtime": [item]}))

    def test_recording_finalizes_only_its_own_process_group_with_sigint(self):
        process = mock.Mock(pid=8234)
        process.poll.return_value = None
        with mock.patch.object(driver.os, "killpg", create=True) as kill:
            driver.stop_process(process, interrupt=True)
        kill.assert_called_once_with(8234, signal.SIGINT)
        process.wait.assert_called_once_with(timeout=5)

    def test_archive_traversal_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for member in ("../account-data", "/absolute", "Payload/ClientUIHarness.app/../../outside"):
                archive = root / "bad.ipa"
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr(member, "not a fixture")
                with self.assertRaises(ValueError):
                    driver.extract_app(archive, root / "unpacked")
            self.assertFalse((root / "account-data").exists())


class EvidenceTests(unittest.TestCase):
    def test_zero_probe_partial_wrong_run_and_visual_claim_cannot_pass(self):
        run_id = str(uuid.uuid4())
        good = synthetic_report("core-light", run_id)
        driver.validate_state(good, "core-light", run_id)
        for changes in ({"probes": []}, {"phase": "ready"}, {"runId": str(uuid.uuid4())},
                        {"unexpectedServices": ["network"]}, {"visualReview": "passed"},
                        {"probes": good["probes"][:-1]}, {"semanticPassed": False}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                driver.validate_state(dict(good, **changes), "core-light", run_id)

    def test_sdk_requires_real_native_calls_two_epochs_and_all_interpreters_destroyed(self):
        run_id = str(uuid.uuid4())
        good = synthetic_report("sdk-ui", run_id)
        driver.validate_state(good, "sdk-ui", run_id)
        for target, key, value in (("engine", "destroyed", [1, 2]), ("engine", "created", []),
                                   ("engine", "finalizations", 0), ("ui", "nativeUICalls", 0),
                                   ("ui", "cEpochs", ["old"]), (None, "hostEpochs", ["old", "old"]),
                                    (None, "realPython", False)):
            bad = copy.deepcopy(good)
            runtime = bad["facts"]["runtime"]
            (runtime[target] if target else runtime)[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                driver.validate_state(bad, "sdk-ui", run_id)
        for change in ("mac-only", "missing-owner", "classification-error"):
            bad = copy.deepcopy(good)
            rows = bad["facts"]["runtime"]["engine"]["fdPaths"]
            if change == "mac-only": rows[0]["checks"].pop("actual_ios_fd_paths")
            elif change == "missing-owner": rows.pop()
            else: rows[0]["error"] = "Host.fd_probe_classification: unknown service"
            with self.subTest(fd_change=change), self.assertRaises(ValueError):
                driver.validate_state(bad, "sdk-ui", run_id)

    def test_protocol_generation_uses_current_signatures_and_named_traps(self):
        text = (ROOT / "telegram-ios/submodules/AccountContext/Sources/AccountContext.swift").read_text(encoding="utf-8")
        generated = stubs.generate(text)
        self.assertIn('fatalError("client-ui-harness: SharedAccountContext.makeChatController is not provided")', generated)
        self.assertIn('fatalError("client-ui-harness: SharedAccountContext.mediaManager is not provided")', generated)
        context = (ROOT / "telegram-ios/Tests/ExteralessHarness/AppContext/ClientHarnessAccountContext.swift").read_text(encoding="utf-8")
        self.assertIn('precondition(self.composerRendering, "client-ui-harness: premium requires the explicit ordinary-user composer fixture")', context)
        self.assertNotIn('public var presentationData ', generated)
        self.assertNotIn('return false', generated)
        self.assertNotIn('return 0', generated)
        # Multiline requirements must remain complete, not func foo( {.
        self.assertIn('func makeChatHistoryListNode( context:', generated)
        self.assertIn('mode: ChatHistoryListMode ) -> ChatHistoryListNode', generated)
        changed = text.replace('    var account: Account { get }', '    var renamedAccount: Account { get }')
        with self.assertRaises(ValueError):
            stubs.generate(changed)


if __name__ == "__main__":
    unittest.main()
