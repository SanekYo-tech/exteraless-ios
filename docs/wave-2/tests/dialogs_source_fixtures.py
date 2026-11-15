"""Bounded, offline source contracts. This is not a Swift build or a UI test."""
from pathlib import Path
import importlib.util
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "telegram-ios/submodules/TelegramCore/Sources"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources"
CHECK = ROOT / "telegram-ios/build-system/Make/PostboxImportCheck.py"
spec = importlib.util.spec_from_file_location("dialog_postbox_check", CHECK)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def text(path):
    return path.read_text(encoding="utf-8")


def code(path):
    return checker.strip_comments_and_strings(text(path))


def hunks(patch_path="docs/wave-2/dialogs-native-hunks.patch"):
    path, lines = None, []
    for line in text(ROOT / patch_path).splitlines():
        if line.startswith("*** Update File: ") or line == "*** End Patch" or line.startswith("@@"):
            if path is not None and lines:
                yield path, lines
                lines = []
            if line.startswith("*** Update File: "):
                path = line.removeprefix("*** Update File: ")
        elif path is not None:
            lines.append(line)


class DialogSourceFixtures(unittest.TestCase):
    def test_read_only_adapters_do_not_mutate_read_or_draft_state(self):
        paths = [CORE / "ExteralessDialogs" / name for name in [
            "ExteralessDialogList.swift", "ExteralessDialogSearch.swift",
            "ExteralessDialogPolicy.swift", "ExteralessDialogStories.swift",
            "ExteralessDialogBadgeContribution.swift",
        ]] + [UI / "ExteralessClient/Dialogs/ExteralessDialogBackBadge.swift", UI / "ChatHistoryNavigationStack.swift"]
        prohibited = re.compile(r"\b(?:applyMaxReadIndex\w*|mark\w*Read\w*|resetIncomingReadStates|setPeerReadState|setSynchronizeableChatInputState|clearPeerUnseen\w*|removeAllChatListEntries)\s*\(")
        for path in paths:
            with self.subTest(path=path.name):
                self.assertIsNone(prohibited.search(code(path)))
        native = code(CORE / "TelegramEngine/Peers/TelegramEnginePeers.swift")
        start = native.index("public func getNextUnreadChannel(")
        end = native.index("public func", native.index("public func getNextUnreadForumTopic(") + 12)
        self.assertIsNone(prohibited.search(native[start:end]))

    def test_native_cursor_and_one_way_privacy_composition(self):
        source = code(CORE / "ExteralessDialogs/ExteralessDialogList.swift")
        self.assertIn("account.postbox.tailChatListView", source)
        self.assertIn("transaction.chatListGetAllPeerIds().count", source)
        self.assertIn("exteralessFilterChatList(account: account, list: list)", source)
        self.assertIn("ExteralessHiddenAccounts.shared.canSelect(identity)", source)
        self.assertNotRegex(source, r"EngineMessage\.(?:Id|Index)\s*\(")
        self.assertNotRegex(source, r"EnginePeer\.Id\s*\(")
        self.assertNotIn(".network", source)
        entries = code(ROOT / "telegram-ios/submodules/ChatListUI/Sources/Node/ChatListNodeEntries.swift")
        self.assertIn("leftIndex.pinningIndex == nil, rightIndex.pinningIndex == nil", entries)
        self.assertIn("left.dialogUnreadPriority != right.dialogUnreadPriority", entries)
        self.assertIn("lhs.dialogUnreadPriority != rhs.dialogUnreadPriority", entries)
        location = code(ROOT / "telegram-ios/submodules/ChatListUI/Sources/Node/ChatListNodeLocation.swift")
        self.assertIn("ExteralessFilteringRuntime.shared.changes", location)
        self.assertIn("ExteralessHiddenAccounts.shared.changes", location)

    def test_real_native_preference_and_no_forum_server_write(self):
        integration = code(UI / "ExteralessClient/Dialogs/ExteralessDialogIntegration.swift")
        self.assertIn("updateChatArchiveSettings(engine: context.engine", integration)
        self.assertIn("withExteralessArchivePull(policy.openArchiveOnPull)", integration)
        forum = code(CORE / "ExteralessDialogs/ExteralessDialogForum.swift")
        self.assertIn("account.postbox.combinedView", forum)
        self.assertIn("transaction.removeItemCacheEntry(id: id)", forum)
        self.assertNotIn("setChannelForumMode", forum)
        self.assertNotIn(".network", forum)
        self.assertNotIn("updateForumViewAsMessages", forum)

    def test_pin_sync_uses_real_capacity_and_one_policy_generation(self):
        sync = code(CORE / "State/ManagedSynchronizePinnedChatsOperations.swift")
        self.assertIn("let preserveAdditionalLocalPins =", sync)
        self.assertIn("enabled: preserveAdditionalLocalPins", sync)
        self.assertIn("exteralessResolveDialogPinSync(transaction:", sync)
        self.assertIn("acknowledgedServerOrder: result == .boolTrue ? encodedItemIds : nil", sync)
        self.assertIn("for itemId in serverItemIds", sync)
        ledger = code(CORE / "ExteralessDialogs/ExteralessDialogPinReconciliation.swift")
        self.assertIn("state.generation == sync.generation", ledger)
        self.assertIn("transaction.getPinnedItemIds(groupId: .root) == sync.localOrder", ledger)
        pin = code(CORE / "ExteralessDialogs/ExteralessDialogPins.swift")
        self.assertIn("Int(limits.maxPinnedChatCount)", pin)
        self.assertIn("Int(limits.maxArchivedPinnedChatCount)", pin)
        self.assertNotIn("Int.max", pin)
        self.assertNotIn("updatePeerCachedData", pin)

    def test_original_unread_collision_and_priority_evidence(self):
        android = ROOT / "third_party/exteraless-android/TMessagesProj/src/main"
        helper = text(android / "java/tw/nekomimi/nekogram/helpers/ChatsHelper.java")
        self.assertIn("return unreadCount > 0 && !counterMuted;", helper)
        self.assertIn("if (reactionCount > 0)", helper)
        self.assertIn("if (mentionCount > 0)", helper)
        neko = text(android / "java/tw/nekomimi/nekogram/NekoConfig.java")
        for field, key, default in [("sortByUnread", "unread", "false"), ("sortByUnmuted", "unmuted", "true"), ("sortByUser", "user", "true"), ("sortByContacts", "contacts", "true")]:
            self.assertIn(f'{field} = addConfig("sort_by_{key}", configTypeBool, {default})', neko)
        schema = text(ROOT / "swift/ExteralessCore/Sources/ExteralessCore/CoreDialogFeatures.swift")
        self.assertIn('"NaConfig.sortByUnread"', schema)
        self.assertNotIn('"NekoConfig.sortByUnread"', schema)

    def test_handoff_exact_eighteen_ids_and_honest_verification(self):
        ownership = json.loads(text(ROOT / "docs/parity/remaining-ownership.json"))
        package = next(p for p in ownership["unfragmented_packages"] if p["id"] == "P-dialog-navigation")
        expected = set(package["feature_ids"]) | {"nagram.sortByUnread", "neko.sortByUnread"}
        fragment = json.loads(text(ROOT / "docs/wave-2/dialogs-parity.json"))
        self.assertEqual(len(fragment["features"]), 18)
        self.assertEqual({f["id"] for f in fragment["features"]}, expected)
        self.assertTrue(all(not f["implementation"]["ported"] for f in fragment["features"]))
        self.assertFalse(fragment["verification"]["native_build_executed"])
        self.assertFalse(fragment["verification"]["visual_frames_verified"])

    def test_shared_hunks_match_declared_applied_and_pending_sources(self):
        integration = json.loads(text(ROOT / "docs/wave-2/dialogs-parity.json"))["integration"]
        applied = set(integration["applied_shared_files"])
        pending = set(integration["pending_shared_files"])
        self.assertFalse(applied & pending)
        checked = []
        for path, block in hunks():
            before = [line[1:].rstrip() for line in block if line.startswith((" ", "-"))]
            after = [line[1:].rstrip() for line in block if line.startswith((" ", "+"))]
            self.assertIn(path, applied | pending)
            self.assertNotIn("AccountStateManagementUtils.swift", path)
            expected = after if path in applied else before
            source = [line.rstrip() for line in text(ROOT / path).splitlines()]
            positions = [i for i in range(len(source) - len(expected) + 1) if source[i:i + len(expected)] == expected]
            with self.subTest(path=path, anchor=before[:1]):
                self.assertEqual(len(positions), 1, "Declared applied/pending hunk does not match actual source")
            checked.append(path)
        self.assertGreater(len(checked), 15)
        self.assertEqual(set(checked), applied | pending)
        state = integration["deferred_state_hunk"]
        state_blocks = list(hunks(state["path"]))
        self.assertEqual(len(state_blocks), 1)
        path, block = state_blocks[0]
        self.assertEqual(path, "telegram-ios/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift")
        expected = [line[1:].rstrip() for line in block if line.startswith((" ", "+" if state["applied"] else "-"))]
        source = [line.rstrip() for line in text(ROOT / path).splitlines()]
        self.assertEqual(sum(source[i:i + len(expected)] == expected for i in range(len(source) - len(expected) + 1)), 1)

    def test_applied_navigation_and_stories_use_native_sources(self):
        history = code(UI / "ChatHistoryListNode.swift")
        reset = history.index("let expandProgress = strongSelf.currentOverscrollExpandProgress")
        gate = history.index("exteralessDialogPolicy().allowsSwipeToNext(isTopic: strongSelf.chatLocation.threadId != nil)", reset)
        navigation = history.index("strongSelf.openNextChannelToRead?(nextChannelToRead.peer, nextChannelToRead.threadData, nextChannelToRead.location)", gate)
        self.assertLess(reset, gate)
        self.assertLess(gate, navigation)
        self.assertIn("strongSelf.currentOverscrollExpandProgress = 0.0", history[reset:gate])
        chat = code(UI / "ChatController.swift")
        self.assertIn("self.updateExteralessDialogHistoryControls(policy: policy)", chat)
        self.assertIn("self.presentationInterfaceState.interfaceState.selectionState == nil && policy.allowsSwipeToNext", chat)
        controller = code(ROOT / "telegram-ios/submodules/ChatListUI/Sources/ChatListController.swift")
        self.assertEqual(controller.count("exteralessDialogStorySource("), 3)
        self.assertIn("context.engine.messages.preloadStorySubscriptions(", controller)
        self.assertIn("context.engine.messages.storySubscriptions(", controller)
        self.assertIn("exteralessDialogViewForumAsMessages(peer: peer, layout: dialogForumLayout", controller)
        for path, block in hunks():
            added = "\n".join(line[1:] for line in block if line.startswith("+"))
            self.assertNotRegex(added, r"Engine(?:Peer|Message)\.(?:Id|Index)\s*\(", path)


if __name__ == "__main__":
    unittest.main()
