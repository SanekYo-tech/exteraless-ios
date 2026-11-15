"""Read-only Chat2 receipt/reference audit. No build, account, plugin or network access."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.compat.feature_inventory import merge_parity

CORE = "swift/ExteralessCore/Sources/ExteralessCore/"
SUB = "telegram-ios/submodules/"
UI = SUB + "TelegramUI/"
CHAT = UI + "Sources/ExteralessClient/Chats/"
COMP = UI + "Components/Chat/"
PANEL = COMP + "ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
STATUS = COMP + "ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift"
COMMON = "docs/wave-2/chat-phase2-common.md"
MEDIA_LEDGER = "docs/wave-2/chat-media-ledger.md"
ANDROID = "third_party/exteraless-android/TMessagesProj/src/main/"
MEDIA_IDS = "chats.hdrPhotos chats.translateInSheet chats.unmuteWithVolumeButtons nagram.defaultHlsVideoQuality nagram.disableChannelMuteButton nagram.disableInAppBrowserGestures nagram.disablePreviewVideoSoundShortcut nagram.hideReactions nagram.messageColoredBackground nagram.sendMp4DocumentAsVideo nagram.showSmallGIF neko.autoPauseVideo neko.takeGIFasVideo".split()
PLAYBACK_IDS = "chats.doubleTapSeekDuration chats.pauseOnMinimizeRound chats.pauseOnMinimizeVoice chats.preferOriginalQuality nagram.dontAutoPlayNextVoice neko.disableProximityEvents".split()


def anchor(path, needle):
    lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
    matches = [i + 1 for i, line in enumerate(lines) if needle in line]
    if not matches:
        raise AssertionError(f"Missing source anchor: {path}: {needle}")
    return {"path": path, "line": matches[0]}


def build_fragment():
    records = {}

    def add(ids, path, needle=None, adaptation=None, live=True, status="partial", key=True, additional=()):
        for feature_id in ids.split():
            field = feature_id.split(".", 1)[1]
            point = anchor(path, (needle or '"chats.{field}"').format(field=field))
            points = [point] + [anchor(p, n.format(field=field)) for p, n in additional]
            detailed = not live or field.startswith("defaultDelete") or feature_id in MEDIA_IDS + PLAYBACK_IDS or feature_id in {"chats.stripTrackingOnOpen", "chats.stripTrackingOnPaste", "nagram.silentMessageByDefault", "nagram.doubleTapAction", "nagram.doubleTapActionOut", "nagram.combineMessage", "nagram.chatMenuItemDeleteOwnMessages", "nagram.showSendAsUnderMessageHint", "nagram.groupedMessageMenu", "neko.disableLinkPreviewByDefault", "nagram.showTextTranslate"}
            records[feature_id] = {
                "id": feature_id,
                "ios": {"setting_key": key if isinstance(key, str) else ("chats." + field if key else None),
                        "implementation_callsites": points if live else [],
                        "adaptation": adaptation if detailed and adaptation else "Native source; adaptation and pending checks: docs/wave-2/chat.md."},
                "implementation": {"status": status, "ported": False,
                                   "evidence": [] if live else [dict(kind="source", **p) for p in points]},
            }

    # Only explicitly transferred Feed/Appearance-Player/Pill/Dialog IDs are omitted.
    # These six original playback IDs never transferred to the Player owner.
    video = SUB + "GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift"
    playback = UI + "Sources/SharedMediaPlayer.swift"
    add("chats.doubleTapSeekDuration", video, adaptation="Original persisted 0...3 indexes select 5/10/15/30 seconds at the actual native gallery double-tap seek. Native bounds retained; baseline receipt restored, not a new runtime pass.")
    add("chats.pauseOnMinimizeRound chats.pauseOnMinimizeVoice", playback, adaptation="Actual native foreground and new-playlist-item paths call shouldPauseInBackground for instantVideo/voice respectively. Baseline receipt restored; account playback not executed.", additional=[(playback, "if self.shouldPauseInBackground(type:")])
    add("chats.preferOriginalQuality", video, adaptation="Native first available quality selects highest through ChatMediaPolicy; explicit viewer selection cancels pending defaults. Highest available is the native adaptation for the original rendition; baseline receipt restored.")
    add("nagram.dontAutoPlayNextVoice", playback, adaptation="Native playback-completed branch stops non-music rather than advancing automatically. Manual queue navigation remains available; baseline receipt restored.")
    add("neko.disableProximityEvents", UI + "Sources/MediaManager.swift", adaptation="Native voice-player construction conjoins this flag with Raise to Listen before enabling proximity control. Applies to new playback sessions; baseline receipt restored.")
    for feature_id in PLAYBACK_IDS:
        records[feature_id]["implementation"]["evidence"] = [dict(kind="source", **point) for point in records[feature_id]["ios"]["implementation_callsites"]]
        records[feature_id]["implementation"]["evidence"].append(dict(kind="source", **anchor("swift/ExteralessCore/Tests/ExteralessCoreTests/ChatPhase2PolicyTests.swift", "func testBaselineFeedPlayerPillWritesStillRegisterAndPersist")))

    add("chats.hdrPhotos", SUB + "GalleryUI/Sources/ExteralessHDRPhoto.swift", adaptation="Original photo resource is decoded with UIImageReader HDR preference and bounded 4096px thumbnail, rendered by UIImageView under the native zoom/capture-protection parent. iOS 17+/HDR image required; off uses native SDR. Device/frames pending.", additional=[(SUB + "GalleryUI/Sources/Items/ChatImageGalleryItem.swift", "self.exteralessHDRPhoto = ExteralessHDRPhoto")])
    add("chats.translateInSheet", CHAT + "ExteralessChatTranslation.swift", adaptation="Native rich translation sheet, current source capability/account lease, selected AI provider; excludes poll/voice/already-translated sources. Double-tap is connected; ordinary AI-message entry hunk is in chat-media-shared.patch.", additional=[(CHAT + "ExteralessMessageGestures.swift", "if exteralessPresentMessageTranslationSheet")])
    add("chats.unmuteWithVolumeButtons", ANDROID + "java/org/telegram/ui/LaunchActivity.java", "ChatsConfig.INSTANCE.unmuteWithVolumeButtons()", live=False, status="unsupported", key=False, adaptation="Android-only consumed non-repeated volume KeyEvent ACTION_DOWN outside VoIP/viewer/sheets. No public iOS general-chat equivalent can consume that hardware event instead of changing volume. No native toggle or outputVolume-observer substitute.", additional=[(MEDIA_LEDGER, "**Android hardware-KeyEvent disposition.**")])
    add("nagram.defaultHlsVideoQuality", video, adaptation="Only legacy value 1 migrates to preferOriginalQuality=true and selector 0. Original 2...5 quality bands/fallthrough have an actual native gallery consumer; highest preference and explicit viewer choices take precedence. Source archive migration helper is ready; Cloud insertion in chat-media-shared.patch pending.", additional=[(CORE + "ChatMediaPolicy.swift", "public static func videoQuality"), (CORE + "ChatLegacyPreferenceMigration.swift", 'preferences["DefaultHlsVideoQuality"]')])
    add("nagram.disableChannelMuteButton", COMP + "ChatChannelSubscriberInputPanelNode/Sources/ChatChannelSubscriberInputPanelNode.swift", '"chats.bottomButton"', key="chats.bottomButton", adaptation="Source-defined bidirectional bridge to bottomButton=0; existing native channel panel consumes that canonical control. No independent alias switch. Exact source archive projection and tests ready; Cloud insertion pending.", additional=[(CORE + "ChatLegacyPreferenceMigration.swift", 'preferences["DisableChannelMuteButton"]')])
    add("nagram.disableInAppBrowserGestures", SUB + "BrowserUI/Sources/ExteralessBrowserGestures.swift", adaptation="Live WebKit back/forward gesture gate plus enclosing Browser interactive navigation/dismiss gate; native toolbar and page scrolling retained. Native compilation/gesture frames pending.", additional=[(SUB + "BrowserUI/Sources/BrowserScreen.swift", '"chats.disableInAppBrowserGestures"')])
    add("nagram.disablePreviewVideoSoundShortcut", ANDROID + "kotlin/xyz/nextalone/nagram/NaConfig.kt", "val disablePreviewVideoSoundShortcut =", live=False, status="unsupported", key=False, adaptation="Source-storage-only preference (default true): exact Java/Kotlin references are declaration and settings row, with no operational consumer. Distinct from unmuteWithVolumeButtons; no invented native shortcut/control or compatibility-storage completion.", additional=[(ANDROID + "java/tw/nekomimi/nekogram/settings/NekoChatSettingsActivity.java", "getDisablePreviewVideoSoundShortcut()")])
    add("nagram.hideReactions", STATUS, 'field = "hideReactionsInChannels"', key=False, adaptation="Legacy true fans out to chats.hideReactionsInChannels/Groups/Private and resets old flag false. Existing reaction consumers use those canonical flags; no fourth switch. Source archive projection/tests ready; Cloud insertion pending.", additional=[(CORE + "ChatLegacyPreferenceMigration.swift", 'preferences["HideReactions"]'), (COMP + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift", "exteralessHideMessageReactions")])
    add("nagram.messageColoredBackground", COMP + "ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift", '"chats.replyBackground"', key="chats.replyBackground", adaptation="Only legacy false migrates to replyBackground=false then resets the legacy flag true. Native reply renderer consumes canonical value; no inverse duplicate toggle. Source archive projection/tests ready; Cloud insertion pending.", additional=[(CORE + "ChatLegacyPreferenceMigration.swift", 'preferences["MessageColoredBackground"]')])
    add("nagram.sendMp4DocumentAsVideo", CHAT + "ExteralessMP4Document.swift", adaptation="Default true. Native asset and Files pickers attach validated MP4 Video metadata while retaining resources, caption/entities/paid/spoiler/group attributes and original file bytes. Metadata failure/5s cancellation fallback retains document; mixed kinds follow native album rules.", additional=[(SUB + "LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift", '"chats.sendMp4DocumentAsVideo"'), (UI + "Sources/ChatControllerOpenAttachmentMenu.swift", "exteralessMP4FileDescription(url)")])
    add("nagram.showSmallGIF", COMP + "ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift", adaptation="Actual standalone GIF preview is constrained to 120pt. Album/mosaic, paid-preview and secret geometry retain native handling; media and rich message attributes are not rewritten.")
    add("neko.autoPauseVideo", video, adaptation="Native foreground/active-account observer pauses gallery video and resumes only the same item it paused. Source policy tests cover pre-existing pause, item switch and disabled state; no runtime playback claim.", additional=[(CORE + "ChatMediaPolicy.swift", "public struct ChatVideoBackgroundPolicy")])
    add("neko.takeGIFasVideo", video, adaptation="Native GIF gallery scrubber/playback/settings and eligible PiP controls are enabled by the setting; original media flag/looping retained. Send/layout never flattens the native message.")

    add("chats.alwaysSendInHD chats.hideCameraTile", SUB + "MediaPickerUI/Sources/MediaPickerScreen.swift")
    add("chats.bottomButton nagram.hideGiftButtonInChannel", COMP + "ChatChannelSubscriberInputPanelNode/Sources/ChatChannelSubscriberInputPanelNode.swift")
    add("chats.hideReactionsInChannels chats.hideReactionsInGroups chats.hideReactionsInPrivate", STATUS, 'field = "{field}"', additional=[(COMP + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift", "exteralessHideMessageReactions")])
    add("chats.inlineMathResult chats.inlineMathCurrency", PANEL)
    add("chats.showResultsBeforeVoting", COMP + "ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift")
    add("chats.stripTrackingOnOpen", UI + "Components/OpenUserGeneratedUrl/Sources/OpenUserGeneratedUrl.swift", adaptation="AdGuard cleanup in native URL openers; signed/user-info and mandatory native checks preserved. AppDelegate import hunk and native verification pending.")
    add("chats.stripTrackingOnPaste", PANEL, "pastedLinkTargetTransformer", adaptation="Native private Document href rewrite, attributed imports, final IME insertText, legacy commit, native link editor and reverse UTF-16 edits. No document flattening; share-import hunk pending.", additional=[(UI + "Components/RichTextEditor/Sources/RichTextInputDecHost/TGIDObservingBlockTextView.m", "tgid_committedTextTransformer(committedRange"), (UI + "Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift", "fragment.rewritingLinkTargets")])
    add("chats.wideChannelPosts", COMP + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift")
    add("nagram.confirmAllLinks neko.skipOpenLinkConfirm", UI + "Components/OpenUserGeneratedUrl/Sources/OpenUserGeneratedUrl.swift")
    add("nagram.disableClickCommandToSend", CHAT + "ExteralessMessageActions.swift", additional=[(UI + "Sources/ChatController.swift", "exteralessConfirmBotCommand")])
    add("nagram.doubleTapAction nagram.doubleTapActionOut", STATUS, "ChatDoubleTapAction.selected", adaptation="All original 0...12 values: native reaction/menu/reply and typed native save/repeat/repeat-copy/edit/translate/LLM/delete/forward/download. Rights, confirmation, Stars and rich payloads retained; AI projection access is integrated.", additional=[(CHAT + "ExteralessMessageGestures.swift", "switch action")])
    add("nagram.showMessageID neko.showAddToSavedMessages neko.showMessageDetails neko.showRepeat neko.repeatConfirm", CHAT + "ExteralessMessageActions.swift", adaptation="Common native message-menu insertion already applied. Reuses protected/Stars/native send operations; repeat and repeat-as-copy now retain distinct semantics.", additional=[(UI + "Sources/ChatInterfaceStateContextMenus.swift", "let extraActions = exteralessMessageContextActions")])
    formatting = "showTextBold showTextItalic showTextMono showTextMonoCode showTextQuote showTextSpoiler showTextStrikethrough showTextUnderline showTextCreateLink showTextCreateDate showTextTranslate showTextRegular textStyleOrder"
    add(" ".join("nagram." + x for x in formatting.split()), COMP + "ChatTextInputPanelNode/Sources/ExteralessChatInputHelpers.swift", "func exteralessOrderedFormatActions", adaptation="Native and legacy formatting gates/order. Date invokes native editor; canonical selected-text translation is chats.showTextTranslate with atomic old-AI-key migration and a dependent two-consumer test.")
    translation = records["nagram.showTextTranslate"]
    translation["ios"]["implementation_callsites"] += [
        anchor(CORE + "AITranslationPolicy.swift", "showTextTranslate = ChatFormattingPolicy.translationActionEnabled"),
        anchor(SUB + "TextSelectionNode/Sources/TextSelectionNode.swift", "AITranslationPolicy().showTextTranslate"),
        anchor(UI + "Sources/ExteralessClient/ExteralessClientRuntime.swift", "try ChatFeatures.migrateSettings"),
        anchor("telegram-ios/Telegram/Share/ShareRootController.swift", "try ChatFeatures.migrateSettings"),
    ]
    translation["ios"]["adaptation"] = "Aggregated Chat/AI receipt: one chats.showTextTranslate control drives native formatting and AI selected-text translation. Atomic old-key migration is called by both main-app and Share preparation. Include the AI follow-up in the frozen Core commit; XCTest/native/frame verification pending. Apply the AI receipt-exclusion hunk in chat-media-shared.patch before merging."
    translation["implementation"]["evidence"] = [dict(kind="source", **anchor("swift/ExteralessCore/Tests/ExteralessCoreTests/ChatPhase2PolicyTests.swift", "func testCanonicalTranslationMigrationDrivesBothRealConsumers"))]
    add("neko.hideKeyboardOnChatScroll", UI + "Sources/Chat/ChatControllerLoadDisplayNode.swift")
    add("neko.hideSendAsChannel", PANEL)
    add("openextera.addCommaAfterMention", SUB + "ChatPresentationInterfaceState/Sources/ChatTextFormat.swift")

    # Three explicitly retained sticker presentation IDs.
    add("chats.stickerShape chats.stickerTimeSide neko.hideTimeForSticker", STATUS, '"chats.{field}"', adaptation="Static/animated/video-sticker radius and side-time geometry; hide time leaves reactions intact. Native glyph/dice variants retain their original shape. Frames pending.")
    add("nagram.silentMessageByDefault", SUB + "TelegramCore/Sources/PendingMessages/EnqueueMessage.swift", adaptation="Default only when notification override is absent. Explicit false survives plugin MODIFY; native/from-plugin enqueue both authorize before media/DB and retain recursion bypass. Shared optional send/inline/media hunks pending.")

    # P-message-presentation, ten exact IDs.
    add("chats.replyColors chats.replyEmoji chats.replyBackground", COMP + "ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift")
    add("chats.removeMessageTail", SUB + "TelegramPresentationData/Sources/Resources/PresentationResourcesChat.swift", additional=[(SUB + "TelegramPresentationData/Sources/ChatMessageBubbleImages.swift", "drawTail = drawTail && !removeTail")])
    add("chats.unreadCapsule", COMP + "ChatMessageItemImpl/Sources/ChatUnreadItem.swift")
    add("chats.hideCallButton chats.hideChannelSearchButton", COMMON, '"chats.{field}"', live=False, adaptation="Exact chat-origin expanded native-header hunk awaits coordinator; appearance-owned nodes are preserved.")
    add("nagram.hideShareButtonInChannel nagram.showTimeHint", STATUS)
    add("neko.showSpoilersDirectly", COMP + "ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift", additional=[(COMP + "ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift", '"chats.showSpoilersDirectly"')], adaptation="Text spoiler presentation/hit-testing in text and rich bubbles. Media spoiler and notification privacy behavior stay on their owning paths.")

    # P-composer-policy, nineteen exact IDs.
    add("chats.hideMoneyButton", UI + "Sources/ChatControllerOpenAttachmentMenu.swift", adaptation="Gates the actual Wallet .money attachment tab; fee/Stars confirmation retained.")
    add("chats.keepAttachButton nagram.hideBotButtonInInputField nagram.showSendAsUnderMessageHint nagram.typeMessageHintUseGroupName neko.useChatAttachMediaMenu", PANEL, adaptation="Native composer button/menu/placeholder behavior. Sender is shown inline in the one-line native placeholder; recording menu enters native locked recording.")
    add("nagram.combineMessage nagram.leftBottomButton", CHAT + "ExteralessSelectionActions.swift", adaptation="Native selected-message actions; combine preserves attributed text into an editable draft and chooses first reply/current thread. Original automatic source deletion is not performed by this adaptation.")
    add("nagram.defaultScheduledTime", UI + "Components/ChatScheduleTimeController/Sources/ChatScheduleTimeScreen.swift", adaptation="Original 30 delay steps, minute ceiling, explicit dates and native send-when-online preserved.")
    add("nagram.disableMarkdown nagram.markdownParser", SUB + "TextFormat/Sources/ExteralessComposerMarkdown.swift", adaptation="Actual ordered Neko grammar versus native Telegram grammar; disable preserves authored entities and rich structures. Plain paste also respects disable.")
    add("nagram.enablePanguOnSending", SUB + "TelegramCore/Sources/PendingMessages/ExteralessOutgoingChatText.swift", adaptation="Native attributed thin-space group splices before interception, with entity remapping; code/URLs/rich payloads and encrypted text preserved.")
    add("nagram.fixLinkPreview nagram.showQuickReplyInBotCommands", UI + "Sources/ChatInterfaceStateContextQueries.swift")
    add("nagram.showTextCreateMention", PANEL, adaptation="Native peer picker applies a mention link through the rich kernel or an undoable legacy attribute splice; stale selection/account guards.")
    add("neko.askBeforeCall", CHAT + "ExteralessChatCallConfirmation.swift", live=False, adaptation="Native confirmation helper and exact universal AccountContext requestCall hunk ready; shared entry not yet wired.")
    add("neko.confirmAVMessage", UI + "Sources/Chat/ChatControllerMediaRecording.swift", adaptation="Send recording becomes native Preview; subsequent Send retains Stars/slowmode/native recording semantics.")
    add("neko.disableLinkPreviewByDefault", SUB + "ChatPresentationInterfaceState/Sources/ExteralessComposerStatePolicy.swift", adaptation="Native preview panel/send attributes share default and per-draft explicit enable marker. Individual URL dismissal wins. Native preview resolution still runs.")
    add("neko.sendCommentAfterForward", UI + "Sources/ChatControllerNode.swift", adaptation="Orders complete native values; multi-source forward batches now keep every member and comment, and enqueue serially.")

    # P-message-actions, forty-six exact IDs.
    add("nagram.ActionBarButtonCopy nagram.ActionBarButtonEdit nagram.ActionBarButtonReply nagram.ActionBarButtonSelectBetween", CHAT + "ExteralessSelectionActions.swift", '"{field}"', adaptation="Native selection More actions reuse copy/edit/reply and select-between; copy keeps rich private fragments and permissions.")
    add("nagram.ActionBarButtonForward neko.showShareMessages neko.showReport", COMP + "ChatMessageSelectionInputPanelNode/Sources/ChatMessageSelectionInputPanelNode.swift", '"{field}"', adaptation="Native toolbar gates; shared ordinary message Report gate is separately handed off.")
    menu_ids = "chatMenuItemBoostGroup chatMenuItemDeleteOwnMessages chatMenuItemGoToMessage chatMenuItemHideTitle chatMenuItemLinkedChat chatMenuItemToBeginning shortcutsAdministrators shortcutsMembers shortcutsPermissions shortcutsRecentActions shortcutsStatistics"
    add(" ".join("nagram." + x for x in menu_ids.split()), CHAT + "ExteralessChatActions.swift", '"{field}"', adaptation="Actual chat actions reached from composer/message menus; native administration/statistics/navigation. Delete-my-messages reviews up to 100 recent matches per invocation, with native delete choice/Undo; not an unlimited purge.")
    deletion_sheet = UI + "Components/AdminUserActionsSheet/Sources/AdminUserActionsSheet.swift"
    for field, needle in [
        ("defaultDeleteMenu", "let defaults = ChatDeleteMenuDefaults.current()"),
        ("defaultDeleteMenuBanUsers", "defaults.contains(.banUsers)"),
        ("defaultDeleteMenReportSpam", "defaults.contains(.reportSpam)"),
        ("defaultDeleteMenuDeleteAll", "defaults.contains(.deleteAll)"),
        ("defaultDeleteMenuDoActionsInCommonGroups", "defaults.contains(.commonGroups)"),
    ]:
        extra = [(CHAT + "ExteralessCommonGroupModeration.swift", "if allowed.contains(.clearHistory)")] if field == "defaultDeleteMenuDoActionsInCommonGroups" else []
        add("nagram." + field, deletion_sheet, needle, key="chats.defaultDeleteMenu", adaptation="Original linked flags share one parent bitmask (ban 8, report 4, delete all 2, common groups 1); native defaults editor and moderation checks use that same value. Indirect original consumer is getDeleteMenuChecks -> toggleDefaultChecks. Common-group operations reuse native rights/history APIs.", additional=extra)
    add("nagram.deleteChatForBothSides", UI + "Sources/ChatControllerAdminBanUsers.swift", '"{field}"', adaptation="Initial value of native unsend-personal switch; explicit user choice and separate for-me/for-everyone actions remain authoritative.")
    add("nagram.groupedMessageMenu", CHAT + "ExteralessMessageActions.swift", '"{field}"', adaptation="Native nested More message actions instead of Android grouped icon row; native action bodies/Back retained.")
    viewer = "mediaViewerMenuItemCopyFrame mediaViewerMenuItemCopyPhoto mediaViewerMenuItemForward mediaViewerMenuItemNoQuoteForward mediaViewerMenuItemScanQRCode mediaViewerMenuItemSetProfilePhoto"
    add(" ".join("nagram." + x for x in viewer.split()), CHAT + "ExteralessGalleryChatActions.swift", '"{field}"', adaptation="Real native gallery action-sheet bridge, bounded media decode/current-frame/QR/profile operations and native forward draft. Copy protection, paid/secret media and original Share/Save flow retained.", additional=[(SUB + "GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift", "ExteralessGalleryMessageActions.present")])
    extra = "nagram.showAddToBookmark nagram.showAddToStickers nagram.showCopyAsSticker nagram.showCopyFrame nagram.showCopyPhoto nagram.showNoQuoteForward nagram.showRepeatAsCopy nagram.showReplyInPrivate nagram.showSetReminder neko.showAdminActions neko.showChangePermissions neko.showDeleteDownloadedFile"
    add(extra, CHAT + "ExteralessAdditionalMessageActions.swift", '"{field}"', adaptation="Real native extra message action, gated by original preference and source/native capabilities. Media/forward/reply references remain native; account-local bookmarks persist reference IDs only.")
    add("nagram.showAddToFavorites nagram.showCopyLink nagram.showReactions", COMMON, 'ChatMenuPolicy.enabled("{field}")', live=False, adaptation="Exact gate for existing native favorite/link/reaction action supplied to coordinator; no duplicate implementation or verified claim.")

    # Shared-file owners may apply ready hunks while this receipt is being refreshed.
    # Promote only physical source callsites, never a planned patch or a verified status.
    for feature_id, path, needle in [
        ("chats.hideCallButton", UI + "Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift", '"chats.hideCallButton"'),
        ("chats.hideChannelSearchButton", UI + "Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift", '"chats.hideChannelSearchButton"'),
        ("neko.askBeforeCall", UI + "Sources/AccountContext.swift", "exteralessConfirmOutgoingCall(context: self"),
        ("nagram.showAddToFavorites", UI + "Sources/ChatInterfaceStateContextMenus.swift", 'ChatMenuPolicy.enabled("showAddToFavorites")'),
        ("nagram.showCopyLink", UI + "Sources/ChatInterfaceStateContextMenus.swift", 'ChatMenuPolicy.enabled("showCopyLink")'),
        ("nagram.showReactions", UI + "Sources/Chat/ChatControllerOpenMessageContextMenu.swift", 'ChatMenuPolicy.enabled("showReactions")'),
    ]:
        if needle in (ROOT / path).read_text(encoding="utf-8"):
            records[feature_id]["ios"]["implementation_callsites"] = [anchor(path, needle)]
            records[feature_id]["ios"]["adaptation"] = "Shared native gate is integrated; compilation/runtime/frame verification pending."
    controller = (ROOT / (UI + "Sources/ChatController.swift")).read_text(encoding="utf-8")
    if "silentPosting: Bool?, scheduleTime" in controller and "parameters?.notificationOverride" in controller:
        records["nagram.silentMessageByDefault"]["ios"]["adaptation"] = records["nagram.silentMessageByDefault"]["ios"]["adaptation"].replace("hunks pending", "hunks integrated")

    modules = {}
    for name, path, needle in [
        ("chats", CHAT + "ExteralessMessageActions.swift", "func exteralessMessageContextActions"),
        ("components", PANEL, "pastedLinkTargetTransformer"),
        ("math", CORE + "ChatCurrencyQuery.swift", "Locale.Currency.isoCurrencies"),
        ("links", UI + "Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift", "fragment.rewritingLinkTargets"),
    ]:
        modules[name] = {"implementation": {"status": "partial", "ported": False,
                          "evidence": [dict(kind="source", **anchor(path, needle))],
                          "note": "Chat2 source handoff; shared hunks, native compilation, XCTest and recorded frames pending. See chat.md and exact-ID receipts."}}
    modules["chats"]["implementation"]["evidence"].append(dict(kind="source", **anchor(CHAT + "ExteralessChatIntegration.swift", "private func open(")))
    modules["chats"]["implementation"]["evidence"].append(dict(kind="source", **anchor("swift/ExteralessCore/Tests/ExteralessCoreTests/ChatContextPresentationScopeTests.swift", "func testSavedActionAAfterSwitch")))
    return {"features": [records[k] for k in sorted(records)], "modules": modules}


def audit(fragment):
    inventory = json.loads((ROOT / "docs/parity/client-features.json").read_text(encoding="utf-8"))
    plan = json.loads((ROOT / "docs/parity/remaining-ownership.json").read_text(encoding="utf-8"))
    wanted_packages = {"P-message-actions", "P-composer-policy", "P-message-presentation"}
    packages = [p for p in plan["unfragmented_packages"] if p["id"] in wanted_packages]
    owned = {r["id"]: r for r in fragment["features"]}
    wanted = {i for p in packages for i in p["feature_ids"]}
    assert len(wanted) == 75
    assert not wanted - owned.keys(), sorted(wanted - owned.keys())
    assert len(MEDIA_IDS) == 13 and len(PLAYBACK_IDS) == 6
    assert not (set(MEDIA_IDS) | set(PLAYBACK_IDS)) - owned.keys()
    assert len(fragment["features"]) == len(owned) == 137
    assert all(not r["implementation"]["ported"] for r in owned.values())
    merged = merge_parity(inventory, fragments=[fragment])
    assert len(merged["features"]) == len(inventory["features"]) == 567
    return {"owner": "chat", "kind": "source-receipts-not-runtime-verification", "feature_records": len(owned),
            "module_records": len(fragment["modules"]), "inventory_features_retained": len(merged["features"]),
             "packages": [{"id": p["id"], "count": len(p["feature_ids"]), "feature_ids": p["feature_ids"]} for p in packages],
            "reconciliation": [{"id": "media-browser-aliases", "count": 13, "feature_ids": MEDIA_IDS}, {"id": "restored-playback", "count": 6, "feature_ids": PLAYBACK_IDS}],
            "unowned_assigned_ids": [], "ported_or_verified_claims": 0}


def text(fragment):
    features = ",\n".join("    " + json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in fragment["features"])
    return '{\n  "features": [\n' + features + '\n  ],\n  "modules": ' + json.dumps(fragment["modules"], ensure_ascii=False, separators=(",", ":")) + '\n}\n'


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true", dest="print_fragment")
    parser.add_argument("--receipts", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    fragment = build_fragment()
    summary = audit(fragment)
    if args.check:
        actual = json.loads((ROOT / "docs/wave-2/chat-parity.json").read_text(encoding="utf-8"))
        actual["features"].sort(key=lambda record: record["id"])
        assert actual == fragment, "Regenerate source line references through a patch; fragment is stale"
    if args.print_fragment:
        print(text(fragment), end="")
    elif args.receipts:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(json.dumps({k: v for k, v in summary.items() if k != "packages"}, indent=2))
