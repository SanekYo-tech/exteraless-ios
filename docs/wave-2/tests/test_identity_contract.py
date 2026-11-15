"""Bounded, offline integration contracts; not Swift execution or visual proof."""
import json
import hashlib
import re
import runpy
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "swift/ExteralessCore/Sources/ExteralessCore"
NATIVE = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessIdentity"
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Identity"


class IdentitySourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = runpy.run_path(str(ROOT / "docs/wave-2/identity-hunks.py"))
        cls.hunks = cls.generator["build_hunks"]()
        cls.applied = cls.generator["build_hunks"]("allowed")
        cls.joined = "\n".join(cls.hunks.modified.values())
        cls.receipt = json.loads((ROOT / "docs/wave-2/identity-parity.json").read_text(encoding="utf-8"))
        cls.application = json.loads((ROOT / "docs/wave-2/identity-application.json").read_text(encoding="utf-8"))

    def test_exact_original_ownership_defaults_and_sources(self):
        ownership = json.loads((ROOT / "docs/parity/remaining-ownership.json").read_text(encoding="utf-8"))
        ids = {key for package in ownership["unfragmented_packages"] if package["id"] in {"P-local-identity", "P-local-premium"} for key in package["feature_ids"]}
        inventory = json.loads((ROOT / "docs/parity/client-features.json").read_text(encoding="utf-8"))
        originals = {item["id"]: item for item in inventory["features"]}
        rows = self.receipt["features"]
        self.assertEqual(len(rows), 22)
        self.assertEqual({row["id"] for row in rows}, ids)
        for row in rows:
            source = originals[row["id"]]["android"]
            self.assertEqual(row["android"]["default"], source["default"]["value"], row["id"])
            self.assertEqual(row["android"]["symbol"], source["symbol"], row["id"])
            for anchor in row["android"]["effect_sources"]:
                path = ROOT / "third_party/exteraless-android/TMessagesProj/src/main" / anchor["file"]
                self.assertIn(anchor["needle"], path.read_text(encoding="utf-8"), row["id"])

    def test_shared_diff_applies_without_touching_the_working_tree(self):
        self.assertEqual(self.applied.diff(), "", "An allowed insertion is still unapplied")
        self.assertEqual({item["status"] for item in self.applied.anchors}, {"applied"})
        self.assertEqual(set(self.applied.modified), set(self.application["applied_shared_files"]))
        remaining = (ROOT / self.application["remaining_patch"]).read_bytes()
        result = subprocess.run(["git", "apply", "--check", "--whitespace=error", "-"], cwd=ROOT,
            input=remaining, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertTrue(all("BUILD" not in Path(path).name for path in self.hunks.modified))
        self.assertTrue(set(self.applied.modified).isdisjoint(self.generator["RESERVED_FILES"]))

    def test_remaining_hunks_are_uniquely_anchored_and_only_reserved_files(self):
        patch = (ROOT / self.application["remaining_patch"]).read_text(encoding="utf-8")
        path = None
        body = []
        header = None
        paths = set()
        for line in patch.splitlines(True) + ["--- END\n"]:
            if line.startswith(("--- ", "@@ ")):
                if header:
                    source = (ROOT / path).read_text(encoding="utf-8")
                    self.assertEqual(source.count("".join(body)), 1, (path, header))
                body, header = [], None
                if line.startswith("--- a/"):
                    path = line[len("--- a/"):].strip()
                    paths.add(path)
                elif line.startswith("@@ "):
                    header = line
            elif header and line.startswith((" ", "-")):
                body.append(line[1:])
        self.assertEqual(paths, set(self.application["remaining_shared_files"]))

    def test_core_freeze_accounts_for_the_explicit_external_era_fix(self):
        self.assertFalse(self.application["frozen_core_changed_by_identity_application"])
        external = self.application.get("external_core_changes", {})
        self.assertEqual(self.application["frozen_core_changed"], bool(external))
        for path, digest in self.application["frozen_core_sha256"].items():
            if path in external:
                self.assertEqual(external[path]["original_sha256"], digest)
                self.assertTrue(external[path]["ci_input_changed"])
                digest = external[path]["current_sha256"]
            self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), digest, path)

    def test_preferences_are_account_local_and_reset_only_the_owned_row(self):
        store = (NATIVE / "ExteralessIdentityStore.swift").read_text(encoding="utf-8")
        self.assertIn('ValueBoxKey("exteraless.identity.state.v1")', store)
        self.assertIn("engine.account.postbox.transaction", store)
        self.assertIn("try permit.check(owner: owner)", store)
        self.assertIn("IdentityArchive.decode(entry.data, owner: owner)", store)
        keys = re.findall(r"transaction\.updatePreferencesEntry\(key: ([^,]+)", store)
        self.assertTrue(keys)
        self.assertEqual(set(keys), {"exteralessIdentityStateKey"})
        code = re.sub(r"//[^\n]*", "", store)
        for token in ["removeItemCacheCollection(", "removeAllPreferences(", "UserDefaults.", "updatePeers(", "network.request("]:
            self.assertNotIn(token, code)
        for path in UI.glob("*.swift"):
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"(?m)^import Postbox\b", str(path))
            self.assertNotIn(".postbox", text, str(path))

    def test_local_picker_is_a_callback_and_server_peer_capabilities_are_native(self):
        picker = (UI / "ExteralessIdentityColorsController.swift").read_text(encoding="utf-8")
        self.assertIn(".customStatusSelection(completion: completion)", picker)
        self.assertIn(".backgroundSelection(completion:", picker)
        self.assertIn("forceHasPremium: true", picker)
        all_owned = "\n".join(path.read_text(encoding="utf-8") for path in list(UI.glob("*.swift")) + list(NATIVE.glob("*.swift")))
        for token in [".setEmojiStatus(", ".setStarGiftStatus(", ".updateNameColorAndEmoji(", ".updateAccountPeerName(", ".withUpdatedEmojiStatus(", ".withUpdatedNameColor(", ".network.request("]:
            self.assertNotIn(token, all_owned)
        native_peer = ROOT / "telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/Peer.swift"
        peer = native_peer.read_text(encoding="utf-8")
        self.assertIn("var isPremium: Bool {\n        return self._asPeer().isPremium", peer)
        self.assertNotIn(str(native_peer.relative_to(ROOT)).replace("\\", "/"), self.hunks.modified)

    def test_every_registered_display_control_reaches_a_native_consumer(self):
        required = {
            "dateOfForwardedMsg": ["forward.date.suffix", "forward.date.story.exclusion"],
            "idDcType": ["profile.id.dc"],
            "showFullAbout": ["about.trim", "about.lines"],
            "preferCommonGroupsTab": ["profile.common.groups"],
            "showOnlineStatus": ["activity.observed.presence", "activity.autoremove.badge"],
            "usePersianCalendar": ["dates.header.live.refresh", "dates.medium", "dates.last.seen"],
            "displayPersianCalendarByLatin": ["dates.clock.digits", "dates.entity.long"],
            "premiumItemEmojiStatus": ["author.emoji.status", "author.premium.badge"],
            "premiumItemEmojiInReplies": ["reply.emoji", "attached.pattern", "contact.pattern"],
            "premiumItemCustomColorInReplies": ["reply.project", "attached.project", "contact.project"],
            "premiumItemCustomWallpaper": ["wallpaper.presentation"],
            "premiumItemVideoAvatar": ["list.video.avatar", "nav.video.eligibility", "profile.video.avatar"],
            "premiumItemStarInReactions": ["paid.reactions.values", "paid.footer.values", "paid.menu", "paid.emoji.pager"],
            "premiumItemStickerEffects": ["sticker.effects", "emoji.effects", "emoji.effects.queued", "message.effects"],
            "premiumItemBoosts": ["boosts.measure", "boosts.apply"],
        }
        anchors = {anchor["id"] for anchor in self.hunks.anchors}
        for field, uses in required.items():
            for use in uses:
                self.assertIn(use, anchors, field)
        self.assertIn("identityRevision", self.joined)
        self.assertIn("previousDateTimeFormat != presentationData.dateTimeFormat", self.joined)

    def test_calendar_conversion_does_not_reinterpret_wire_or_partial_dates(self):
        path = "telegram-ios/submodules/TelegramStringFormatting/Sources/DateFormat.swift"
        original = subprocess.run(["git", "show", "HEAD:" + path], cwd=ROOT, capture_output=True, timeout=10, check=True)
        old = original.stdout.decode("utf-8").replace("\r\n", "\n")
        new = (ROOT / path).read_text(encoding="utf-8")
        def part(text, start, end=None):
            value = text[text.index(start):]
            return value if end is None else value[:value.index(end)]
        self.assertEqual(part(old, "public func getDateTimeComponents", "public func stringForMediumCompactDate"),
                         part(new, "public func getDateTimeComponents", "public func stringForMediumCompactDate"))
        self.assertEqual(part(old, "public func roundDateToDays"), part(new, "public func roundDateToDays"))
        policy = (CORE / "IdentityDatePolicy.swift").read_text(encoding="utf-8")
        self.assertIn("Calendar(identifier: .persian)", policy)
        self.assertIn("Self.components(at: date, timeZone: timeZone) == value", policy)
        self.assertIn("persianRange(from:", self.joined)
        self.assertNotIn("year - 621", policy)

    def test_actual_contact_payload_and_font_paths_keep_native_data(self):
        contact = (ROOT / "telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift").read_text(encoding="utf-8")
        self.assertIn("firstName: selectedContact.firstName, lastName: selectedContact.lastName", contact)
        self.assertNotIn("identityContact?.name { displayName", contact)
        rows = (ROOT / "telegram-ios/submodules/ContactsPeerItem/Sources/ContactsPeerItem.swift").read_text(encoding="utf-8")
        self.assertIn("if let name = identityPeer.localAlias", rows)
        self.assertIn("switch identityDisplayOrder", rows)
        self.assertIn("font: item.sortOrder == .firstLast ? titleBoldFont : titleFont", rows)

    def test_actual_native_helper_calls_resolve_to_declared_functions(self):
        paths = [ROOT / path for path in self.application["applied_shared_files"]] + list(NATIVE.glob("*.swift")) + list(UI.glob("*.swift"))
        text = "\n".join(path.read_text(encoding="utf-8") for path in paths)
        names = r"(?:exteralessIdentity\w*|exteralessDisplayTitle|exteralessCompactDisplayTitle)"
        calls = set(re.findall(r"\b(" + names + r")\s*\(", text))
        definitions = set(re.findall(r"\bfunc\s+(" + names + r")\s*\(", text))
        self.assertEqual(calls - definitions, set())
        account_ui = (UI / "ExteralessIdentityController.swift").read_text(encoding="utf-8")
        self.assertIn("IdentityArchive.encode(state)", account_ui)
        self.assertIn("UIActivityViewController(activityItems:", account_ui)
        self.assertIn("exteralessUpdateIdentity(engine: context.engine", account_ui)

    def test_forward_ranges_and_avatar_video_markup_keep_native_semantics(self):
        self.assertIn("NSRange(location: leftPart.utf16.count, length: peerString.utf16.count)", self.joined)
        self.assertIn("StoryData(storyType: storyType), nil, CGSize", self.joined)
        video = self.hunks.modified["telegram-ios/submodules/AvatarVideoNode/Sources/AvatarVideoNode.swift"]
        self.assertIn("self.animationNode?.visibility = isVisible", video)
        self.assertIn("self.videoItemLayer?.isVisibleForAnimations = showsVideo", video)
        self.assertIn("self.videoItemLayer?.isHidden = !showsVideo", video)

    def test_receipts_distinguish_applied_consumers_from_pending_registration(self):
        self.assertFalse(self.receipt["verification"]["visual_pass"])
        self.assertEqual(self.receipt["integration"]["state"], "source-applied-with-reserved-integration-remaining")
        anchors = {anchor["id"]: anchor for anchor in self.hunks.anchors}
        for feature in self.receipt["features"]:
            self.assertFalse(feature["implementation"]["ported"])
            self.assertTrue(feature["ios"]["prepared_hunks"])
            self.assertTrue(set(feature["ios"]["prepared_hunks"]).issubset(anchors), feature["id"])
            for callsite in feature["ios"]["implementation_callsites"]:
                self.assertEqual(anchors[callsite["hunk"]]["status"], "applied", feature["id"])
                self.assertTrue((ROOT / callsite["path"]).is_file())
            for pending in feature["ios"]["remaining_hunks"]:
                self.assertIn(anchors[pending]["file"], self.generator["RESERVED_FILES"])
            for evidence in feature["implementation"]["evidence"]:
                self.assertTrue((ROOT / evidence["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
