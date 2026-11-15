"""Bounded cross-source parity checks; these are not Swift/iOS execution tests.

Run explicitly: python swift/PluginHost/NativeServiceSourceTests.py
Only reads this checkout. No accounts, network, subprocesses or plugin execution.
"""

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "third_party/exteraless-android/TMessagesProj/src/main"
HOST = ROOT / "swift/PluginHost/Sources/PluginHost"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices"
SCHEMA = ROOT / "docs/wave-2/native-services-wire.schema.json"


class NativeServiceSourceTests(unittest.TestCase):
    def test_notification_ids_are_the_original_source_ids_with_real_publishers(self):
        source = (ANDROID / "java/org/telegram/messenger/NotificationCenter.java").read_text(encoding="utf-8")
        names = re.findall(r"public static final int (\w+) = totalEvents\+\+;", source)
        actual = {name: i + 1 for i, name in enumerate(names)}
        native = (HOST / "NativeServiceOperations.swift").read_text(encoding="utf-8")
        mapping = dict((name, int(value)) for name, value in re.findall(r"case (\w+) = (\d+)", native))
        # Phase 2 pins the additional payload-bearing ids in its own source suite.
        mapping = {name: value for name, value in mapping.items() if name in {"contactsDidLoad", "mainUserInfoChanged", "didUpdateConnectionState"}}
        self.assertEqual(set(mapping), {"contactsDidLoad", "mainUserInfoChanged", "didUpdateConnectionState"})
        publishers = {
            "contactsDidLoad": ANDROID / "java/org/telegram/messenger/ContactsController.java",
            "mainUserInfoChanged": ANDROID / "java/org/telegram/messenger/MessagesController.java",
            "didUpdateConnectionState": ANDROID / "java/org/telegram/tgnet/ConnectionsManager.java",
        }
        provider = (UI / "PluginNativeServicesBridgeExtension.swift").read_text(encoding="utf-8")
        for name, event_id in mapping.items():
            with self.subTest(event=name):
                self.assertEqual(event_id, actual[name])
                self.assertIn("postNotificationName(NotificationCenter." + name + ")", publishers[name].read_text(encoding="utf-8"))
                self.assertIn("self.emit(." + name + ", arguments: [], scope:", provider)
        self.assertIn("context.account.networkState", provider)
        self.assertIn("nativeServiceContactIDs(account: context.account)", provider)
        self.assertIn("context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))", provider)

    def test_wire_operation_names_and_all_fragment_references_resolve(self):
        fragment = json.loads(SCHEMA.read_text(encoding="utf-8"))
        provider = (UI / "PluginNativeServicesBridgeExtension.swift").read_text(encoding="utf-8")
        declaration = re.search(r"private static let members: Set<String> = \[(.*?)\n    \]", provider, re.S)
        self.assertIsNotNone(declaration)
        native = set(re.findall(r'"([A-Za-z]+)"', declaration.group(1)))
        self.assertEqual(native, set(fragment["x-operations"]))

        def check(value):
            if isinstance(value, dict):
                if "$ref" in value:
                    reference = value["$ref"]
                    self.assertTrue(reference.startswith("#/"))
                    target = fragment
                    for key in reference[2:].split("/"):
                        target = target[key]
                    self.assertIsInstance(target, dict)
                for child in value.values():
                    check(child)
            elif isinstance(value, list):
                for child in value:
                    check(child)

        check(fragment)

    def test_named_queue_inventory_matches_actual_python_sdk_constants(self):
        sdk = (ANDROID / "python/client_utils.py").read_text(encoding="utf-8")
        original = set(re.findall(r'^([A-Z_]+_QUEUE) = "[A-Z_]+_QUEUE"$', sdk, re.M))
        self.assertEqual(len(original), 8)
        native = (HOST / "NativeServiceScheduler.swift").read_text(encoding="utf-8")
        declaration = re.search(r"public static var queueNames: Set<String> \{(.*?)\n    \}", native, re.S)
        self.assertIsNotNone(declaration)
        names = set(re.findall(r'"([A-Z_]+)"', declaration.group(1)))
        self.assertEqual(names, original | {"UI"})
        fragment = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.assertEqual(names, set(fragment["$defs"]["queue"]["enum"]))

    def test_original_file_return_is_ignored_and_filters_are_filename_substrings(self):
        source = (ANDROID / "java/app/exteraless/plugins/files/FilesControllerJava.java").read_text(encoding="utf-8")
        self.assertRegex(source, r'handler\.onClick\.callAttr\("__call__", args\);\s*return true;')
        self.assertIn("passesFilters(handler, fileNameOf(args))", source)
        self.assertIn("name.contains(w)", source)
        self.assertIn("name.contains(b)", source)
        model = (HOST / "NativeServiceInterceptionModels.swift").read_text(encoding="utf-8")
        self.assertIn("whitelist.contains(where: { name.contains($0) })", model)

    def test_new_ui_sources_respect_postbox_import_boundary(self):
        checker_path = ROOT / "telegram-ios/build-system/Make/PostboxImportCheck.py"
        spec = importlib.util.spec_from_file_location("NativeServicePostboxImportCheck", checker_path)
        checker = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(checker)
        files = sorted(UI.glob("*.swift"))
        self.assertGreaterEqual(len(files), 3)
        for path in files:
            source = path.read_text(encoding="utf-8")
            self.assertTrue(checker.is_in_scope(path.relative_to(ROOT / "telegram-ios").as_posix()))
            self.assertIsNone(checker.find_import_line(source), path.name)
            self.assertIsNone(checker.find_access_line(source), path.name)
            self.assertEqual(checker.find_unwrappable_media(source), [], path.name)
            self.assertNotRegex(source, r"(?m)^\s*(?:\w+\s+)?import TelegramApi\b", path.name)
        core = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime"
        media = (core / "NativeServiceMedia.swift").read_text(encoding="utf-8")
        self.assertIn("account.postbox.mediaBox.resourceData", media)
        self.assertIn("fetchedMediaResource(mediaBox: account.postbox.mediaBox", media)
        self.assertIn("transaction.getMessage(messageId)", media)


if __name__ == "__main__":
    unittest.main()
