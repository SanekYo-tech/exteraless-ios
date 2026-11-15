"""Source staging/locking and Xcode pin checks; no UIKit, plugins or CI dispatch."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/runtime"))
import client_ui_harness_build as build
import client_ui_harness_workspace as workspace


class OwnedWorkspaceTests(unittest.TestCase):
    repository = "fixture/client"

    def setUp(self):
        parent = os.environ.get("RUNNER_TEMP")
        if parent is None and os.name == "nt":
            preferred = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode"
            if preferred.is_dir():
                parent = str(preferred)
        self.temporary = tempfile.TemporaryDirectory(prefix="client-ui-workspace-test-", dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "checkout"
        (self.source / "Tests/ExteralessHarness").mkdir(parents=True)
        for name in ("versions.json", "MODULE.bazel", "Tests/ExteralessHarness/BUILD"):
            (self.source / name).write_text("{}\n", encoding="utf-8")
        self.root = self.base / "owned"
        self.calls = []

    def record(self, argv, **options):
        self.calls.append((argv, options))

    def stage(self, generation="1-1", run=None):
        return workspace.stage(self.root, self.repository, generation, self.source, run=run or self.record)

    def test_unmarked_directory_is_not_adopted_or_modified(self):
        self.root.mkdir()
        unknown = self.root / "user-file"
        unknown.write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "ownership sentinel"):
            self.stage()
        self.assertEqual(unknown.read_text(), "keep")
        self.assertFalse((self.root / workspace.MARKER).exists())
        self.assertEqual(self.calls, [])

    def test_marked_directory_reuses_only_its_source_child(self):
        destination = self.stage()
        marker = (self.root / workspace.MARKER).read_bytes()
        cached = self.root / "bazel-user-root/retained-cache"
        cached.write_text("retain", encoding="utf-8")
        self.stage("2-1")
        self.assertEqual((self.root / workspace.MARKER).read_bytes(), marker)
        self.assertEqual(cached.read_text(), "retain")
        for argv, options in self.calls:
            self.assertEqual(argv[0], "rsync")
            self.assertIn("--delete", argv)
            self.assertEqual(Path(argv[-1]), destination)
            self.assertEqual(Path(argv[-2]), self.source.resolve())
            self.assertEqual(options["timeout"], 300)
        self.assertTrue(workspace.read_generation(self.root, self.repository)["ready"])

    def test_foreign_repository_cannot_refresh_owned_source(self):
        self.stage()
        before = (self.root / workspace.GENERATION).read_bytes()
        with self.assertRaisesRegex(ValueError, "unowned"):
            workspace.stage(self.root, "another/repository", "2-1", self.source, run=self.record)
        self.assertEqual((self.root / workspace.GENERATION).read_bytes(), before)
        self.assertEqual(len(self.calls), 1)

    def test_failed_sync_invalidates_the_previous_generation(self):
        self.stage()
        def failed(*args, **kwargs):
            raise RuntimeError("rsync fixture failure")
        with self.assertRaisesRegex(RuntimeError, "rsync fixture"):
            self.stage("2-1", run=failed)
        executed = mock.Mock()
        for generation in ("1-1", "2-1"):
            with self.assertRaisesRegex(ValueError, "generation changed|staging did not finish"):
                workspace.execute_owned(self.root, self.repository, generation, ["must-not-run"], 1, run=executed)
        executed.assert_not_called()

    def test_replaced_generation_and_competing_lock_block_execution(self):
        self.stage()
        self.stage("2-1")
        with self.assertRaisesRegex(ValueError, "generation changed"):
            workspace.execute_owned(self.root, self.repository, "1-1", ["must-not-run"], 1, run=self.record)
        with workspace.locked_workspace(self.root, self.repository):
            with self.assertRaises(TimeoutError):
                with workspace.locked_workspace(self.root, self.repository, wait=0):
                    self.fail("competing writer acquired the lock")
        def child(argv, **options):
            # The actual OS lock is held through the child call, not just validation.
            with self.assertRaises(TimeoutError):
                with workspace.locked_workspace(self.root, self.repository, wait=0):
                    self.fail("stage could overwrite sources during a child command")
        workspace.execute_owned(self.root, self.repository, "2-1", ["fixture-child"], 1, run=child)

    def test_source_and_owned_tree_cannot_overlap(self):
        nested = self.source / "owned"
        with self.assertRaisesRegex(ValueError, "separate trees"):
            workspace.stage(nested, self.repository, "1-1", self.source, run=self.record)
        self.assertFalse(nested.exists())
        self.assertEqual(self.calls, [])


class XcodePinTests(unittest.TestCase):
    def test_application_path_tracks_versions_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for version in ("27.1", "27.2"):
                (root / "versions.json").write_text(json.dumps({"xcode": version}), encoding="utf-8")
                self.assertEqual(build.pinned_xcode_app(root).as_posix(), "/Applications/Xcode_" + version + ".app")

    def test_preflight_accepts_app_xcode_and_rejects_older_component_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "versions.json").write_text('{"xcode":"27.1"}', encoding="utf-8")
            with mock.patch.object(build, "source_preflight", return_value=[]), \
                    mock.patch.object(build.sys, "platform", "darwin"), \
                    mock.patch.object(build.platform, "machine", return_value="arm64"), \
                    mock.patch.object(build, "command", return_value="Xcode 27.1\nBuild version fixture") as command:
                current = build.preflight(root)
                self.assertEqual(current["errors"], [])
                self.assertFalse(current["swiftTypechecked"])
                command.return_value = "Xcode 26.6\nBuild version fixture"
                old = build.preflight(root)
                self.assertEqual(old["status"], "build-blocked")
                self.assertIn("Xcode_27.1.app", old["errors"][0])


if __name__ == "__main__":
    unittest.main()
