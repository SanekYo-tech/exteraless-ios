import Foundation

/// Authored from the twelve module.settings Java files, SettingsHelper's moved
/// rows and ClassAliases.EXACT. These are source names, never UIKit class names
/// discovered by NSStringFromClass/reflection. Unknown plugin UItems stay unknown.
public enum ClientSettingsSourceRoutes {
    public struct Row: Sendable {
        public let page: String
        public let names: [String]
        public let title: String
        public let route: ClientSettingsRoute
        let previousPages: [String]
    }

    private static func key(_ page: String, _ names: String, _ key: String, from: [String] = []) -> Row {
        .init(page: page, names: names.split(separator: "|").map(String.init), title: names.components(separatedBy: "|")[0],
              route: .setting(key), previousPages: from)
    }
    private static func action(_ page: String, _ names: String, _ id: String, from: [String] = []) -> Row {
        .init(page: page, names: names.split(separator: "|").map(String.init), title: names.components(separatedBy: "|")[0],
              route: .action(id), previousPages: from)
    }
    private static func focus(_ page: String, _ names: String, _ key: String, from: [String] = []) -> Row {
        .init(page: page, names: names.split(separator: "|").map(String.init), title: names.components(separatedBy: "|")[0],
              route: .row(key), previousPages: from)
    }
    private static func absent(_ page: String, _ names: String, _ title: String, _ reason: String, from: [String] = []) -> Row {
        .init(page: page, names: names.split(separator: "|").map(String.init), title: title,
              route: .unavailable(reason), previousPages: from)
    }

    public static let rows: [Row] = [
        focus("settings", "general|generalRow", "appearance.disableNumberRounding"),
        focus("settings", "appearance|appearanceRow", "appearance.avatarCorners"),
        focus("settings", "chats|chatsRow", "chats.stickerSize"),
        focus("settings", "other|otherRow", "tools.crashReports"),
        action("settings", "about|aboutRow", "tools.updates"),
        action("settings", "MENU_CLOUD|cloud", "cloud.settings"),
        .init(page: "settings", names: ["MENU_SEARCH", "search"], title: "Search", route: .search, previousPages: []),
        absent("settings", "plugins|pluginsRow", "Plugins", "Open Plugins from Telegram Settings or the Main Menu; it is not a client action-registry entry."),
        absent("settings", "channel|channelRow|source|sourceRow|designer|designerRow|designStudio|designStudioRow", "Original project links", "These Original project/designer link rows have no registered native settings action."),

        key("general", "disableNumberRounding|disableNumberRoundingRow", "appearance.disableNumberRounding"),
        key("general", "formatTimeWithSeconds|formatTimeWithSecondsRow", "appearance.showSeconds"),
        key("general", "inAppVibration|inAppVibrationRow", "appearance.disableVibration"),
        key("general", "filterZalgo|filterZalgoRow", "privacy.zalgoFilter"),
        key("general", "relativeLastSeen|relativeLastSeenRow", "appearance.relativeLastSeen"),
        key("general", "hidePhone|hidePhoneRow", "privacy.hidePhone"),
        key("general", "showIdAndDc|showIdAndDcRow", "identity.idDcType"),
        key("general", "downloadSpeed|downloadSpeedRow", "tools.downloadSpeedBoost"),
        key("general", "uploadBoost|uploadBoostRow", "tools.uploadBoost"),
        key("general", "IPv6|useIPv6|useIPv6Row", "network.useIPv6"),
        key("general", "dnsType|DnsType|dnsTypeRow", "network.dnsType"),
        key("general", "customDoH|CustomDoH|customDoHRow", "network.customDoH"),
        key("general", "savePath|savePathRow|customSavePath", "tools.customSavePath"),
        key("general", "saveToChatSubfolder|SaveToChatSubfolder|saveToChatSubfolderRow", "tools.saveToChatSubfolder"),
        key("general", "botPrivacyEnabled|OEBotPrivacyEnabled|botPrivacyEnabledRow", "privacy.botPrivacyEnabled"),
        key("general", "botPrivacyAlwaysAsk|OEBotPrivacyAlwaysAsk|botPrivacyAlwaysAskRow", "privacy.botPrivacyAlwaysAsk"),
        action("general", "botPrivacyAccount|OEBotPrivacyAccount|botPrivacyAccountRow", "privacy.botAccount"),
        key("general", "sortByUnread|SortByUnread|sortByUnreadRow", "chats.sortByUnread"),
        key("general", "unlimitedPinnedDialogs|UnlimitedPinnedDialogs|unlimitedPinnedRow", "chats.unlimitedPinnedDialogs", from: ["other"]),
        key("general", "hideArchive|hideArchiveRow", "appearance.hideArchive"),
        key("general", "archiveOnPull|archiveOnPullRow", "chats.openArchiveOnPull"),
        key("general", "disableUnarchiveSwipe|disableUnarchiveSwipeRow", "chats.doNotUnarchiveBySwipe"),
        key("general", "mapProvider|mapProviderRow", "maps.useOSMDroidMap"),
        key("general", "mapDriftingFix|mapDriftingFixRow", "maps.mapDriftingFixForGoogleMaps"),
        key("general", "mapPreview|mapPreviewRow", "maps.mapPreviewProvider"),
        action("general", "pushStatus|pushStatusRow", "privacy.notifications"),
        action("general", "translator|translatorRow", "ai.translationModels"),
        key("general", "translateInSheet|translateInSheetRow", "chats.translateInSheet", from: ["chats"]),
        key("general", "translateButton|showTranslate", "ai.showTranslate"),
        key("general", "translateChatButton|TelegramUIAutoTranslate", "ai.telegramUIAutoTranslate"),
        key("general", "translationProvider", "ai.translationProvider"),
        action("general", "translateToLang|TranslateTo|doNotTranslate|DoNotTranslate", "ai.translationLanguages"),
        absent("general", "pushServiceType|PushServiceType|pushServiceTypeRow|pushServiceTypeUnifiedGateway|PushServiceTypeUnifiedGateway|pushGatewayRow|pushServiceTypeInAppDialog|PushServiceTypeInAppDialog|residentNotificationRow", "Android push transport", "FCM, MicroG, UnifiedPush gateways and resident Android services are unavailable on iOS. Use Notification diagnostics for APNs."),
        absent("general", "disableNotificationBubbles|notificationBubblesRow|batteryOptimization|batteryOptimizationRow", "Android notification and battery controls", "Android notification bubbles and battery-whitelist settings have no iOS provider."),
        absent("general", "glyph|glyphRow", "Nothing Glyph", "Nothing Phone rear-light hardware and SDK are unavailable on iOS.", from: ["other"]),

        key("appearance", "avatarCorners|avatarCornersPreviewRow", "appearance.avatarCorners"),
        key("appearance", "singleCornerRadius|singleCornerRadiusRow", "appearance.singleCornerRadius"),
        key("appearance", "fabShape|fabShapeRow", "appearance.squareFab"),
        key("appearance", "useSystemFonts|useSystemFontsRow", "appearance.useSystemFonts"),
        key("appearance", "gooeyAvatar|gooeyAvatarRow", "appearance.gooeyAvatarAnimation"),
        key("appearance", "customThemes|customThemesRow", "appearance.customThemes"),
        key("appearance", "sectionRadius|sectionRadiusRow", "appearance.sectionRadius"),
        key("appearance", "separateHeaders|separateHeadersRow", "appearance.separateHeaders"),
        key("appearance", "dividerStyle|dividerStyleRow", "appearance.dividerStyle"),
        key("appearance", "glassOutline|glassOutlineRow|glassOutlineStyle", "appearance.glassOutlineStyle"),
        key("appearance", "glassMessageMenu|glassMessageMenuRow", "appearance.glassMessageMenu"),
        key("appearance", "disableAvatarBlur|disableAvatarBlurRow", "appearance.disableAvatarBlur"),
        key("appearance", "forceSnow|forceSnowRow", "appearance.actionBarDecoration"),
        key("appearance", "centerTitle|centerTitleRow", "appearance.centerActionBarTitle"),
        key("appearance", "senderMiniAvatars|senderMiniAvatarsRow", "appearance.senderMiniAvatars"),
        key("appearance", "titleText|titleTextRow", "appearance.titleText"),
        key("appearance", "tabTitleStyle|tabTitleStyleRow", "appearance.tabsTitleType"),
        key("appearance", "tabCounter|tabCounterRow", "appearance.ignoreUnreadCount"),
        key("appearance", "md3Loading|md3LoadingRow", "appearance.newLoadingStyle"),
        key("appearance", "md3Slider|md3SliderRow", "appearance.sliderStyle"),
        key("appearance", "md3Switch|md3SwitchRow", "appearance.switchStyle"),
        key("appearance", "md3ChatHeader|md3ChatHeaderRow", "appearance.newChatHeaderStyle"),
        key("appearance", "md3NavBar|md3NavBarRow", "appearance.newNavigationBarStyle"),
        key("appearance", "md3ListItems|md3ListItemsRow", "appearance.m3ListItems"),
        key("appearance", "md3Player|md3PlayerRow", "appearance.md3Player"),
        key("appearance", "md3MiniPlayer|md3MiniPlayerRow", "appearance.md3MiniPlayer"),
        key("appearance", "iosNavBar|iosNavBarRow", "appearance.iosNavigationBarStyle"),
        focus("appearance", "md3Styles|md3GroupRow", "appearance.newLoadingStyle"),
        focus("appearance", "iosStyles|iosGroupRow", "appearance.iosNavigationBarStyle"),
        focus("appearance", "appNavigation|appNavigationRow", "appearance.tabletMode"),
        focus("appearance", "hiding|hidingRow", "appearance.hideStoriesFromHeader"),
        action("appearance", "iconPacks|iconPacksRow", "appearance.iconPacks"),
        action("appearance", "emojiSets|EmojiSets|emojiSetsRow", "stickers.emojiPacks"),
        key("appearance", "useSystemEmoji", "chats.useSystemEmoji"),
        action("appearance", "pillStack|pillStackRow", "pills.status"),
        focus("appearance", "playerStyle|playerStyleRow", "appearance.playerCoverStyle"),
        absent("appearance", "forceBlur|forceBlurRow", "Force Android blur", "Android LiteMode blur has no native settings provider. The SDK compatibility field is storage-only and stays hidden."),
        absent("appearance", "iosChatHeader|iosChatHeaderRow", "Android iOS-style chat header", "This Android style switch has no registered native control; iOS uses its actual native chat header."),

        key("navigation", "tabletMode|ID_TABLET_MODE|-101", "appearance.tabletMode"),
        key("navigation", "backAnimation|ID_BACK_ANIMATION|-102", "appearance.backAnimationStyle"),
        key("navigation", "predictiveBackIntensity|ID_PREDICTIVE_INTENSITY|-103", "appearance.predictiveBackIntensity"),
        key("navigation", "navigationDrawer|ID_DRAWER|-104", "appearance.navigationDrawer"),
        key("navigation", "immersiveDrawerAnimation|ID_IMMERSIVE|-105", "appearance.immersiveDrawerAnimation"),
        key("navigation", "bottomNavigationBar|ID_BOTTOM_NAVIGATION_BAR|-106", "appearance.hideBottomNavigationBar"),
        key("navigation", "MainTabsHideTitles|ID_HIDE_TAB_TITLES|-107", "appearance.mainTabsHideTitles"),
        key("navigation", "MainTabsHideContacts|ID_HIDE_CONTACTS_TAB|-108", "appearance.mainTabsHideContacts"),
        key("navigation", "MainTabsHideCallsSettings|ID_HIDE_CALLS_TAB|-109", "appearance.mainTabsHideCallsSettings"),
        key("navigation", "MainTabsHideProfile|ID_HIDE_PROFILE_TAB|-110", "appearance.mainTabsHideProfile"),
        key("navigation", "AlwaysShowDownloadIcon|ID_ALWAYS_DOWNLOADS|-111", "appearance.alwaysShowDownloadIcon"),
        action("navigation", "mainMenu|mainMenuLayout|ID_ADD_DIVIDER|-200|resetMenuLayout", "appearance.customizeMenu"),

        key("chats", "stickerSize|stickerSizeRow", "chats.stickerSize"),
        key("chats", "stickerTime|hideTimeOnStickers|stickerTimeRow", "chats.stickerTimeSide"),
        key("chats", "stickerShape|stickerShapeRow", "chats.stickerShape"),
        focus("chats", "replies|repliesGroupRow", "chats.replyColors"),
        key("chats", "replyColorsRow", "chats.replyColors"),
        key("chats", "replyEmojiRow", "chats.replyEmoji"),
        key("chats", "replyBackgroundRow", "chats.replyBackground"),
        focus("chats", "unlimited|unlimitedRecentStickers|unlimitedGroupRow", "chats.maxRecentStickerCount"),
        key("chats", "unlimitedStickersRow", "chats.maxRecentStickerCount"),
        key("chats", "unlimitedGifsRow", "chats.unlimitedSavedGifs"),
        key("chats", "SendLockedCustomEmojiAsSticker|lockedEmojiAsStickerRow", "chats.sendLockedCustomEmojiAsSticker"),
        key("chats", "doubleTapIncoming|doubleTapIncomingRow", "chats.doubleTapAction"),
        key("chats", "doubleTapOutgoing|doubleTapOutgoingRow", "chats.doubleTapActionOut"),
        action("chats", "doubleTapReaction|doubleTapReactionRow", "stickers.quickReaction"),
        focus("chats", "quickTransition|quickTransitionGroupRow", "chats.disableSwipeToNext"),
        key("chats", "quickTransitionChannelsRow", "chats.disableSwipeToNext"),
        key("chats", "quickTransitionTopicsRow", "chats.disableSwipeToNextTopic"),
        key("chats", "hideKeyboardOnScroll|hideKeyboardOnScrollRow", "chats.hideKeyboardOnChatScroll"),
        key("chats", "deleteChatForBothSides|DeleteChatForBothSides|deleteChatForBothSidesRow", "chats.deleteChatForBothSides"),
        key("chats", "disableGlobalSearch|disableGlobalSearchRow", "chats.disableGlobalSearch"),
        key("chats", "searchHashtagChat|SearchHashtagDefaultPageChat|searchHashtagChatRow", "chats.searchHashtagDefaultPageChat"),
        key("chats", "searchHashtagChannel|SearchHashtagDefaultPageChannel|searchHashtagChannelRow", "chats.searchHashtagDefaultPageChannel"),
        key("chats", "addCommaAfterMention|addCommaRow", "chats.addCommaAfterMention"),
        key("chats", "inlineMathResult|inlineMathRow", "chats.inlineMathResult"),
        key("chats", "inlineMathCurrency|inlineMathCurrencyRow", "chats.inlineMathCurrency"),
        key("chats", "tapToSwitchRecord|UseChatAttachEnterMenu|tapToSwitchRecordRow", "chats.useChatAttachMediaMenu"),
        key("chats", "keepAttachButton|keepAttachButtonRow", "chats.keepAttachButton"),
        key("chats", "removeMessageTail|removeMessageTailRow", "chats.removeMessageTail"),
        key("chats", "unreadCapsule|unreadCapsuleRow", "chats.unreadCapsule"),
        key("chats", "replaceEdited|replaceEditedRow", "chats.useEditedIcon"),
        key("chats", "showOnlineStatus|showOnlineStatusRow", "identity.showOnlineStatus"),
        key("chats", "showResultsBeforeVoting|showResultsBeforeVotingRow", "chats.showResultsBeforeVoting"),
        key("chats", "dateOfForwardedMsg|DateOfForwardedMsg|dateOfForwardedMsgRow", "identity.dateOfForwardedMsg"),
        key("chats", "showTimeHint|ShowTimeHint|showTimeHintRow", "chats.showTimeHint"),
        key("chats", "rememberAllBackMessages|rememberAllRepliesRow", "chats.rememberAllBackMessages"),
        key("chats", "fixLinkPreview|FixLinkPreview|fixLinkPreviewRow", "chats.fixLinkPreview"),
        key("chats", "disableLinkPreviewByDefault|DisableLinkPreviewByDefault|disableLinkPreviewRow", "chats.disableLinkPreviewByDefault"),
        focus("chats", "openLinkConfirmation|SkipOpenLinkConfirm|ConfirmAllLinks|openLinkConfirmationRow", "chats.confirmAllLinks"),
        focus("chats", "askWhen|askWhenGroupRow", "chats.confirmAVMessage"),
        key("chats", "confirmAVMessage|ConfirmAVMessage|confirmAVMessageRow", "chats.confirmAVMessage"),
        key("chats", "askBeforeCalling|AskBeforeCalling|askBeforeCallRow", "chats.askBeforeCall"),
        key("chats", "repeatConfirm|repeatConfirmRow", "chats.repeatConfirm"),
        key("chats", "DisableClickCommandToSend|disableClickCommandToSendRow", "chats.disableClickCommandToSend"),
        focus("chats", "stripTracking|stripTrackingGroupRow", "chats.stripTrackingOnOpen"),
        key("chats", "stripTrackingOpenRow", "chats.stripTrackingOnOpen"),
        key("chats", "stripTrackingPasteRow", "chats.stripTrackingOnPaste"),
        action("chats", "trackingFilter|trackingFilterRow", "chats.trackingFilter"),
        key("chats", "wideChannelPosts|wideChannelPostsRow", "chats.wideChannelPosts"),
        key("chats", "wideFeedPosts|wideFeedPostsRow", "chats.wideFeedPosts"),
        action("chats", "chatSettings|chatSettingsRow", "appearance.nativeThemes"),
        action("chats", "aiChat|aiChatRow", "ai.services"),
        focus("chats", "menus|menusRow", "chats.bottomButton"),
        focus("chats", "media|mediaRow", "tools.videoMessageCameraFacing"),

        key("menus", "bottomButton|bottomButtonRow", "chats.bottomButton", from: ["chats"]),
        focus("menus", "chatMenu|chatMenuGroupRow", "chats.chatMenuItemToBeginning", from: ["chats"]),
        focus("menus", "adminShortcuts|adminShortcutsRow", "chats.shortcutsAdministrators", from: ["chats"]),
        focus("menus", "messageMenu|messageMenuGroupRow", "chats.showMessageDetails", from: ["chats"]),
        key("menus", "groupedMessageMenu|groupedMessageMenuRow", "chats.groupedMessageMenu", from: ["chats"]),
        key("menus", "textStyle|TextStyle|textStyleRow", "chats.textStyleOrder", from: ["chats"]),
        focus("menus", "mediaViewerMenu|mediaViewerMenuGroupRow", "chats.mediaViewerMenuItemForward", from: ["chats"]),
        focus("menus", "actionBarButtons|actionBarButtonsGroupRow", "chats.ActionBarButtonReply", from: ["chats"]),
        action("menus", "defaultDeleteMenu|DefaultDeleteMenu|deleteMenuGroupRow|deleteMenuBanUsersRow|deleteMenuReportSpamRow|deleteMenuDeleteAllRow|deleteMenuCommonGroupsRow", "chats.deleteDefaults", from: ["chats"]),
        key("menus", "chatMenuAdminsRow", "chats.shortcutsAdministrators"),
        key("menus", "chatMenuRecentActionsRow", "chats.shortcutsRecentActions"),
        key("menus", "chatMenuStatisticsRow", "chats.shortcutsStatistics"),
        key("menus", "chatMenuPermissionsRow", "chats.shortcutsPermissions"),
        key("menus", "chatMenuMembersRow", "chats.shortcutsMembers"),
        key("menus", "chatMenuBoostRow", "chats.chatMenuItemBoostGroup"),
        key("menus", "chatMenuLinkedChatRow", "chats.chatMenuItemLinkedChat"),
        key("menus", "chatMenuToBeginningRow", "chats.chatMenuItemToBeginning"),
        key("menus", "chatMenuGoToMessageRow", "chats.chatMenuItemGoToMessage"),
        key("menus", "chatMenuHideTitleRow", "chats.chatMenuItemHideTitle"),
        key("menus", "chatMenuViewDeletedRow", "chats.chatMenuItemViewDeleted"),
        key("menus", "chatMenuClearDeletedRow", "chats.chatMenuItemClearDeleted"),
        key("menus", "chatMenuDeleteOwnRow", "chats.chatMenuItemDeleteOwnMessages"),
        key("menus", "menuCopyPhotoRow", "chats.showCopyPhoto"),
        key("menus", "menuSaveRow", "chats.showAddToSavedMessages"),
        key("menus", "menuRepeatRow", "chats.showRepeat"),
        key("menus", "menuClearRow", "chats.showDeleteDownloadedFile"),
        key("menus", "menuHistoryRow", "chats.showViewHistory"),
        key("menus", "menuReportRow", "chats.showReport"),
        key("menus", "menuDetailsRow", "chats.showMessageDetails"),
        key("menus", "menuReactionsRow", "chats.showReactions"),
        key("menus", "menuReplyInPrivateRow", "chats.showReplyInPrivate"),
        key("menus", "menuCopyLinkRow", "chats.showCopyLink"),
        key("menus", "menuCopyFrameRow", "chats.showCopyFrame"),
        key("menus", "menuCopyAsStickerRow", "chats.showCopyAsSticker"),
        key("menus", "menuAddToStickersRow", "chats.showAddToStickers"),
        key("menus", "menuAddToFavoritesRow", "chats.showAddToFavorites"),
        key("menus", "menuNoQuoteForwardRow", "chats.showNoQuoteForward"),
        key("menus", "menuSetReminderRow", "chats.showSetReminder"),
        key("menus", "menuBookmarkRow", "chats.showAddToBookmark"),
        key("menus", "menuRepeatAsCopyRow", "chats.showRepeatAsCopy"),
        key("menus", "menuTranslateRow", "ai.showTranslate"),
        key("menus", "menuTranslateLlmRow", "ai.showTranslateMessageLLM"),
        key("menus", "menuShareRow", "chats.showShareMessages"),
        key("menus", "menuHideRow", "chats.showMessageHide"),
        key("menus", "menuAdminActionsRow", "chats.showAdminActions"),
        key("menus", "menuPermissionsRow", "chats.showChangePermissions"),
        key("menus", "mediaMenuForwardRow", "chats.mediaViewerMenuItemForward"),
        key("menus", "mediaMenuNoQuoteForwardRow", "chats.mediaViewerMenuItemNoQuoteForward"),
        key("menus", "mediaMenuCopyFrameRow", "chats.mediaViewerMenuItemCopyFrame"),
        key("menus", "mediaMenuCopyPhotoRow", "chats.mediaViewerMenuItemCopyPhoto"),
        key("menus", "mediaMenuProfilePhotoRow", "chats.mediaViewerMenuItemSetProfilePhoto"),
        key("menus", "mediaMenuQrRow", "chats.mediaViewerMenuItemScanQRCode"),
        key("menus", "actionBarReplyRow", "chats.ActionBarButtonReply"),
        key("menus", "actionBarEditRow", "chats.ActionBarButtonEdit"),
        key("menus", "actionBarSelectBetweenRow", "chats.ActionBarButtonSelectBetween"),
        key("menus", "actionBarCopyRow", "chats.ActionBarButtonCopy"),
        key("menus", "actionBarForwardRow", "chats.ActionBarButtonForward"),

        key("media", "videoMessagesCamera|videoMessagesCameraRow", "tools.videoMessageCameraFacing", from: ["chats"]),
        key("media", "rememberLastUsedCamera|rememberLastUsedCameraRow", "tools.rememberLastUsedCamera", from: ["chats"]),
        key("media", "zoomSlider|zoomSliderRow", "tools.zoomSlider", from: ["chats"]),
        key("media", "staticZoom|staticZoomRow", "tools.staticZoom", from: ["chats"]),
        focus("media", "extendedSettings|extendedSettingsGroupRow", "tools.extendedFramesPerSecond", from: ["chats"]),
        key("media", "extendedFpsRow", "tools.extendedFramesPerSecond"),
        key("media", "cameraStabilizationRow", "tools.cameraStabilization"),
        key("media", "cameraMirrorModeRow", "tools.cameraMirrorMode"),
        key("media", "startWithWideAngleRow", "tools.startWithWideAngleCamera"),
        key("media", "alwaysSendInHD|alwaysSendHdRow", "chats.alwaysSendInHD", from: ["chats"]),
        key("media", "hdrPhotos|hdrPhotosRow", "chats.hdrPhotos", from: ["chats"]),
        key("media", "enhancedVideoBitrate|EnhancedVideoBitrate|enhancedVideoBitrateRow", "tools.enhancedVideoBitrate", from: ["other"]),
        key("media", "noiseSuppressAndVoiceEnhance|NoiseSuppressAndVoiceEnhance|voiceEnhancementsRow", "tools.voiceEnhancement", from: ["other"]),
        absent("media", "disableInstantCamera|DisableInstantCamera|disableInstantCameraRow", "Disable Android instant camera", "The Android instant-camera toggle has no separately registered native control.", from: ["chats"]),
        key("media", "doubleTapSeekDuration|doubleTapSeekDurationRow", "chats.doubleTapSeekDuration", from: ["chats"]),
        key("media", "preferOriginalQuality|preferOriginalQualityRow", "chats.preferOriginalQuality", from: ["chats"]),
        key("media", "swipeToPip|swipeToPipRow", "chats.swipeToPip", from: ["chats"]),
        key("media", "showSmallGIF|ShowSmallGIF|showSmallGifRow", "chats.showSmallGIF", from: ["chats"]),
        key("media", "dontAutoPlayNextVoice|DontAutoPlayNextVoice|dontAutoPlayNextVoiceRow", "chats.dontAutoPlayNextVoice", from: ["chats"]),
        key("media", "disableProximityEvents|DisableProximityEvents|disableProximityEventsRow", "chats.disableProximityEvents", from: ["chats"]),
        focus("media", "pauseOnMinimize|pauseGroupRow", "chats.autoPauseVideo", from: ["chats"]),
        key("media", "pauseVideoRow", "chats.autoPauseVideo"),
        key("media", "pauseVoiceRow", "chats.pauseOnMinimizeVoice"),
        key("media", "pauseRoundRow", "chats.pauseOnMinimizeRound"),
        action("media", "videoPlayerDecoder|VideoPlayerDecoder|videoPlayerDecoderRow", "appearance.playerDecoderInfo", from: ["chats"]),
        action("media", "transcribeProvider|TranscribeProviderShort|transcribeProviderRow|cloudflareCredentials|CloudflareCredentials|cloudflareCredentialsRow|transcribeProviderOpenAI|TranscribeProviderOpenAI|openAiCredentialsRow|voskModels|VoskModelsShort|voskModelsRow", "ai.speech", from: ["chats"]),
        action("media", "llmProviderGeminiKey|LlmProviderGeminiKey|geminiApiKeyRow", "ai.translationModels", from: ["chats"]),
        absent("media", "cameraType|cameraTypeRow|seamlessSwitchingRow", "Android camera engine", "Android Camera2/CameraX engine and seamless-switch selectors have no native iOS provider.", from: ["chats"]),
        absent("media", "unmuteWithVolumeButtons|unmuteWithVolumeButtonsRow", "Unmute with volume buttons", "This Original volume-button control has no registered native settings provider.", from: ["chats"]),

        key("hiding", "hideActionBarStatus|hideActionBarStatusRow", "appearance.hideActionBarStatus", from: ["appearance"]),
        key("hiding", "hideStories|HideStoriesFromHeader|hideStoriesRow", "appearance.hideStoriesFromHeader", from: ["appearance"]),
        key("hiding", "DisableStories", "chats.disableStories", from: ["appearance"]),
        key("hiding", "hideFloatingButton|hideFloatingButtonRow", "appearance.disableDialogsFloatingButton", from: ["appearance"]),
        key("hiding", "hideSearchBar|hideSearchBarRow", "appearance.hideDialogsSearchField", from: ["appearance"]),
        key("hiding", "hideAllChats|hideAllChatsRow", "appearance.hideAllTab", from: ["appearance"]),
        key("hiding", "hideSendAsPeer|hideSendAsPeerRow", "chats.hideSendAsChannel", from: ["chats"]),
        key("hiding", "hideShareButton|hideShareButtonRow", "chats.hideShareButtonInChannel", from: ["chats"]),
        key("hiding", "hideGiftButton|hideGiftButtonRow", "chats.hideGiftButtonInChannel", from: ["chats"]),
        key("hiding", "hideSearchButton|hideSearchButtonRow", "chats.hideChannelSearchButton", from: ["chats"]),
        key("hiding", "hideCallButton|hideCallButtonRow", "chats.hideCallButton"),
        key("hiding", "hideMoneyButton|hideMoneyButtonRow", "chats.hideMoneyButton"),
        focus("hiding", "hideReactions|hideReactionsGroupRow", "chats.hideReactionsInChannels", from: ["chats"]),
        key("hiding", "hideReactionsChannelsRow", "chats.hideReactionsInChannels"),
        key("hiding", "hideReactionsGroupsRow", "chats.hideReactionsInGroups"),
        key("hiding", "hideReactionsPrivateRow", "chats.hideReactionsInPrivate"),
        key("hiding", "hideCameraTile|hideCameraTileRow", "chats.hideCameraTile", from: ["chats"]),
        key("hiding", "disableTrending|DisableTrending|disableTrendingRow", "chats.disableTrending", from: ["chats"]),
        key("hiding", "hideGroupSticker|hideGroupStickerRow", "chats.hideGroupSticker", from: ["chats"]),
        key("hiding", "disableGreeting|disableGreetingRow", "chats.dontSendGreetingSticker", from: ["chats"]),
        focus("hiding", "premiumElements|PremiumElements|premiumElementsGroupRow", "identity.premiumItemEmojiStatus", from: ["chats"]),
        key("hiding", "premiumEmojiStatusRow", "identity.premiumItemEmojiStatus"),
        key("hiding", "premiumEmojiInRepliesRow", "identity.premiumItemEmojiInReplies"),
        key("hiding", "premiumColorsInRepliesRow", "identity.premiumItemCustomColorInReplies"),
        key("hiding", "premiumWallpapersRow", "identity.premiumItemCustomWallpaper"),
        key("hiding", "premiumVideoAvatarsRow", "identity.premiumItemVideoAvatar"),
        key("hiding", "premiumStarReactionsRow", "identity.premiumItemStarInReactions"),
        key("hiding", "premiumStickerEffectsRow", "identity.premiumItemStickerEffects"),
        key("hiding", "premiumBoostsRow", "identity.premiumItemBoosts"),
        focus("hiding", "hideAi|hideAiGroupRow", "appearance.hideAiEditor", from: ["appearance"]),
        key("hiding", "hideAiEditor|hideAiEditorRow", "appearance.hideAiEditor", from: ["appearance"]),
        key("hiding", "hideAiSummary|hideAiSummaryRow", "appearance.hideMessageSummary", from: ["appearance"]),
        key("hiding", "hideAiIv|hideAiIvRow", "appearance.hideIvSummary", from: ["appearance"]),
        focus("hiding", "hideSettingsSections|hideSettingsGroupRow", "appearance.hidePremiumSection", from: ["appearance"]),
        key("hiding", "hidePremiumSection|HidePremiumSection|hidePremiumSectionRow", "appearance.hidePremiumSection", from: ["appearance"]),
        key("hiding", "hideHelpSection|HideHelpSection|hideHelpSectionRow", "appearance.hideHelpSection", from: ["appearance"]),

        action("other", "ayuMoments|ayuMomentsRow", "retention.archive"),
        key("other", "crashReports|crashReportsRow", "tools.crashReports"),
        key("other", "contentCapture|contentCaptureRow", "privacy.contentCapture"),
        action("other", "localPremium|localPremiumRow", "identity.account"),
        action("other", "exportEtgSettings|exportEtgRow|importEtgSettings|importEtgRow", "tools.backup"),
        action("other", "resetSettings|resetSettingsRow", "general.settingsReset"),
        absent("other", "deleteAccount|deleteAccountRow", "Delete account", "Use Telegram's native Delete Account settings. Account deletion is not a client action-registry route."),
        absent("other", "sensitiveDisableFiltering|SensitiveDisableFiltering|sensitiveContentRow", "Sensitive content", "Use native Data and Storage. Server-sensitive-content consent is not the local restriction-display preference."),

        action("ayumoments", "ayuGhost|ghostRow", "privacy.ghost"),
        key("ayumoments", "AskBeforeOpeningStory|askStoryRow", "privacy.askBeforeOpeningStory"),
        key("ayumoments", "SaveLocalLastSeen|saveLastSeenRow", "privacy.saveLocalLastSeen"),
        key("ayumoments", "SaveReadDate|saveReadDateRow", "privacy.saveReadDate"),
        key("ayumoments", "EnableSaveDeletedMessages|saveDeletedRow", "privacy.enableSaveDeletedMessages"),
        key("ayumoments", "EnableSaveEditsHistory|saveEditsRow", "privacy.enableSaveEditsHistory"),
        key("ayumoments", "SaveDeletedExceptionsMode|deletedExceptionsModeRow", "privacy.saveDeletedExceptionsMode"),
        key("ayumoments", "SaveEditedExceptionsMode|editedExceptionsModeRow", "privacy.saveEditedExceptionsMode"),
        key("ayumoments", "saveInArchived|saveInArchivedRow", "privacy.saveInArchivedChats"),
        focus("ayumoments", "MessageSavingSaveMedia|saveMediaRow", "privacy.messageSavingSaveMedia"),
        key("ayumoments", "saveMediaPrivateChatsRow", "privacy.saveMediaInPrivateChats"),
        key("ayumoments", "saveMediaPublicChannelsRow", "privacy.saveMediaInPublicChannels"),
        key("ayumoments", "saveMediaPrivateChannelsRow", "privacy.saveMediaInPrivateChannels"),
        key("ayumoments", "saveMediaPublicGroupsRow", "privacy.saveMediaInPublicGroups"),
        key("ayumoments", "saveMediaPrivateGroupsRow", "privacy.saveMediaInPrivateGroups"),
        key("ayumoments", "SaveDeletedInPrivateChats|saveDeletedPrivateRow", "privacy.saveDeletedInPrivateChats"),
        key("ayumoments", "SaveDeletedInGroups|saveDeletedGroupsRow", "privacy.saveDeletedInGroups"),
        key("ayumoments", "SaveDeletedInChannels|saveDeletedChannelsRow", "privacy.saveDeletedInChannels"),
        key("ayumoments", "SaveDeletedMessageForBotUser|botUserRow", "privacy.saveDeletedMessageForBotUser"),
        key("ayumoments", "SaveDeletedMessageForBot|botChatRow", "privacy.saveDeletedMessageForBot"),
        key("ayumoments", "ReplyToDeletedAsQuote|replyToDeletedRow", "chats.replyToDeletedAsQuote"),
        key("ayumoments", "TranslucentDeletedMessages|translucentRow", "chats.translucentDeletedMessages"),
        key("ayumoments", "UseDeletedIcon|deletedIconRow", "chats.useDeletedIcon"),
        key("ayumoments", "CustomDeletedMark|deletedMarkRow", "chats.customDeletedMark"),
        key("ayumoments", "DeletedMarkColor|deletedMarkColorRow", "chats.deletedMarkColor"),
        key("ayumoments", "ForwardProtectedAsCopy|forwardProtectedRow", "privacy.forwardProtectedAsCopy"),
        action("ayumoments", "RegexFiltersEnabled|regexRow", "privacy.localFilters"),
        action("ayumoments", "databaseExport|exportDbRow|ayuClearDatabase|clearDbRow", "retention.archive"),
        action("ayumoments", "databaseImport|importDbRow", "retention.importAyu"),
        absent("ayumoments", "ayuDisableAll|disableAllRow", "Disable all Ayu features", "No native composite provider disables retention, ghost mode and its menu/pill shortcuts together. Use the named controls."),

        key("cloud", "cloudAutoSync|autoSyncRow", "cloud.autoSync"),
        action("cloud", "cloudApiKeys|apiKeysRow", "cloud.settings"),
        action("cloud", "cloudUpload|uploadRow|cloudRestore|restoreRow|cloudClear|clearRow|cloudStatus|cloudActions|cloudOptions", "cloud.settings"),
        action("api", "custom_api|customApi|custom_app_id|customAppId|custom_app_hash|customAppHash", "clientAPI.edit"),
        absent("glyph", "glyphEnableRow|glyphNewMessageRow|glyphCallsRow|glyphRecordingRow|glyphScreenOffRow|glyphPreview|glyphPreviewRow", "Nothing Glyph preview", "Nothing Phone rear-light hardware and SDK are unavailable on iOS.")
    ]

    public static var unavailableRows: [Row] { rows.filter { if case .unavailable = $0.route { return true }; return false } }

    public static func aliases(for route: ClientSettingsRoute) -> [String] {
        func same(_ lhs: ClientSettingsRoute, _ rhs: ClientSettingsRoute) -> Bool {
            switch (lhs, rhs) {
            case let (.setting(a), .row(b)), let (.row(a), .setting(b)): return a == b
            default: return lhs == rhs
            }
        }
        return rows.filter { same($0.route, route) }.flatMap { [$0.page] + $0.names }
    }

    /// Exact class redirects read from ClassAliases.java:26-41. A Chats owner can
    /// own four constructor modes; its row disambiguates them, never a first match.
    private static let classes: [(names: [String], pages: [String])] = [
        (["app.exteraless.settings.OpenExteraSettingsActivity", "OpenExteraSettingsActivity", "com.exteragram.messenger.preferences.MainPreferencesActivity"], ["settings"]),
        (["app.exteraless.settings.OpenExteraGeneralActivity", "OpenExteraGeneralActivity", "com.exteragram.messenger.preferences.GeneralPreferencesActivity"], ["general"]),
        (["app.exteraless.settings.OpenExteraAppearanceActivity", "OpenExteraAppearanceActivity", "com.exteragram.messenger.preferences.AppearancePreferencesActivity", "com.exteragram.messenger.preferences.appearance.AppearancePreferencesActivity"], ["appearance"]),
        (["app.exteraless.settings.OpenExteraChatsActivity", "OpenExteraChatsActivity", "com.exteragram.messenger.preferences.ChatsPreferencesActivity"], ["chats", "menus", "media", "hiding"]),
        (["app.exteraless.settings.OpenExteraOtherActivity", "OpenExteraOtherActivity", "com.exteragram.messenger.preferences.OtherPreferencesActivity"], ["other"]),
        (["app.exteraless.settings.OpenExteraAppNavigationActivity", "OpenExteraAppNavigationActivity", "com.exteragram.messenger.preferences.AppNavigationPreferencesActivity"], ["navigation"]),
        (["app.exteraless.settings.OpenExteraAyuMomentsActivity", "OpenExteraAyuMomentsActivity"], ["ayumoments"]),
        (["app.exteraless.settings.OpenExteraCloudActivity", "OpenExteraCloudActivity"], ["cloud"]),
        (["app.exteraless.settings.OpenExteraGlyphActivity", "OpenExteraGlyphActivity"], ["glyph"]),
        (["app.exteraless.icons.IconPacksActivity", "com.exteragram.messenger.icons.ui.IconPacksActivity"], ["iconpacks"]),
        (["app.exteraless.pillstack.PillStackSettingsActivity", "com.exteragram.messenger.pillstack.ui.PillStackPreferencesActivity"], ["pillstack"]),
        (["app.exteraless.pillstack.pills.weather.WeatherSettingsActivity", "com.exteragram.messenger.pillstack.ui.pills.weather.WeatherPreferencesActivity"], ["pillstackweather"]),
        (["com.exteragram.messenger.preferences.BasePreferencesActivity"], ["base"]),
        (["tw.nekomimi.nekogram.settings.NekoTranslatorSettingsActivity"], ["general"])
    ]

    private static let pageAliases: [String: String] = [
        "exteraless": "settings", "exteraless_general": "general", "exteraless_appearance": "appearance",
        "exteraless_chats": "chats", "exteraless_menus": "menus", "exteraless_media": "media", "exteraless_hiding": "hiding",
        "exteraless_other": "other", "exteraless_ayumoments": "ayumoments", "exteraless_navigation": "navigation",
        "exteraless_cloud": "cloud", "exteraless_glyph": "glyph", "exteraless_ai": "ai",
        "translator": "general", "translate": "general", "t": "general", "emoji": "emoji",
        "g": "general", "c": "chats", "chat": "chats", "e": "other", "experimental": "other"
    ]

    private static func page(_ name: String) -> String {
        let name = name.hasPrefix("nasettings/") ? String(name.dropFirst("nasettings/".count)) : name
        return pageAliases[name] ?? name
    }

    public static func resolve(page inputPage: String?, className: String?, row: String?) throws -> ClientSettingsRoute {
        guard [inputPage, className, row].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw ClientSettingsRouteError.invalidLink
        }
        var pages: Set<String>?
        var classPages: Set<String>?
        var classDefault: String?
        if let className {
            let matches = classes.filter { $0.names.contains(className) }
            guard matches.count == 1, let match = matches.first else {
                throw matches.isEmpty ? ClientSettingsRouteError.notFound : ClientSettingsRouteError.ambiguous
            }
            classPages = Set(match.pages)
            pages = classPages
            classDefault = match.pages.first
        }
        if let inputPage {
            let value = page(inputPage)
            guard pages == nil || pages!.contains(value) else { throw ClientSettingsRouteError.ambiguous }
            pages = [value]
        }
        if let row {
            var candidates = Set<ClientSettingsRoute>()
            for entry in rows where entry.names.contains(row) {
                if let pages, pages.isDisjoint(with: [entry.page] + entry.previousPages) { continue }
                candidates.insert(entry.route)
            }
            // SettingsHelper.NAGRAM_ROWS moves these exact original aliases.
            // A legacy page redirect never discards an explicit class constraint.
            if inputPage?.hasPrefix("nasettings/") == true, candidates.isEmpty,
               ["HidePremiumSection", "HideHelpSection", "HideStoriesFromHeader", "DisableStories", "MainTabsHideTitles", "MainTabsHideContacts", "MainTabsHideCallsSettings", "MainTabsHideProfile", "AlwaysShowDownloadIcon", "VideoPlayerDecoder"].contains(row) {
                candidates.formUnion(rows.filter { entry in
                    entry.names.contains(row)
                        && (classPages.map { !$0.isDisjoint(with: [entry.page] + entry.previousPages) } ?? true)
                }.map(\.route))
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw candidates.isEmpty ? ClientSettingsRouteError.notFound : ClientSettingsRouteError.ambiguous
            }
            return candidate
        }
        let target = inputPage.map(page) ?? classDefault ?? "settings"
        switch target {
        case "settings": return .root
        case "general": return .row("appearance.disableNumberRounding")
        case "appearance": return .row("appearance.avatarCorners")
        case "chats": return .row("chats.stickerSize")
        case "menus": return .row("chats.bottomButton")
        case "media": return .row("tools.videoMessageCameraFacing")
        case "hiding": return .row("appearance.hideStoriesFromHeader")
        case "navigation": return .row("appearance.tabletMode")
        case "other": return .row("tools.crashReports")
        case "ayumoments": return .row("privacy.enableSaveDeletedMessages")
        case "cloud": return .action("cloud.settings")
        case "api": return .action("clientAPI.edit")
        case "ai": return .action("ai.services")
        case "pillstack": return .action("pills.status")
        case "pillstackweather": return .unavailable("Open Weather settings from Status Pills; the nested weather page has no independent registered action.")
        case "base": return .unavailable("The Android base fragment is not a native settings page.")
        case "iconpacks": return .action("appearance.iconPacks")
        case "emoji": return .action("stickers.emojiPacks")
        case "glyph": return .unavailable("Nothing Phone rear-light hardware and SDK are unavailable on iOS.")
        default: throw ClientSettingsRouteError.notFound
        }
    }
}
