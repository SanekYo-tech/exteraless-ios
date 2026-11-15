"""Bounded static contracts for privacy integration; not a Swift/runtime test.

Run from repository root: python docs/wave-2/tests/privacy_source_fixtures.py
Only local source text and the repository's PostboxImportCheck are inspected.
"""
import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "telegram-ios"
spec = importlib.util.spec_from_file_location(
    "postbox_import_check", NATIVE / "build-system/Make/PostboxImportCheck.py"
)
CHECK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CHECK)


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def code(path):
    return CHECK.strip_comments_and_strings(source(path))


CORE = "telegram-ios/submodules/TelegramCore/Sources/"
UI = "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Privacy/"


class PrivacySourceFixtures(unittest.TestCase):
    def test_real_ui_files_have_no_postbox_import_access_or_raw_types(self):
        files = sorted((ROOT / UI).glob("*.swift"))
        self.assertEqual(len(files), 5)
        allowlists = "\n".join((NATIVE / path).read_text(encoding="utf-8") for path in (CHECK.ALLOWLIST_PATH, CHECK.ACCESS_ALLOWLIST_PATH))
        for path in files:
            with self.subTest(file=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIsNone(CHECK.find_import_line(text))
                self.assertIsNone(CHECK.find_access_line(text))
                self.assertFalse(CHECK.find_unwrappable_media(text))
                self.assertNotRegex(CHECK.strip_comments_and_strings(text), r"\b(?:PeerId|MessageId|MessageIndex|Transaction)\b")
                self.assertNotIn(path.relative_to(NATIVE).as_posix(), allowlists)

    def test_checker_would_reject_the_removed_shape(self):
        fixture = "import Postbox\nlet query = context.account.postbox.transaction { tx in tx }\n"
        self.assertEqual(CHECK.find_import_line(fixture), 1)
        self.assertEqual(CHECK.find_access_line(fixture), 2)

    def test_real_postbox_contract_and_privacy_bounds_agree(self):
        history = code("telegram-ios/submodules/Postbox/Sources/MessageHistoryTable.swift")
        self.assertIn("precondition(fromIndex.id.peerId == toIndex.id.peerId)", history)
        self.assertIn("precondition(fromIndex.id.namespace == toIndex.id.namespace)", history)
        for relative in ("State/ExteralessPrivacyObservations.swift", "TelegramEngine/Privacy/ExteralessPrivacyObservationData.swift", "State/ExteralessOutgoingPrivacy.swift"):
            self.assertNotIn("MessageIndex.absolute", code(CORE + relative), relative)
        projection = code(CORE + "TelegramEngine/Privacy/ExteralessPrivacyObservationData.swift")
        self.assertIn("MessageIndex.upperBound(peerId: peerId, namespace: namespace)", projection)
        self.assertIn("MessageIndex.lowerBound(peerId: peerId, namespace: namespace)", projection)
        self.assertIn("getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud)", code(CORE + "State/ExteralessOutgoingPrivacy.swift"))

    def test_store_scan_is_bounded_and_quota_is_applied_as_one_batch(self):
        text = code(CORE + "State/ExteralessPrivacyObservations.swift")
        self.assertIn("min(256, PrivacyObservations.maximumReadRecords - inspected)", text)
        self.assertIn("limit: count", text)
        self.assertIn("value.observeReadMessages(peerId:", text)
        self.assertNotIn("value.observeRead(peerId: message.id.peerId", text)
        self.assertIn("value.pruneActivity(now:", text)
        self.assertIn("value.pruneReadRecords()", text)

    def test_queued_store_writes_check_cancel_epoch_and_account_identity(self):
        text = code(CORE + "State/ExteralessPrivacyObservations.swift")
        self.assertIn("guard work.isCurrent", text)
        self.assertIn("state.peerId == accountPeerId", text)
        self.assertIn("state.isTestingEnvironment == testingEnvironment", text)
        self.assertIn("ActionDisposable { work.cancel(); disposable.dispose() }", text)
        self.assertIn("epoch.invalidate()", text)
        self.assertIn("capturedWork: work", text)
        self.assertIn("let work = epoch.makeWork()", text)
        self.assertNotIn("clearItemCacheCollection", text)

    def test_central_allocation_and_persisted_key_identity(self):
        namespaces = source(CORE + "SyncCore/SyncCore_Namespaces.swift")
        block = namespaces.split("public struct CachedItemCollection {", 1)[1].split("\n    }", 1)[0]
        definitions = re.findall(r"public static let (\w+): Int8 = (\d+)", block)
        allocated = {}
        for name, value in definitions:
            value = int(value)
            self.assertNotIn(value, allocated, (name, allocated.get(value)))
            allocated[value] = name
        self.assertLessEqual(max(allocated), 63)
        if 63 in allocated:
            self.assertEqual(allocated[63], "exteralessLocalState")
        else:
            self.assertIn("public static let exteralessLocalState: Int8 = 63", source("docs/wave-2/privacy-phase-2.md"))
        self.assertIn("return 64 + value", namespaces)
        store = source(CORE + "State/ExteralessPrivacyObservations.swift")
        self.assertEqual(store.count("collectionId: Namespaces.CachedItemCollection.exteralessLocalState"), 3)
        keys = re.findall(r'ValueBoxKey\("(exteraless\.privacy\.[^"]+)"\)', store)
        self.assertEqual(set(keys), {"exteraless.privacy.observations.v1", "exteraless.privacy.readDates.v1", "exteraless.privacy.ownLastSeen.v1"})

    def test_raw_metadata_does_not_bypass_global_policy_or_fabricate_pts(self):
        text = source(CORE + "State/ExteralessPrivacyPolicy.swift")
        self.assertIn("exteralessTLPrivacyMetadata(network: network, description: description)", text)
        self.assertIn("allPeersResolved: metadata.allPeersResolved", text)
        self.assertIn("PrivacyPolicy.current.permitsRequest", text)
        self.assertIn("EXTERALESS_PRIVACY_SUPPRESSED", text)
        self.assertNotIn("pts: -1", text)
        self.assertNotIn("return .never()", text)
        self.assertNotIn("Logger.", text)

    def test_pr02_automatic_adapter_never_acquires_manual_grant(self):
        text = code(CORE + "State/ExteralessPrivacyPolicy.swift")
        automatic = text.split("func exteralessReadMessageContents(", 1)[1].split("func exteralessAutomaticReadMessageContents", 1)[0]
        self.assertIn("exteralessAutomaticReadMessageContents", automatic)
        self.assertNotIn("exteralessExplicitReadRequest", automatic)
        adapter = text.split("func exteralessAutomaticReadMessageContents", 1)[1].split("func exteralessReadChannelMessageContents", 1)[0]
        self.assertIn("intent: .automatic(", adapter)
        self.assertIn("self.body == body", text)
        self.assertIn("self.admitted = true", text)
        self.assertIn("policy.allowsMessageRead(peer), automaticMetadataAllows", text)

    def test_pr04_actual_tracker_captures_before_queue_and_disposes_subscription(self):
        text = code(CORE + "State/AccountViewTracker.swift")
        history = text.split("let history = withState(signal", 1)[1].split("let peerId: PeerId?", 1)[0]
        receive = history.split("}, next:", 1)[1].split("}, disposed:", 1)[0]
        self.assertLess(receive.index("exteralessCaptureLoadedMessagesObservation"), receive.index("strongSelf.queue.async"))
        self.assertIn("observation?.start()", receive)
        self.assertNotIn("exteralessObserveLoadedMessages", receive)
        dispose = history.split("}, disposed:", 1)[1]
        self.assertLess(dispose.index("state.observations.dispose()"), dispose.index("strongSelf.queue.async"))
        self.assertEqual(history.count("strongSelf.updatePendingWebpages("), 2)
        self.assertEqual(history.count("strongSelf.updatePolls("), 2)
        self.assertEqual(history.count("strongSelf.historyViewStateValidationContexts.updateView("), 4)

    def test_proxy_loss_state_is_explicit_and_settings_observation_disposes(self):
        text = code(CORE + "Network/ExteralessProxyPolicy.swift")
        self.assertIn("current.update(isAvailable: path.status == .satisfied", text)
        self.assertIn("monitor.cancel()", text)
        self.assertIn("monitor.pathUpdateHandler = nil", text)
        self.assertIn("current.suppressesProxy", text)
        self.assertIn("ActionDisposable { observation.cancel() }", code(CORE + "State/ExteralessPrivacyPolicy.swift"))
        proxy_settings = code(CORE + "SyncCore/SyncCore_ProxySettings.swift")
        self.assertIn("if self.enabled, !ExteralessProxyEnvironment.shared.isSuppressed", proxy_settings)


if __name__ == "__main__":
    unittest.main(verbosity=2)
