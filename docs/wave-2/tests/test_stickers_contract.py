"""Read-only source/fixture handoff checks. These do not run or compile Swift."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def hunks(path: str):
    target, old, new = None, [], []
    for line in source(path).splitlines():
        if line.startswith("*** Update File: ") or line == "@@" or line == "*** End Patch":
            if old or new:
                yield target, "\n".join(old), "\n".join(new)
                old, new = [], []
            if line.startswith("*** Update File: "):
                target = line.split(": ", 1)[1]
        elif target and line.startswith((" ", "+", "-")):
            if line[0] != "+":
                old.append(line[1:])
            if line[0] != "-":
                new.append(line[1:])


class StickerHandoffTests(unittest.TestCase):
    def test_exact_original_id_coverage_and_fragment_merge(self):
        from tools.compat.feature_inventory import merge_parity

        inventory = json.loads(source("docs/parity/client-features.json"))
        ownership = json.loads(source("docs/parity/remaining-ownership.json"))
        fragment = json.loads(source("docs/wave-2/stickers-parity.json"))
        ids = set(next(p for p in ownership["unfragmented_packages"] if p["id"] == "P-stickers-emoji")["feature_ids"])
        own = {item["id"] for item in fragment["features"]}
        delegated = {item["id"] for item in fragment["delegated_features"]}
        self.assertEqual(len(ids), 21)
        self.assertEqual(own | delegated, ids)
        self.assertFalse(own & delegated)
        self.assertEqual({item["id"] for item in fragment["coverage"]}, ids)
        self.assertEqual(delegated, {"chats.stickerShape", "chats.stickerTimeSide", "neko.hideTimeForSticker"})
        merged = merge_parity(inventory, fragments=[fragment])
        self.assertFalse(any(item["implementation"]["ported"] for item in merged["features"] if item["id"] in own))
        originals = {item["id"]: item for item in inventory["features"]}
        for item in fragment["coverage"]:
            self.assertEqual(item["android_default"], originals[item["id"]]["android"]["default"]["value"])
            for test in item["tests"]:
                self.assertIn(test["symbol"], source(test["path"]))
        for item in fragment["features"]:
            for call in item.get("ios", {}).get("implementation_callsites", []):
                self.assertNotIn("docs/", call["path"])
                self.assertIn(call["symbol"], source(call["path"]).splitlines()[call["line"] - 1])
            for evidence in item["implementation"]["evidence"]:
                self.assertTrue((ROOT / evidence["path"]).is_file())

    def test_all_coordinator_hunks_have_unique_current_source_anchors(self):
        total = 0
        for path in ["docs/wave-2/stickers-native-hunks.patch", "docs/wave-2/stickers-gif-hunks.patch", "docs/wave-2/stickers-build-hunks.patch"]:
            for target, old, new in hunks(path):
                with self.subTest(path=path, target=target, anchor=old[:70]):
                    text = source(target)
                    self.assertTrue(old)
                    # A coordinator may have applied a hunk while the owner is
                    # checking the rest; recognize a complete already-applied hunk.
                    self.assertTrue(text.count(old) == 1 or text.count(new) == 1, (target, text.count(old), text.count(new)))
                    total += 1
        self.assertGreaterEqual(total, 25)

    def test_fixture_is_pinned_licensed_sfnt_with_nonempty_emoji_glyph(self):
        text = source("swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontFixture.swift")
        data = base64.b64decode(re.search(r'static let base64 = "([^"]+)"', text)[1], validate=True)
        digest = re.search(r'static let sha256 = "([^"]+)"', text)[1]
        self.assertEqual(len(data), 936)
        self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        count = struct.unpack_from(">H", data, 4)[0]
        tables = {}
        for i in range(count):
            tag, checksum, offset, size = struct.unpack_from(">4sIII", data, 12 + 16 * i)
            self.assertLessEqual(offset + size, len(data))
            table = bytearray(data[offset:offset + size])
            if tag == b"head":
                table[8:12] = b"\0" * 4
            padded = table + b"\0" * (-len(table) % 4)
            self.assertEqual(sum(struct.unpack(">" + "I" * (len(padded) // 4), padded)) & 0xFFFFFFFF, checksum)
            tables[tag] = (offset, size)
        self.assertEqual(count, 10)
        self.assertEqual(sum(struct.unpack(">" + "I" * (len(data) // 4), data)) & 0xFFFFFFFF, 0xB1B0AFBA)
        cmap = tables[b"cmap"][0]
        self.assertEqual(struct.unpack_from(">III", data, cmap + 28), (0x1F600, 0x1F600, 1))
        self.assertEqual(struct.unpack_from(">h", data, tables[b"glyf"][0] + 12)[0], 1)
        self.assertIn("CC0-1.0".encode("utf-16-be"), data)

    def test_boundaries_and_actual_native_consumers(self):
        for path in (ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Stickers").glob("*.swift"):
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"\bimport\s+(?:Postbox|TelegramApi)\b|\.postbox\b")
        for path in (ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers").glob("*.swift"):
            self.assertNotRegex(path.read_text(encoding="utf-8"), r"\bimport\s+(?:UIKit|Display)\b")
        core = source("swift/ExteralessCore/Sources/ExteralessCore/StickerFeatures.swift")
        for field in ["stickerShape", "stickerTimeSide", "hideTimeForSticker", "unlimitedFavedStickers", "useCustomEmoji"]:
            self.assertNotIn('"chats.' + field + '"', core)
        network = source("telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/ExteralessEmojiPackSource.swift")
        for call in ["engine.peers.resolvePeerByName", "engine.messages.searchMessages", "engine.messages.getMessagesLoadIfNecessary", "engine.resources.fetch", "engine.resources.data"]:
            self.assertIn(call, network)
        self.assertNotIn("joinChannel", network)
        renderer = source("telegram-ios/submodules/Emoji/Sources/EmojiFontRendering.swift")
        for call in ["CTFontManagerRegisterGraphicsFont", "UIFont(name:", "hasVisibleProbe", "self.owner == owner", "self.graphemes.supports(text)"]:
            self.assertIn(call, renderer)
        self.assertIn("CTLineDraw(line, context)", source("telegram-ios/submodules/Emoji/Sources/EmojiGraphemeSupport.swift"))
        picker = source("telegram-ios/submodules/TelegramUI/Components/ChatEntityKeyboardInputNode/Sources/ChatEntityKeyboardInputNode.swift")
        for call in ["exteralessPrepareEmojiSticker", "sendSticker(.standalone(media: uploaded)", "exteralessToggleGifSaved", "!policy.hideChoosingActivity"]:
            self.assertIn(call, picker)
        groups = source("telegram-ios/submodules/TelegramUI/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift")
        for call in ["policy.hideTrending", "stickerPolicy.compactCreator", "!stickerPolicy.hideGroupPack", "for item in localRecentStickers"]:
            self.assertIn(call, groups)
        self.assertIn("interaction?.openStickerEditor()", picker)
        self.assertIn("exteralessPinnedReactionItems(engine: context.engine", source("telegram-ios/submodules/TelegramUI/Components/Chat/TopMessageReactions/Sources/TopMessageReactions.swift"))

    def test_native_tests_cannot_contact_account_network(self):
        for path in ["telegram-ios/Tests/Exteraless/StickerEmojiRenderingTests.swift", "swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontHTTPTests.swift"]:
            text = source(path)
            self.assertNotRegex(text, r"\b(?:Account|TelegramEngine)\s*\(")
        http = source("swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontHTTPTests.swift")
        self.assertIn("configuration.protocolClasses = [EmojiFontURLProtocol.self]", http)
        self.assertIn('url.host?.hasSuffix(".invalid") == true', http)
        self.assertIn("override class func canInit(with request: URLRequest) -> Bool { true }", http)


if __name__ == "__main__":
    unittest.main()
