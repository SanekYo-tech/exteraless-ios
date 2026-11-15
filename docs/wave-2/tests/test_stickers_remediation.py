"""IDS-06/07/08 bounded source/fixture checks; never executes Swift/CoreText."""
import base64
import hashlib
import re
import struct
import unittest
from test_stickers_contract import ROOT, source

CORE = "swift/ExteralessCore/Sources/ExteralessCore/"
NATIVE = "telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/"
FONT = "telegram-ios/submodules/Emoji/Sources/"
FIXTURE = "swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontFixture.swift"


def sfnt_tables(data):
    count = struct.unpack_from(">H", data, 4)[0]
    result = {}
    for index in range(count):
        tag, expected, offset, length = struct.unpack_from(">4sIII", data, 12 + 16 * index)
        assert offset + length <= len(data)
        value = bytearray(data[offset:offset + length])
        if tag == b"head":
            value[8:12] = b"\0" * 4
        value += b"\0" * (-len(value) % 4)
        assert sum(struct.unpack(">" + "I" * (len(value) // 4), value)) & 0xffffffff == expected
        result[tag] = data[offset:offset + length]
    assert sum(struct.unpack(">" + "I" * (len(data) // 4), data)) & 0xffffffff == 0xb1b0afba
    return result


class StickerRemediationSourceTests(unittest.TestCase):
    def test_review_remains_immutable(self):
        path = ROOT / "docs/wave-2/reviews/identity-dialogs-stickers.md"
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), "78a52ae89033c4d76574cc33d8127fe831c33c33e097a32a33762ffd49dcbeae")

    def test_mixed_review_fonts_are_pinned_with_real_nonzero_blank_mapping(self):
        fixture = source(FIXTURE)
        for suffix, size, digest in [
            ("mixed", 968, "3d8c2e9912be9ff1ffabee9f71feb51687b82d0f00535b1b22b20492736fd1ea"),
            ("mixedThumb", 980, "4361f295dc49f86262e9143620ec5489a5e933e6791caf8d3ed31aaffe5a8c67"),
        ]:
            data = base64.b64decode(re.search(r'static let ' + suffix + r'Base64 = "([^"]+)"', fixture)[1], validate=True)
            self.assertEqual(len(data), size)
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
            tables = sfnt_tables(data)
            self.assertEqual(struct.unpack_from(">H", tables[b"maxp"], 4)[0], 3)
            self.assertEqual(struct.unpack_from(">H", tables[b"hhea"], 34)[0], 3)
            self.assertEqual(len(tables[b"hmtx"]), 12)
            offsets = struct.unpack(">4I", tables[b"loca"])
            self.assertEqual(offsets, (0, 12, 48, 60))
            self.assertEqual(struct.unpack_from(">h", tables[b"glyf"], offsets[1])[0], 1)
            self.assertEqual(struct.unpack_from(">h", tables[b"glyf"], offsets[2])[0], 0)
            mappings = [struct.unpack_from(">III", tables[b"cmap"], offset) for offset in range(28, len(tables[b"cmap"]), 12)]
            self.assertIn((0x1f600, 0x1f600, 1), mappings)
            self.assertIn((0x1f609, 0x1f609, 2), mappings)
            if suffix == "mixedThumb": self.assertIn((0x1f44d, 0x1f44d, 1), mappings)
            self.assertIn("CC0-1.0".encode("utf-16-be"), tables[b"name"])

    def test_recents_use_new_policy_and_gif_adapter_is_byte_unchanged(self):
        policy = source(CORE + "StickerPolicy.swift")
        self.assertIn("public static func recent<", policy)
        self.assertIn("for items in [cloud, local]", policy)
        collections = source(NATIVE + "ExteralessStickerCollections.swift")
        recents, gif = collections.split("public func exteralessSavedGifItems", 1)
        self.assertIn("_internal_exteralessRecentStickerItems", recents)
        self.assertEqual(recents.count("StickerCollectionPolicy.recent("), 2)
        self.assertNotIn("StickerCollectionPolicy.merged(", recents)
        gif = "public func exteralessSavedGifItems" + gif.split("public enum ExteralessSavedGifResult", 1)[0]
        self.assertEqual(hashlib.sha256(gif.encode()).hexdigest(), "c498e8460f38509a94b40ab6de447420386a501417186d6e2d0d795bf22ff1fd")
        tests = source("swift/ExteralessCore/Tests/ExteralessCoreTests/StickerPolicyTests.swift")
        self.assertNotIn("testRecentsMergeKeepsLocalOrder", tests)
        self.assertIn("testGifShelfStillKeepsLocalOrderAndRefreshesReferences", tests)
        native = source("telegram-ios/submodules/TelegramCore/Tests/ExteralessStickerReviewTests.swift")
        for required in ["[20, 21, 200]", "[999] + Array(1...19)", "_internal_exteralessRecentStickerItems", "_internal_removeRecentlyUsedSticker", "_internal_clearRecentlyUsedStickers", "inMemory: true"]:
            self.assertIn(required, native)

    def test_policy_reread_and_publication_are_queued_and_disposable(self):
        text = source(NATIVE + "ExteralessStickerSettings.swift")
        callback = text.split("let observation = settings.observe", 1)[1].split("// Register", 1)[0]
        self.assertNotIn("putNext", callback)
        self.assertNotIn("snapshot", callback)
        block = text.split("self.queue.justDispatch {", 1)[1]
        self.assertLess(block.index("let value = StickerPolicy(settings:"), block.index("self.subscriber.putNext(value)"))
        self.assertEqual(block.count("guard !self.disposed.with"), 2)
        self.assertIn("!self.pending.swap(true)", text)
        self.assertNotIn("self.queue.async", text)
        native = source("telegram-ios/submodules/TelegramCore/Tests/ExteralessStickerReviewTests.swift")
        for required in ["testLateOldReadCannotPublishAfterNewTrue", "testInitialReadUsesLatestValueAndResetIsPublished", "testDisposeWhileReadIsPaused", "testSubscriberWriteIsQueuedInsteadOfReentrant", "DispatchQueue.global().async"]:
            self.assertIn(required, native)
        self.assertNotRegex(native, r"\bAccount\s*\(|\bNetwork\s*\(")

    def test_all_font_use_paths_share_bounded_visible_grapheme_decisions(self):
        renderer = source(FONT + "EmojiFontRendering.swift")
        support = source(FONT + "EmojiGraphemeSupport.swift")
        self.assertIn("return self.graphemes.supports(text)", renderer)
        self.assertGreaterEqual(renderer.count("face.supports("), 3)
        self.assertIn("private static let capacity = 256", support)
        self.assertIn("self.decisions.removeValue(forKey: self.insertionOrder.removeFirst())", support)
        self.assertIn("self.decisions[text] = value", support)
        self.assertIn("CTRunGetGlyphCount(run) == 1", support)
        self.assertIn("self.hasVariation(base:", support)
        self.assertLess(support.index("context.clear("), support.index("CTLineDraw("))
        native = source("telegram-ios/Tests/Exteraless/StickerEmojiRenderingTests.swift")
        for required in ["testMixedVisibleAndNonzeroBlankGlyph", "testPartialZWJVariationAndSkinTone", "testDecisionChurnAndRetainedUIFont", "rawWink", "CTLineDraw"]:
            self.assertIn(required, native)


if __name__ == "__main__":
    unittest.main()
