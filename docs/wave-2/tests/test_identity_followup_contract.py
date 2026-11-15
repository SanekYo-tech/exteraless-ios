"""IDSF-01/02 source/dataflow contracts. Does not execute Swift or a live account."""
import re
import subprocess
import unittest
from pathlib import Path

from test_identity_remediation_contract import patch_hunks

ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessIdentity"
CONTACT = ROOT / "telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift"
APPEARANCE = ROOT / "telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift"
FIXTURE = ROOT / "telegram-ios/Tests/Exteraless/IdentityRemediationTests.swift"


def read(path):
    return path.read_text(encoding="utf-8")


class IdentityFollowupContracts(unittest.TestCase):
    def test_contact_payload_alias_order_filter_and_initials_form_one_plan(self):
        text = read(NATIVE / "ExteralessIdentityContactPresentation.swift")
        self.assertIn("first: contact.firstName, last: contact.lastName", text)
        self.assertIn("alias: alias, order: state?.nameOrder ?? .firstLast", text)
        self.assertIn("let filtered = exteralessZalgoDisplayText(composed)", text)
        self.assertIn("initials: IdentityNamePolicy.initials(name)", text)
        self.assertLess(text.index("let filtered ="), text.index("initials: IdentityNamePolicy.initials(name)"))
        self.assertNotIn("guard alias != nil", text)
        self.assertNotRegex(text, r"peer\.(firstName|lastName)|user\.(firstName|lastName)")
        for token in [".postbox", "updatePeers(", "withUpdatedName", "network.request("]:
            self.assertNotIn(token, text)

    def test_actual_contact_node_passes_the_plan_to_title_and_custom_letters(self):
        text = read(CONTACT)
        self.assertIn("var namePresentation = exteralessIdentityContactPresentation(account: item.context.account", text)
        self.assertIn("contact: selectedContact, peer: contactPeer", text)
        self.assertIn("displayName = namePresentation.name", text)
        self.assertIn("titleString = NSAttributedString(string: displayName", text)
        self.assertIn("let customLetters = contactNamePresentation?.initials ?? []", text)
        self.assertIn("strongSelf.avatarNode.setCustomLetters(customLetters)", text)
        self.assertIn("if let peer = contactNamePresentation?.avatarPeer", text)
        self.assertIn("peer: peer, overrideLetters: customLetters", text)
        self.assertIn("fallbackName: contactData.organization", text)
        self.assertNotIn("displayName = contactData.organization", text)
        self.assertGreater(text.index("contactNamePresentation = namePresentation"), text.index("updatedContactInfo = info"))
        self.assertNotIn("selectedContact.peerId == nil", text)
        self.assertNotIn("firstName.index(after:", text)
        self.assertNotIn("lastName.index(after:", text)

    def test_associated_avatar_keeps_original_peer_and_accepts_final_contact_initials(self):
        text = read(NATIVE / "ExteralessIdentityContactPresentation.swift")
        self.assertIn("let avatarPeer = peer.flatMap { $0.id == contact.peerId ? $0 : nil }", text)
        avatar = ROOT / "telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift"
        staged = read(avatar)
        for path, old, new in patch_hunks(ROOT / "docs/wave-2/identity-followup-avatar-letters.patch"):
            self.assertEqual(ROOT / path, avatar)
            if staged.count(new) == 1 and staged.replace(new, "").count(old) == 0:
                continue
            self.assertEqual(staged.count(old), 1, path)
            staged = staged.replace(old, new, 1)
        self.assertEqual(staged.count("overrideLetters: [String]? = nil"), 2)
        self.assertIn("overrideLetters: overrideLetters", staged)
        self.assertIn("let displayLetters = overrideLetters ?? (identity?.letters ?? peer?.displayLetters ?? []).map", staged)
        self.assertIn("identity?.nameColor, displayLetters, representation, clipStyle", staged)
        self.assertIn("letters: displayLetters, font: self.font", staged)

    def test_zalgo_semantic_change_advances_revision_when_identity_policy_is_equal(self):
        text = read(NATIVE / "ExteralessIdentityPresentation.swift")
        self.assertIn('keys.contains("privacy.zalgoFilter")', text)
        self.assertIn('values["privacy.zalgoFilter"]', text)
        self.assertIn("let changed = policyValue != value || zalgoFilterValue != zalgoFilter", text)
        self.assertIn("zalgoFilterValue = zalgoFilter", text)
        self.assertIn("if changed { invalidate() }", text)
        self.assertIn("revisionValue &+= 1", text)
        self.assertIn("NotificationCenter.default.post(name: IdentityFeatures.presentationChanged", text)

    def test_existing_cheap_appearance_adapter_receives_the_identity_notification(self):
        text = read(APPEARANCE)
        self.assertIn("let _ = ExteralessIdentityPresentation.shared", text)
        self.assertIn("forName: IdentityFeatures.presentationChanged", text)
        self.assertIn("return combineLatest(queue: .mainQueue(), native, updates)", text)
        self.assertIn("dateTimeFormat: dateTimeFormat()", text)
        for token in ["makePresentationTheme(", "themeSettingsSignal(", "FileManager", ".postbox"]:
            self.assertNotIn(token, text)

    def test_native_fixture_uses_actual_payload_and_actual_live_presentation_stream(self):
        text = read(FIXTURE)
        matrix = text[text.index("func testContactPresentationFiltersPayloadAliasOrder"):text.index("func testContactPresentationKeeps")]
        for token in ["TelegramMediaContact(", "exteralessIdentityContactPresentation(owner:", "for hasPeerId in [false, true]", "for hasCachedPeer in [false, true]", "for aliasMode in 0...2", "IdentityNameOrder.firstLast, .lastFirst", "for enabled in [false, true]", "result.initials", "contact.vCardData"]:
            self.assertIn(token, matrix)
        live = text[text.index("func testZalgoFlagAloneRefreshesStableNativePresentationNamesAndInitials"):]
        for token in ["let stable = defaultPresentationData()", "exteralessAppearancePresentationData(native: native, updates: exteralessAppearanceUpdates()", "runtime.formattingSnapshot", "runtime.changes.start", "XCTAssertEqual(nativeLoads, 1", "XCTAssertEqual(received.count, 5)", 'settings.reset("privacy.zalgoFilter")', "XCTAssertEqual(runtime.policy, policy", "current.dateTimeFormat.identityRevision", "peerInitials.append(renderedPeerContact.initials)"]:
            self.assertIn(token, live)
        for token in ["runtime.invalidate()", "NotificationCenter.default.post", "accountWithId(", "HarnessAccount.make("]:
            self.assertNotIn(token, live)

    def test_green_expiry_driver_and_its_nine_tests_are_unchanged(self):
        paths = ["swift/ExteralessCore/Sources/ExteralessCore/IdentityExpiryTimer.swift", "swift/ExteralessCore/Tests/ExteralessCoreTests/IdentityExpiryTimerTests.swift"]
        result = subprocess.run(["git", "diff", "--exit-code", "7d04a35a", "--"] + paths,
            cwd=ROOT, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", errors="replace"))
        self.assertEqual(len(re.findall(r"func test\w+\(", read(ROOT / paths[1]))), 9)


if __name__ == "__main__":
    unittest.main()
