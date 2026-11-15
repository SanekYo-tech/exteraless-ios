"""Phase-2 source contracts only. Never import/execute corpus plugins or access HTTP."""
import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "third_party/exteraless-android/TMessagesProj/src/main/java"
HOST = ROOT / "swift/PluginHost/Sources/PluginHost"
CORE = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices"


def text(path):
    return path.read_text(encoding="utf-8")


def corpus_report():
    names = ["didReceiveNewMessages", "dialogsNeedReload", "fileLoaded", "fileLoadFailed", "onDownloadingFilesChanged",
             "messagePlayingProgressDidChanged", "messagePlayingPlayStateChanged", "messagePlayingDidStart", "messagePlayingDidSeek",
             "getUser", "getChat", "getClientUserId", "getCurrentUser", "getContacts", "getUserFull", "getChatFull", "getNotificationCenter"]
    result = {name: {"references": 0, "files": []} for name in names}
    count = 0
    for path in sorted((ROOT / "third_party/corpus/all").iterdir()):
        if not path.is_file() or path.suffix not in (".plugin", ".py"):
            continue
        source = path.read_text(encoding="utf-8", errors="replace")
        count += 1
        for name in names:
            occurrences = len(re.findall(r"\b" + re.escape(name) + r"\b", source))
            if occurrences:
                result[name]["references"] += occurrences
                result[name]["files"].append(path.name)
    return {"mode": "static lexical references, not execution or compatibility results", "source_files": count, "members": result}


class NativeServicePhase2SourceTests(unittest.TestCase):
    def test_notification_ids_are_pinned_to_current_android_and_obstructions_stay_unadvertised(self):
        names = re.findall(r"^\s*public static final int (\w+) = totalEvents\+\+;", text(ANDROID / "org/telegram/messenger/NotificationCenter.java"), re.M)
        actual = {name: index + 1 for index, name in enumerate(names)}
        exported = dict((name, int(value)) for name, value in re.findall(r"^\s*case (\w+) = (\d+)$", text(HOST / "NativeServiceOperations.swift"), re.M))
        self.assertEqual(len(exported), 12)
        for name, value in exported.items():
            self.assertEqual(value, actual[name], name)
        for name in ("messagePlayingDidReset", "messagePlayingSpeedChanged", "playerDidStartPlaying"):
            self.assertNotIn(name, exported)

    def test_original_argument_shapes_and_real_native_message_data(self):
        messages = text(ANDROID / "org/telegram/messenger/MessagesController.java")
        self.assertIn("NotificationCenter.didReceiveNewMessages, dialogId, messages, scheduled, mode", messages)
        images = text(ANDROID / "org/telegram/messenger/ImageLoader.java")
        self.assertIn("NotificationCenter.fileLoaded, location, finalFile", images)
        self.assertIn("NotificationCenter.fileLoadFailed, location, canceled", images)
        media = text(ANDROID / "org/telegram/messenger/MediaController.java")
        self.assertIn("NotificationCenter.messagePlayingDidStart, messageObject, oldMessageObject", media)
        self.assertIn("NotificationCenter.messagePlayingDidSeek, playingMessageObject.getId(), progress", media)
        self.assertIn("onFail(false, 0)", text(ANDROID / "org/telegram/messenger/FileLoadOperation.java"))
        native = text(CORE / "NativeServiceMessageValue.swift")
        for expression in ("message.text", "message.timestamp", "message.flags.contains(.Incoming)", "message.groupingKey", "apiTextAttributeEntities", "resource.accessHash", "resource.fileReference"):
            self.assertIn(expression, native)
        events = text(CORE / "NativeServiceAccountEvents.swift")
        self.assertIn("transaction.getMessage(id)", events)
        self.assertIn(".array(batch), .bool(batchScheduled), .integer(0)", events)
        self.assertNotRegex(events, r"\bmessagesForNotification\(")

    def test_new_sources_never_poll_state_or_fetch_contacts_users_at_startup(self):
        accounts = text(CORE / "NativeServiceAccounts.swift")
        self.assertIn("account.postbox.contactPeerIdsView()", accounts)
        provider = text(UI / "PluginNativeServicesBridgeExtension.swift")
        observe = provider[provider.index("@MainActor private func observe("):]
        self.assertNotIn("Item.Contacts.List", observe)
        live = text(UI / "NativeServiceLivePublishers.swift")
        self.assertIn("fetchManager.entriesSummary", live)
        self.assertIn("mediaManager.globalMediaPlayerState", live)
        for path in list(CORE.glob("NativeService*.swift")) + list(UI.glob("*.swift")):
            self.assertNotRegex(text(path), r"\bpollStateUpdateCompletion\(|Api\.functions\.help\.test\(", str(path))

    def test_discovery_only_exposes_installed_publishers_and_wire_names_match(self):
        provider = text(UI / "PluginNativeServicesBridgeExtension.swift")
        self.assertIn("publisherSites.contains(.committedMessages)", provider)
        self.assertIn("publisherSites.contains(.mediaFetch)", provider)
        self.assertIn("notificationsAvailable(account.recordId).contains(event)", provider)
        self.assertIn("scope: scope", provider)
        fragment = json.loads(text(ROOT / "docs/wave-2/native-services-wire.schema.json"))
        declaration = re.search(r"private static let members: Set<String> = \[(.*?)\n    \]", provider, re.S)
        self.assertIsNotNone(declaration)
        self.assertEqual(set(re.findall(r'"([A-Za-z]+)"', declaration.group(1))), set(fragment["x-operations"]))

    def test_changed_ui_sources_pass_the_real_postbox_boundary_parser(self):
        path = ROOT / "telegram-ios/build-system/Make/PostboxImportCheck.py"
        spec = importlib.util.spec_from_file_location("NativePhase2PostboxCheck", path)
        checker = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(checker)
        for name in ("PluginNativeServicesBridgeExtension.swift", "NativeServiceControllerSnapshots.swift", "NativeServiceLivePublishers.swift"):
            source = text(UI / name)
            self.assertIsNone(checker.find_import_line(source), name)
            self.assertIsNone(checker.find_access_line(source), name)
            self.assertEqual(checker.find_unwrappable_media(source), [], name)


if __name__ == "__main__":
    if "--corpus" in sys.argv:
        print(json.dumps(corpus_report(), ensure_ascii=False, indent=2))
    else:
        unittest.main()
