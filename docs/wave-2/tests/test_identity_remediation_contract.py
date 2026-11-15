"""IDS-01/02 bounded source contracts; Swift/native execution is a separate gate."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "swift/ExteralessCore/Sources/ExteralessCore"
NATIVE = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessIdentity"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Identity"


def read(path):
    return path.read_text(encoding="utf-8")


def patch_hunks(path):
    target = None
    old, new = [], []
    for line in read(path).splitlines() + ["*** End Patch"]:
        if line.startswith(("*** Update File:", "@@", "*** End Patch")):
            if old or new:
                yield target, "\n".join(old) + "\n", "\n".join(new) + "\n"
                old, new = [], []
            if line.startswith("*** Update File:"):
                target = line.partition(": ")[2]
        elif target and line.startswith(" "):
            old.append(line[1:]); new.append(line[1:])
        elif target and line.startswith("-"):
            old.append(line[1:])
        elif target and line.startswith("+"):
            new.append(line[1:])


class IdentityRemediationContracts(unittest.TestCase):
    def test_wall_deadline_is_rechecked_on_every_monotonic_wakeup(self):
        text = read(CORE / "IdentityExpiryTimer.swift")
        callback = text[text.index("let cancellation = self.schedule(remaining)"):text.index("if changed, self.isCurrent()")]
        self.assertIn("self.generation == generation", callback)
        self.assertIn("self.refresh()", callback)
        self.assertNotIn("self.availabilityChanged()", callback)
        self.assertIn("let remaining = Double(deadline) - now", text)
        self.assertIn("let active = remaining > 0", text)
        self.assertIn("if self.deadline != deadline", text)
        self.assertNotRegex(text, r"\b(settimeofday|clock_settime)\b")

    def test_both_ui_lifecycle_events_rearm_all_account_leases(self):
        text = read(UI / "ExteralessIdentityIntegration.swift")
        for event in ["UIApplication.didBecomeActiveNotification", "UIApplication.significantTimeChangeNotification"]:
            block = text[text.index(event):]
            self.assertIn("self?.refreshExpirations()", block[:350])
        self.assertIn("for lease in leases.values { lease.refreshExpiration() }", text)

    def test_native_lease_uses_the_same_injected_path_and_retains_token_guards(self):
        text = read(NATIVE / "ExteralessIdentityPresentation.swift")
        lease = text[text.index("public final class ExteralessIdentityAccountLease"):text.index("public struct ExteralessPeerIdentityPresentation")]
        self.assertIn("public convenience init(account: Account)", lease)
        self.assertIn("try self.init(accountId:", lease)
        self.assertIn("isCurrent: { cache.isCurrent(token) }", lease)
        self.assertIn("self.expiry.updateDeadline(state.localPremium ? state.emojiStatus?.until : nil)", lease)
        self.assertIn("public func refreshExpiration() { self.expiry.refresh() }", lease)
        self.assertIn("expiry.invalidate()", lease)
        self.assertIn("if cache.end(token)", lease)

    def test_account_title_entries_delegate_to_the_final_filtered_formatters(self):
        text = read(ROOT / "telegram-ios/submodules/LocalizedPeerData/Sources/PeerTitle.swift")
        self.assertIn("self.exteralessDisplayTitle(identity: exteralessIdentityPresentation(account: account, peer: self)", text)
        self.assertIn("self.exteralessCompactDisplayTitle(identity: exteralessIdentityPresentation(account: account, peer: self))", text)
        self.assertIn("if let name = identity.name { return exteralessZalgoDisplayText(name) }", text)
        self.assertIn("if let name = identity.compactName { return exteralessZalgoDisplayText(name) }", text)

    def test_contacts_filter_after_native_attributed_name_composition(self):
        text = read(ROOT / "telegram-ios/submodules/ContactsPeerItem/Sources/ContactsPeerItem.swift")
        start = text.index("let identityPeer = exteralessIdentityPresentation")
        end = text.index("switch item.status", start)
        block = text[start:end]
        self.assertIn("switch identityDisplayOrder", block)
        self.assertIn("font: item.sortOrder == .firstLast ? titleBoldFont : titleFont", block)
        self.assertIn("font: item.sortOrder == .firstLast ? titleFont : titleBoldFont", block)
        final_filter = "titleAttributedString = titleAttributedString.map { exteralessZalgoDisplayText($0) }"
        self.assertIn(final_filter, block)
        self.assertGreater(block.index(final_filter), block.index("identityPeer.localAlias ?? community.title"))
        projection = read(NATIVE / "ExteralessIdentityPresentation.swift")
        projection = projection[projection.index("public func exteralessIdentityProjection"):projection.index("public func exteralessIdentityActivityBand")]
        self.assertNotIn("exteralessZalgoDisplayText", projection)

    def test_native_fixtures_execute_real_formatting_and_cache_publication(self):
        text = read(ROOT / "telegram-ios/Tests/Exteraless/IdentityRemediationTests.swift")
        for token in ["import LocalizedPeerData", "peer.exteralessDisplayTitle(identity:", "peer.displayTitle(strings:", "peer.exteralessCompactDisplayTitle(identity:", "exteralessZalgoDisplayText(value)", "ExteralessIdentityAccountLease(accountId:", "lease.refreshExpiration()", "cache.begin(account: owner)", "clock.advance(100)"]:
            self.assertIn(token, text)
        for token in ["accountWithId(", "HarnessAccount.make(", ".postbox", "settimeofday", "clock_settime"]:
            self.assertNotIn(token, text)
        self.assertIn("FileManager.default.temporaryDirectory", text)
        self.assertIn("secretStore: IdentityFixtureSecrets()", text)

    def test_pending_display_and_build_patches_have_exact_current_preimages(self):
        for name, allowed in [
            ("identity-remediation-display-remaining.patch", {"telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift", "telegram-ios/submodules/AvatarNode/Sources/PeerAvatar.swift"}),
            ("identity-remediation-build.patch", {"telegram-ios/Tests/Exteraless/BUILD"})
        ]:
            staged = {}
            for path, old, new in patch_hunks(ROOT / "docs/wave-2" / name):
                self.assertIn(path, allowed)
                text = staged.setdefault(path, read(ROOT / path))
                if text.count(new) == 1 and text.replace(new, "").count(old) == 0:
                    continue  # A current owner may already have applied this hunk.
                self.assertEqual(text.count(old), 1, (name, path))
                staged[path] = text.replace(old, new, 1)


if __name__ == "__main__":
    unittest.main()
