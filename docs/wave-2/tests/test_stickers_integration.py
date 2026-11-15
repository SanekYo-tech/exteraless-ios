"""Bounded, read-only receipts for the second sticker source-integration step."""
from __future__ import annotations

import unittest
from test_stickers_contract import ROOT, source, hunks

KEYBOARD = "telegram-ios/submodules/TelegramUI/Components/EntityKeyboard/Sources/"
CHAT_INPUT = "telegram-ios/submodules/TelegramUI/Components/ChatEntityKeyboardInputNode/Sources/ChatEntityKeyboardInputNode.swift"


class StickerIntegrationTests(unittest.TestCase):
    def test_allowed_native_and_gif_hunks_are_applied_once(self):
        allowed = {
            "telegram-ios/submodules/TelegramCore/Sources/State/SynchronizeRecentlyUsedMediaOperations.swift",
            "telegram-ios/submodules/TelegramUI/Components/Chat/ChatEmptyNode/Sources/ChatEmptyNode.swift",
            "telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift",
            "telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift",
            "telegram-ios/submodules/TelegramUI/Sources/HorizontalListContextResultsChatInputContextPanelNode.swift",
        }
        checked = 0
        for path in ["docs/wave-2/stickers-native-hunks.patch", "docs/wave-2/stickers-gif-hunks.patch"]:
            for target, _, new in hunks(path):
                if target in allowed:
                    self.assertEqual(source(target).count(new), 1, (target, new[:80]))
                    checked += 1
        self.assertEqual(checked, 9)

    def test_font_backend_is_after_native_styling_and_has_a_real_empty_probe(self):
        bubble = source("telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift")
        self.assertEqual(bubble.count("attributedString: ExteralessEmojiRendering.shared.attributedText(attributedText, accountId:"), 1)
        self.assertIn("stringWithAppliedEntities", bubble)
        self.assertIn("AITranslationPolicy()", bubble)
        suggestions = source("telegram-ios/submodules/TelegramUI/Sources/EmojisChatInputPanelItem.swift")
        self.assertEqual(suggestions.count("ExteralessEmojiRendering.shared.attributedText"), 1)
        renderer = source("telegram-ios/submodules/Emoji/Sources/EmojiFontRendering.swift")
        support = source("telegram-ios/submodules/Emoji/Sources/EmojiGraphemeSupport.swift")
        self.assertLess(support.index("context.clear(CGRect(x: 0, y: 0, width: 96, height: 96))"), support.index("CTLineDraw(line, context)"))
        self.assertIn("UIFont(name: name, size: 32)", renderer)
        self.assertIn("return fallback", renderer)

    def test_single_favorite_projection_keeps_existing_picker_inputs(self):
        text = source(KEYBOARD + "EmojiPagerContentSignals.swift")
        self.assertEqual(text.count("exteralessLocalFavoriteStickerItems(engine: context.engine)"), 1)
        self.assertEqual(text.count("exteralessStickerPickerFavorites(cloud: cloudFavoriteStickers, local: localFavoriteStickers)"), 1)
        for symbol in ["exteralessRecentStickerItems", "exteralessStickerPolicy", "localRecentStickers", "!stickerPolicy.hideGroupPack", "searchCategories", "peerSpecificPack"]:
            self.assertIn(symbol, text)
        self.assertIn("partialReference: reference.partial", text)
        self.assertIn("fileReference: reference", text)
        self.assertIn('Logger.shared.log("ExteralessFavorites", "Local favorite storage unavailable")', text)
        self.assertGreaterEqual(text.count("guard ExteralessIdentityPresentation.shared.policy.premiumItemStarInReactions"), 3)

    def test_menu_uses_tools_state_and_keeps_the_native_cloud_limit_branch(self):
        text = source(CHAT_INPUT)
        self.assertEqual(text.count("menuItems.append(strongSelf.localFavoriteAction("), 1)
        self.assertEqual(text.count("exteralessSetLocalFavoriteSticker(engine: context.engine, file: file, saved: !isLocal)"), 1)
        self.assertIn("exteralessLocalFavoriteStickers(engine: context.engine)", text)
        self.assertIn("guard let isLocal else", text)
        self.assertIn("return .single(nil)", text)
        self.assertIn("context.engine.stickers.toggleStickerSaved(file: file, saved: !isStarred)", text)
        self.assertIn("case let .limitExceeded(limit, premiumLimit):", text)
        self.assertIn("isLocked && !isStarred", text)

    def test_reference_rebinding_covers_taps_long_press_and_secondary_picker(self):
        model = source(KEYBOARD + "EmojiPagerContentComponent.swift")
        self.assertIn("public let fileReference: FileMediaReference?", model)
        self.assertIn("lhs.fileReference?.abstract != rhs.fileReference?.abstract", model)
        self.assertIn("previous.item.fileReference?.abstract != item.fileReference?.abstract", model)
        self.assertIn("itemLayer.updateItem(item)", model)
        for path in [CHAT_INPUT, "telegram-ios/submodules/TelegramUI/Components/StickerPickerScreen/Sources/StickerPickerScreen.swift"]:
            self.assertIn("if let itemReference = item.fileReference", source(path))
        self.assertIn("pickerReference", source(CHAT_INPUT))
        self.assertIn("$0.withMedia(fileReference.media)", source(CHAT_INPUT))

    def test_projection_is_not_a_second_data_store_and_fixture_has_no_account(self):
        helper = source("telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/ExteralessStickerFavorites.swift")
        self.assertNotRegex(helper, r"\.postbox\b|\.network\b|ValueBoxKey|updatePreferencesEntry|toggleStickerSaved")
        self.assertIn("ToolsFavoriteStickerArchive.maximumPerAccount", helper)
        self.assertIn(".savedSticker(media:", helper)
        self.assertIn(".stickerPack(stickerPack:", helper)
        self.assertIn(".standalone(media:", helper)
        test = source("telegram-ios/Tests/Exteraless/StickerFavoritesIntegrationTests.swift")
        self.assertIn("1...350", test)
        self.assertNotRegex(test, r"\b(?:Account|Postbox|Network)\s*\(|\.start\s*\(|\.startStandalone\s*\(")
        self.assertIn("archive.stickers(for: 1002)", test)

    def test_remaining_owner_hunks_are_exact(self):
        count = 0
        for path in ["docs/wave-2/stickers-integration-common-hunks.patch", "docs/wave-2/stickers-integration-node-hunks.patch", "docs/wave-2/stickers-integration-build-hunks.patch"]:
            for target, old, new in hunks(path):
                text = source(target)
                self.assertTrue(text.count(old) == 1 or text.count(new) == 1, (target, old[:90]))
                count += 1
        self.assertEqual(count, 20)


if __name__ == "__main__":
    unittest.main()
