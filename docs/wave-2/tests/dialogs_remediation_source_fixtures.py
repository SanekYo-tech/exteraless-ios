"""Offline source-boundary receipts for IDS-03/04/05; not native execution."""
from pathlib import Path
import importlib.util
import unittest

ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "telegram-ios/submodules/TelegramCore"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Dialogs"
spec = importlib.util.spec_from_file_location("dialog_review_source", ROOT / "docs/wave-2/tests/dialogs_source_fixtures.py")
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class DialogRemediationSourceTests(unittest.TestCase):
    def test_sent_generation_native_intent_and_true_ack_boundaries(self):
        ledger = source.code(NATIVE / "Sources/ExteralessDialogs/ExteralessDialogPinReconciliation.swift")
        sync = source.code(NATIVE / "Sources/State/ManagedSynchronizePinnedChatsOperations.swift")
        self.assertIn("struct ExteralessDialogPinRequest: Codable", ledger)
        self.assertIn("operationLogGetNextEntryLocalIndex", ledger)
        self.assertIn("state.intentRemoved", ledger)
        self.assertIn("state.lastSent = request", ledger)
        self.assertIn("state.generation == sync.generation", ledger)
        self.assertIn("state.revision == sync.revision", ledger)
        self.assertIn("state.claimedOperationIndex", ledger)
        self.assertNotIn("state.claimedOperationIndex = nil", ledger)
        record = sync.index("exteralessRecordDialogPinRequest(")
        send = sync.index("network.request(Api.functions.messages.reorderPinnedDialogs", record)
        self.assertLess(record, send)
        self.assertIn("encodedItemIds.append(itemId)", sync[:record])
        self.assertIn("acknowledgedServerOrder: result == .boolTrue ? encodedItemIds : nil", sync)

    def test_replay_is_narrow_and_authoritative_removal_still_exists(self):
        state = source.code(NATIVE / "Sources/State/AccountStateManagementUtils.swift")
        self.assertIn("case let .UpdatePinnedItemIds(groupId, pinnedOperation):\n                if exteralessReplayDialogPinUpdate(", state)
        self.assertNotIn("exteralessDialogKeepsOverflowPinOnRemoteUnpin", state)
        ledger = source.code(NATIVE / "Sources/ExteralessDialogs/ExteralessDialogPinReconciliation.swift")
        self.assertIn("state.verificationPending || state.disablePending", ledger)
        self.assertIn("result = pinIds(remoteOrder)", ledger)
        self.assertIn("!state.intentRemoved.contains(id)", ledger)
        for forbidden in ["setState(", "resetIncomingReadStates(", "applyMaxReadIndex", "addMessages(", "network.request("]:
            self.assertNotIn(forbidden, ledger)

    def test_initial_false_and_account_local_deduplication(self):
        ui = source.code(UI / "ExteralessDialogIntegration.swift")
        pins = source.code(NATIVE / "Sources/ExteralessDialogs/ExteralessDialogPins.swift")
        ledger = source.code(NATIVE / "Sources/ExteralessDialogs/ExteralessDialogPinReconciliation.swift")
        self.assertNotIn("previousPinsEnabled", ui)
        block = ui[ui.index("pinsDisposable.set((exteralessDialogPolicyUpdates()") : ui.index("public func clearContext()")]
        self.assertIn("map { $0.unlimitedPinnedDialogs }", block)
        self.assertIn("distinctUntilChanged", block)
        self.assertIn("exteralessUpdateDialogPinPolicy(account: context.account)", block)
        self.assertIn("enabled: DialogPolicy.current.unlimitedPinnedDialogs", pins)
        self.assertIn("state.disablePending && !enabled", ledger)
        self.assertIn("state.activeRevision == state.revision", ledger)
        self.assertIn("state.observedOperationWatermark = operationWatermark(transaction)", ledger)

    def test_badge_uses_native_set_once_and_rejects_unqualified_scalar(self):
        native = source.code(NATIVE / "Sources/ExteralessDialogs/ExteralessDialogBadgeContribution.swift")
        ui = source.code(UI / "ExteralessDialogBackBadge.swift")
        self.assertIn("telegramPostboxSeedConfiguration.peerSummaryCounterTags", native)
        self.assertIn("includeTags.intersection(tag)", native)
        self.assertIn("resolvedIsRemovedFromTotalUnreadCount", native)
        self.assertIn("peer.associatedPeerOverridesIdentity", native)
        self.assertLess(native.index("if peerIsIncluded == false"), native.index("guard peerIsIncluded == true"))
        self.assertEqual(ui.count("exteralessFilteredAccountBadge("), 1)
        self.assertEqual(ui.count("exteralessFilteredChatSummary("), 1)
        self.assertNotIn("exteralessFilterChatList(", ui)
        self.assertIn("exteralessDialogBackBadgeText(total: nil", ui)
        self.assertNotIn("globalRemainingUnreadChatCount -=", ui)

    def test_regression_fixtures_are_actual_finite_native_transactions(self):
        test = source.code(NATIVE / "Tests/ExteralessDialogReviewTests.swift")
        self.assertIn("SqliteValueBox(", test)
        self.assertIn("inMemory: true", test)
        self.assertIn("Postbox(queue:", test)
        self.assertIn("postbox.transaction", test)
        self.assertIn("_internal_reorderPinnedItemIds", test)
        self.assertIn("_internal_toggleItemPinned", test)
        self.assertIn("exteralessReplayDialogPinUpdate", test)
        self.assertIn("getTotalUnreadState(groupId: .root)", test)
        self.assertIn("ProcessInfo.processInfo.systemUptime + 20.0", test)
        self.assertNotRegex(test, r"\b(?:Account|AccountManager|Network)\s*\(")
        self.assertNotIn("network.request(", test)


if __name__ == "__main__":
    unittest.main()
