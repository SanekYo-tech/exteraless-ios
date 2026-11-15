"""Domain driver rejection/provenance tests. These never render UIKit."""

import copy
import hashlib
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/runtime"))
import client_ui_harness as driver
import client_ui_harness_domains as domains


def source_manifest():
    # Synthetic metadata to test the evidence checker, not claimed source/UI evidence.
    files = {"telegram-ios/submodules/contract-test" + name: "a" * 64 for name in domains.REQUIRED_SOURCE_SUFFIXES}
    canonical = "".join(sha + "  " + name + "\n" for name, sha in sorted(files.items()))
    return {"format": "exteraless-ui-domain-sources/1", "files": files,
            "sha256": hashlib.sha256(canonical.encode()).hexdigest()}


def report(scenario):
    return {"pythonRequested": False, "probes": [{"name": name} for name in domains.PROBES[scenario]],
            "facts": {"domainSources": source_manifest(), "bootstrap": {
                "apiIdentity": "synthetic-private-fixture-store", "systemKeychain": False,
                "retention": "registered-main-application-snapshot-before-writer"},
                "domain": {"name": scenario, "realNativeRenderer": True, "cleanup": True}}}


class DomainDriverTests(unittest.TestCase):
    def test_domains_are_explicit_and_cannot_expand_or_repeat_the_baseline_batch(self):
        self.assertEqual(domains.selected_scenarios(None, driver.SCENARIOS), ("core-light", "core-dark", "sdk-ui"))
        self.assertEqual(domains.selected_scenarios(domains.DOMAIN_SCENARIOS, driver.SCENARIOS), domains.DOMAIN_SCENARIOS)
        for values in (("sdk-ui", "feed-render"), ("feed-render", "feed-render"), ("unknown",),
                       ("feed-render", "player-render", "pill-render", "core-dark")):
            with self.assertRaises(ValueError):
                domains.selected_scenarios(values, driver.SCENARIOS)

    def test_domain_sources_reject_missing_graph_and_changed_digest(self):
        value = source_manifest()
        domains.check_manifest(value)
        for mutation in ("remove", "sha", "path"):
            bad = copy.deepcopy(value)
            first = next(iter(bad["files"]))
            if mutation == "remove":
                del bad["files"][first]
            elif mutation == "sha":
                bad["files"][first] = "b" * 64
            else:
                bad["files"]["../outside"] = bad["files"].pop(first)
            with self.assertRaises(ValueError):
                domains.check_manifest(bad)

    def test_feed_requires_composite_ids_and_current_native_projection(self):
        value = report("feed-render")
        value["facts"]["domain"].update(messageIds=["channel-a:0:" + str(i) for i in range(4)] + ["channel-b:0:3", "channel-b:0:4"],
                                         postCount=4, projectionVerified=True, namespaceIsolation=True)
        domains.validate_domain(value, "feed-render")
        for key, replacement in (("messageIds", ["same"] * 6), ("postCount", 6), ("projectionVerified", False),
                                 ("namespaceIsolation", False), ("cleanup", False)):
            bad = copy.deepcopy(value)
            bad["facts"]["domain"][key] = replacement
            with self.assertRaises(ValueError):
                domains.validate_domain(bad, "feed-render")

    def test_player_rejects_seek_following_or_incomplete_cleanup(self):
        value = report("player-render")
        value["facts"]["domain"].update(seekCount=0, pausedPosition=13, finalPosition=13,
                                         samePositionTickPreservedOffset=True, surfacesStopped=True)
        domains.validate_domain(value, "player-render")
        for key, replacement in (("seekCount", 1), ("finalPosition", 14), ("samePositionTickPreservedOffset", False),
                                 ("surfacesStopped", False)):
            bad = copy.deepcopy(value)
            bad["facts"]["domain"][key] = replacement
            with self.assertRaises(ValueError):
                domains.validate_domain(bad, "player-render")

    def test_pill_requires_cancelled_pending_and_fresh_replacement_lifetimes(self):
        value = report("pill-render")
        value["facts"]["domain"]["final"] = {"owners": ["one", "two", "three"],
            "providers": [{"starts": 1, "cancellations": 1}] * 3}
        domains.validate_domain(value, "pill-render")
        bad = copy.deepcopy(value)
        bad["facts"]["domain"]["final"]["providers"][1]["cancellations"] = 0
        with self.assertRaises(ValueError):
            domains.validate_domain(bad, "pill-render")
        bad = copy.deepcopy(value)
        bad["facts"]["bootstrap"]["systemKeychain"] = True
        with self.assertRaises(ValueError):
            domains.validate_domain(bad, "pill-render")


if __name__ == "__main__":
    unittest.main()
