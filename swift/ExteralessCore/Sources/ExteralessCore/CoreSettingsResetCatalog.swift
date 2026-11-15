import Foundation

public enum CoreSettingsResetScope: String, CaseIterable, Hashable, Sendable {
    case general
    case exteraless
    case allOriginal

    public var title: String {
        switch self {
        case .general: return "General settings"
        case .exteraless: return "Exteraless settings"
        case .allOriginal: return "All Original preference scopes"
        }
    }

    public var originalMethod: String {
        switch self {
        case .general: return "GeneralConfig.reset"
        case .exteraless: return "GeneralHelper.resetSettings"
        case .allOriginal: return "GeneralHelper.resetAllSettings"
        }
    }
}

public enum CoreSettingsResetGroup: String, CaseIterable, Hashable, Sendable {
    case openExtera, general, appearance, chats, icons, pills, utils, neko, nagram, glyph, cloud, clientAPI, otherNeko

    public var title: String {
        switch self {
        case .openExtera: return "OpenExtera"
        case .general: return "General"
        case .appearance: return "Appearance and player"
        case .chats: return "Chats and camera"
        case .icons: return "Icon pack preferences"
        case .pills: return "Status pill preferences and caches"
        case .utils: return "Navigation gestures"
        case .neko: return "Neko preferences"
        case .nagram: return "Nagram preferences"
        case .glyph: return "Nothing Glyph"
        case .cloud: return "Cloud sync preferences"
        case .clientAPI: return "Saved API mode, ID and hash"
        case .otherNeko: return "Other Original nkmrcfg preferences"
        }
    }

    public var preferenceNamespace: String {
        switch self {
        case .cloud: return "nekocloud"
        case .clientAPI: return "nekox_config"
        default: return "nkmrcfg"
        }
    }

    var owner: String {
        switch self {
        case .openExtera: return "OpenExteraConfig"
        case .general: return "GeneralConfig"
        case .appearance: return "AppearanceConfig"
        case .chats: return "ChatsConfig"
        case .icons: return "IconPacksConfig"
        case .pills: return "PillStackConfig"
        case .utils: return "UtilsConfig"
        case .neko: return "NekoConfig"
        case .nagram: return "NaConfig"
        case .glyph: return "GlyphConfig"
        case .cloud: return "CloudSettingsHelper"
        case .clientAPI: return "NekoXConfig"
        case .otherNeko: return ""
        }
    }
}

public struct CoreSettingsResetSourceField: Equatable, Sendable {
    public let group: CoreSettingsResetGroup
    public let symbol: String
    public let preferenceKey: String
    public var preferenceNamespace: String { self.group.preferenceNamespace }
    public var id: String { self.symbol }
}

/// Frozen source identities, not a catalogue of invented native settings. The
/// runtime joins this allowlist to actual registered definitions only. No Python
/// import, Android preference-file scan or filesystem deletion is performed.
public enum CoreSettingsResetCatalog {
    public static let retainedOriginalMarkers: Set<String> = ["OELegacyDefaultsPinned", "OELegacyDefaultsGeneration"]
    public static let retainedOriginalGeneration = 2

    /// Full-file SHA-256 pins under third_party/exteraless-android/TMessagesProj/src/main.
    public static let sourcePins: [String: String] = [
        "java/app/exteraless/general/GeneralHelper.java": "9c380a420e3d9d7584f2faee17e8cd6c298b6851cf685cc32fba214e85a14bfc",
        "java/app/exteraless/config/LegacyDefaults.java": "115fdc4d1185bdd9d257dde8885816f6f0989c74c3bc365e82702751ce42020a",
        "java/app/exteraless/ai/AiConfig.java": "398249c0a4354ceaaa28183335d8d2e8c440adac81f54b6c873c12c8e6cd71f2",
        "java/com/exteragram/messenger/ExteraConfig.java": "384de71c6f5870facf969ad2ad915a1ed40f34a2da405e01eda72542482c0239",
        "kotlin/app/exteraless/OpenExteraConfig.kt": "8294a20ceb3e81ad2c6e0809a61b2b5f4e3ca2ebadaad0bf5b04b463cce164ec",
        "kotlin/app/exteraless/general/GeneralConfig.kt": "c5d9eb589032deb71b696b6b57946c6d23dee8d05a382608faf32632f86bff51",
        "kotlin/app/exteraless/appearance/AppearanceConfig.kt": "8092bb53568040d010df1ec6fa1f269f666c4cb1b072cc642cce7bfee32ee187",
        "kotlin/app/exteraless/chats/ChatsConfig.kt": "a342a836244edc83b3beb920d352f1cbe202b418220e0b16b35d6a223ce5e614",
        "kotlin/app/exteraless/icons/IconPacksConfig.kt": "8bf472bb5ce785e41cddf6bebd4a023a945258d64fa300a05bdf9f3f95190630",
        "kotlin/app/exteraless/pillstack/PillStackConfig.kt": "00cc8274e49c41da3cfbf69a59f9235bde12c3ada6efc49496806ed81f20e811",
        "kotlin/app/exteraless/utils/UtilsConfig.kt": "c8f3d16230e3480a7053ca43363029e2e96a12cb1fdc8f2eae4b98c76626d226",
        "kotlin/app/exteraless/glyph/GlyphConfig.kt": "d6257ca6802d7aff3d62597cb3602c69d201a6eb6ddca68c3ab8c497cd227d6c",
        "java/tw/nekomimi/nekogram/NekoConfig.java": "9dab494987cce3fdc7a4271630a4925daca74d2a3ce3675c08227b1562e183ec",
        "kotlin/xyz/nextalone/nagram/NaConfig.kt": "495356be6d7050b4c5ca313ff5d4bb6be61d6ce4f3022c47fcddead222014646",
        "java/tw/nekomimi/nekogram/NekoXConfig.java": "24cf8b9aac5f5410102af754afbcee6d953df99e5c9c2a1febe8b9e7a0c53e64",
        "java/tw/nekomimi/nekogram/helpers/CloudSettingsHelper.java": "fcb12b0ee6f4cd5430968a29b546b145409b55a1c0acf16f01f07b41dcd632d0",
        "java/com/radolyn/ayugram/utils/AyuGhostPreferences.java": "807c026af1d0642973531ad903470d96c7800359e601fd7fab44ae8e9f0e2229",
        "java/com/radolyn/ayugram/messages/AyuSavePreferences.java": "707f8a4d98d3379a7a3d898995a18a5d578bded6b89071c0acf020d99336e5c1",
        "java/tw/nekomimi/nekogram/helpers/LocalNameHelper.java": "60fae18cc315779d6abca4d30df92695f692f01417963512f146b2187c910527",
        "java/tw/nekomimi/nekogram/DialogConfig.java": "daf068484584108a5c44e2d6180927e9490850334dfabf0ee0060779e635aef0",
        "java/org/telegram/ui/MainTabsLayout.java": "2fde86f0682a3c39f33c87b406e7666749c4195b18e9552a8d77351dd9df2d37",
        "java/org/telegram/ui/Components/ChatAttachAlertPhotoLayout.java": "f58fd6f80aa4ba193bd72932e622dac7410daaaf3b8478ea1cd22a79c4227acf",
        "java/tw/nekomimi/nekogram/translate/Translator.kt": "21bc6054edfa89bf14fdf2d206f6475110f52b89e7e31200b50fb45d64c0fe51",
        "java/app/exteraless/speech/VoskManager.java": "9c27cdf0321d2627ac68e480413c9aa7842657870bcd72d269678a924258c408",
        "java/app/exteraless/settings/OpenExteraOtherActivity.java": "333376bacc300b7548f686dd38a58abbe8f09fed5c0419f0fc8925dff44c77a3"
    ]

    public static func fields(for scope: CoreSettingsResetScope) -> [CoreSettingsResetSourceField] {
        return allFields.filter { field in
            switch scope {
            case .general: return field.group == .general
            case .exteraless:
                return selectedGroups.contains(field.group) || selectedExternalSymbols.contains(field.symbol)
            case .allOriginal: return true
            }
        }
    }

    private static let selectedGroups: Set<CoreSettingsResetGroup> = [.openExtera, .general, .appearance, .chats, .icons, .pills, .utils]
    public static let selectedExternalSymbols: Set<String> = [
        "NekoConfig.disableNumberRounding", "NekoConfig.showSeconds", "NekoConfig.disableVibration", "NaConfig.zalgoFilter",
        "NekoConfig.translationProvider", "NekoConfig.translateToLang", "NekoConfig.uploadBoost", "NekoConfig.customSavePath",
        "NekoConfig.hidePhone", "NaConfig.idDcType", "NaConfig.hideArchive", "NekoConfig.openArchiveOnPull", "NaConfig.doNotUnarchiveBySwipe"
    ]

    public static func matches(_ definition: ClientSettingDefinition, source: CoreSettingsResetSourceField) -> Bool {
        let symbols = Set(definition.androidSymbols.map(self.canonicalSymbol))
        if symbols.contains(source.symbol) { return true }
        if let aliases = migratedSymbols[source.symbol], !symbols.isDisjoint(with: aliases) { return true }
        // These exact AI fields use the native AIFeatures helper's bare field
        // metadata. A key prefix by itself is never sufficient authority.
        let field = source.symbol.split(separator: ".").last.map(String.init) ?? ""
        if bareAIFields.contains(source.symbol), definition.key == "ai." + field, symbols.contains(field) { return true }
        if source.symbol == "VoskManager.language" {
            return definition.key == "ai.OEVoskLanguage" && symbols.contains("OEVoskLanguage")
        }
        if source.symbol == "Translator.inputTranslateLangForChat" {
            return definition.key.hasPrefix("ai.translateInputLang_") && symbols.contains("Translator.setInputTranslateLangForChat")
        }
        return false
    }

    private static func canonicalSymbol(_ symbol: String) -> String {
        let value = symbol.hasSuffix("()") ? String(symbol.dropLast(2)) : symbol
        for (qualified, short) in qualifiedOwners where value.hasPrefix(qualified + ".") {
            return short + String(value.dropFirst(qualified.count))
        }
        return value
    }

    private static let qualifiedOwners: [String: String] = [
        "app.exteraless.OpenExteraConfig": "OpenExteraConfig",
        "app.exteraless.general.GeneralConfig": "GeneralConfig",
        "app.exteraless.appearance.AppearanceConfig": "AppearanceConfig",
        "app.exteraless.chats.ChatsConfig": "ChatsConfig",
        "app.exteraless.icons.IconPacksConfig": "IconPacksConfig",
        "app.exteraless.pillstack.PillStackConfig": "PillStackConfig",
        "app.exteraless.utils.UtilsConfig": "UtilsConfig",
        "app.exteraless.glyph.GlyphConfig": "GlyphConfig",
        "tw.nekomimi.nekogram.NekoConfig": "NekoConfig",
        "xyz.nextalone.nagram.NaConfig": "NaConfig",
        "tw.nekomimi.nekogram.NekoXConfig": "NekoXConfig",
        "tw.nekomimi.nekogram.helpers.CloudSettingsHelper": "CloudSettingsHelper",
        "com.radolyn.ayugram.utils.AyuGhostPreferences": "AyuGhostPreferences",
        "com.radolyn.ayugram.messages.AyuSavePreferences": "AyuSavePreferences"
    ]

    private static let migratedSymbols: [String: Set<String>] = [
        "NaConfig.hideDividers": ["AppearanceConfig.dividerStyle"],
        "NaConfig.customTitleUserName": ["AppearanceConfig.titleText"],
        "NaConfig.disableChannelMuteButton": ["ChatsConfig.bottomButton"],
        "NaConfig.hideReactions": ["ChatsConfig.hideReactionsInChannels", "ChatsConfig.hideReactionsInGroups", "ChatsConfig.hideReactionsInPrivate"],
        "NaConfig.messageColoredBackground": ["ChatsConfig.replyBackground"],
        "NaConfig.disableProxyWhenVpnEnabled": ["OpenExteraConfig.proxyDisableConditions"],
        "nkmrcfg.IgnoreFolderCount": ["NaConfig.ignoreUnreadCount"],
        "nkmrcfg.IgnoreMutedCount": ["NaConfig.ignoreUnreadCount"],
        "nkmrcfg.SpringAnimation": ["NaConfig.backAnimationStyle"]
    ]

    private static let bareAIFields: Set<String> = [
        "NekoConfig.translateToLang", "NekoConfig.translateInputLang", "NekoConfig.showTranslate", "NekoConfig.googleCloudTranslateKey",
        "NaConfig.showTranslateMessageLLM", "NaConfig.preferredTranslateTargetLang", "NaConfig.keepTranslatorPreferences",
        "NaConfig.telegramUIAutoTranslate", "NaConfig.enableSeparateArticleTranslator", "NaConfig.translatorKeepMarkdown",
        "NaConfig.googleTranslateExp", "NaConfig.deepLTranslateKey", "NaConfig.llmApiUrl", "NaConfig.llmSystemPrompt", "NaConfig.llmUserPrompt",
        "NaConfig.llmUseContext", "NaConfig.llmUseContextInAutoTranslate", "NaConfig.translatorModeWithOriginalMigrated",
        "NaConfig.transcribeProviderCfAccountID", "NaConfig.transcribeProviderCfApiToken", "NaConfig.transcribeProviderGeminiApiKey",
        "NaConfig.transcribeProviderGeminiPrompt", "NaConfig.transcribeProviderOpenAiApiBase", "NaConfig.transcribeProviderOpenAiModel",
        "NaConfig.transcribeProviderOpenAiApiKey", "NaConfig.transcribeProviderOpenAiPrompt"
    ]

    public static func unavailableReason(for field: CoreSettingsResetSourceField) -> String {
        switch field.symbol {
        case "GeneralConfig.showNagramSettings": return "The obsolete parallel Android settings entry has no native definition."
        case "AppearanceConfig.centerTitle": return "This obsolete stored flag is not the active NaConfig header setting."
        case "ChatsConfig.cameraType": return "Android Camera1/Camera2/CameraX selection is not an iOS preference."
        case "IconPacksConfig.customNotificationIcon": return "iOS notification icons do not have this Android preference."
        case "NekoConfig.disableInstantCamera": return "Android's live attachment-camera preview switch has no distinct native setting."
        case "nkmrcfg.OEAppearanceTitleTextMigrated": return "This Original migration marker has no native client-setting definition."
        case "nkmrcfg.SendHighQualityPhoto": return "Original migrated this flag to mainconfig, which is outside these reset scopes."
        case "CloudSettingsHelper.localSyncedDate": return "Native sync timestamps are account-owned metadata, not a client-setting definition."
        case "NekoConfig.nameOrder", "NekoConfig.localPremium", "LocalNameHelper.chatNameOverride", "LocalNameHelper.userNameOverride":
            return "The native account-local editor owns this data; it is not in the shared client-settings store."
        case "AyuSavePreferences.saveDeletedExclusions", "AyuSavePreferences.saveEditedExclusions":
            return "Native per-peer retention exceptions are account-database data, outside this settings reset."
        default:
            if field.group == .glyph { return "Nothing Glyph requires Android/Nothing hardware." }
            return "No source-matched native definition is registered in this settings store."
        }
    }

    public static let allFields: [CoreSettingsResetSourceField] = {
        var result: [CoreSettingsResetSourceField] = []
        func add(_ group: CoreSettingsResetGroup, _ fields: String) {
            for token in fields.split(whereSeparator: { $0.isWhitespace }) {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                result.append(CoreSettingsResetSourceField(group: group, symbol: group.owner + "." + parts[0], preferenceKey: parts.count == 2 ? parts[1] : parts[0]))
            }
        }
        add(.general, """
        botPrivacyAlwaysAsk=OEGeneralBotPrivacyAlwaysAsk botPrivacyEnabled=OEGeneralBotPrivacyEnabled botPrivacyUserId=OEGeneralBotPrivacyUserId
        contentCapture=OEGeneralContentCapture crashReports=OEGeneralCrashReports downloadSpeedBoost=OEGeneralDownloadSpeedBoost showNagramSettings=OEGeneralShowNagramSettings
        """)
        add(.openExtera, "addCommaAfterMention=OEAddCommaAfterMention downloadEmojiPacks=OEDownloadEmojiPacks proxyDisableConditions=OEProxyDisableConditions relativeLastSeen=OERelativeLastSeen")
        add(.appearance, """
        avatarCorners=OEAppearanceAvatarCorners centerTitle=OEAppearanceCenterTitle customThemes=OEAppearanceCustomThemes dividerStyle=OEAppearanceDividerStyle glassMessageMenu=OEAppearanceGlassMessageMenu
        glassOutlineStyle=OEAppearanceGlassOutlineStyle gooeyAvatarAnimation=OEAppearanceGooeyAvatarAnimation hideActionBarStatus=OEAppearanceHideActionBarStatus hideAiEditor=OEAppearanceHideAiEditor hideIvSummary=OEAppearanceHideIvSummary
        hideMessageSummary=OEAppearanceHideMessageSummary immersiveDrawerAnimation=OEAppearanceImmersiveDrawer iosChatHeader=OEAppearanceIosChatHeader iosNavigationBarStyle=OEAppearanceIosNavigationBarStyle lrclibAllowed=OEPlayerLrclibAllowed
        m3ListItems=OEAppearanceM3ListItems mainMenuLayout=OEAppearanceMainMenuLayout md3MiniPlayer=OEAppearanceMd3MiniPlayer md3Player=OEAppearanceMd3Player monetStyle=OEAppearanceMonetStyle
        navigationDrawer=OEAppearanceNavigationDrawer newChatHeaderStyle=OEAppearanceNewChatHeaderStyle newLoadingStyle=OEAppearanceNewLoadingStyle newNavigationBarStyle=OEAppearanceNewNavigationBarStyle playerActionsStyle=OEPlayerActionsStyle
        playerBackground=OEPlayerBackground playerColors=OEPlayerColors playerControlsSize=OEPlayerControlsSize playerCoverExtend=OEPlayerCoverExtend playerCoverRadius=OEPlayerCoverRadius
        playerCoverSize=OEPlayerCoverSize playerCoverStyle=OEPlayerCoverStyle playerCoverSwipe=OEPlayerCoverSwipe playerDiscSpin=OEPlayerDiscSpin playerMiniArtist=OEPlayerMiniArtist
        playerMiniClose=OEPlayerMiniClose playerMiniColors=OEPlayerMiniColors playerMiniCompact=OEPlayerMiniCompact playerMiniCover=OEPlayerMiniCover playerMiniNext=OEPlayerMiniNext
        playerMiniPrevious=OEPlayerMiniPrevious playerMiniProgress=OEPlayerMiniProgress playerMiniShape=OEPlayerMiniShape playerMiniTop=OEPlayerMiniTop playerOrder=OEPlayerOrder
        playerShowActions=OEPlayerShowActions playerShowLike=OEPlayerShowLike playerShowModes=OEPlayerShowModes playerShowSource=OEPlayerShowSource playerTitleAbove=OEPlayerTitleAbove
        playerTitleAlign=OEPlayerTitleAlign playerTitleSize=OEPlayerTitleSize playerWavy=OEPlayerWavy profileMusicCard=OEAppearanceProfileMusicCard sectionRadius=OEAppearanceSectionRadius
        senderMiniAvatars=OEAppearanceSenderMiniAvatars separateHeaders=OEAppearanceSeparateHeaders showFeedTab=OEAppearanceShowFeedTab showFeedUnreadCounter=OEAppearanceFeedUnreadCounter singleCornerRadius=OEAppearanceSingleCornerRadius
        squareFab=OEAppearanceSquareFab titleText=OEAppearanceTitleText
        """)
        add(.chats, """
        alwaysSendInHD=OEChatsAlwaysSendInHD bottomButton=OEChatsBottomButton cameraMirrorMode=OEChatsCameraMirrorMode cameraStabilization=OEChatsCameraStabilization cameraType=OEChatsCameraType
        doubleTapSeekDuration=OEChatsDoubleTapSeekDuration extendedFramesPerSecond=OEChatsExtendedFps flashIntensity=OEChatsFlashIntensity flashWarmth=OEChatsFlashWarmth hdrPhotos=OEChatsHdrPhotos
        hideCallButton=OEChatsHideCallButton hideCameraTile=OEChatsHideCameraTile hideChannelSearchButton=OEChatsHideChannelSearchButton hideMoneyButton=OEChatsHideMoneyButton hideReactionsInChannels=OEChatsHideReactionsChannels
        hideReactionsInGroups=OEChatsHideReactionsGroups hideReactionsInPrivate=OEChatsHideReactionsPrivate inlineMathCurrency=OEChatsInlineMathCurrency inlineMathResult=OEChatsInlineMathResult keepAttachButton=OEChatsKeepAttachButton
        pauseOnMinimizeRound=OEChatsPauseRound pauseOnMinimizeVoice=OEChatsPauseVoice preferOriginalQuality=OEChatsPreferOriginalQuality rememberLastUsedCamera=OEChatsRememberLastUsedCamera removeMessageTail=OEChatsRemoveMessageTail
        replyBackground=OEChatsReplyBackground replyColors=OEChatsReplyColors replyEmoji=OEChatsReplyEmoji showResultsBeforeVoting=OEChatsShowResultsBeforeVoting startWithWideAngleCamera=OEChatsStartWithWideAngleCamera
        staticZoom=OEChatsStaticZoom stickerShape=OEChatsStickerShape stickerTimeSide=OEChatsStickerTimeSide stripTrackingOnOpen=OEChatsStripTrackingOnOpen stripTrackingOnPaste=OEChatsStripTrackingOnPaste
        swipeToPip=OEChatsSwipeToPip translateInSheet=OEChatsTranslateInSheet unmuteWithVolumeButtons=OEChatsUnmuteWithVolumeButtons unreadCapsule=OEChatsUnreadCapsule wideChannelPosts=OEChatsWideChannelPosts
        wideFeedPosts=OEChatsWideFeedPosts zoomSlider=OEChatsZoomSlider
        """)
        add(.icons, "activePacks=OEIconPacksActive customNotificationIcon=OEIconPacksNotificationIcon editingPackId=OEIconPacksEditing enabled=OEIconPacksEnabled useSystemIconShape=OEIconPacksSystemShape")
        add(.pills, """
        activePillsRaw=OEPillActivePills btcTargetCurrency=OEPillBtcCurrency ethTargetCurrency=OEPillEthCurrency eurTargetCurrency=OEPillEurCurrency goldPriceCache=OEPillGoldPriceCache
        goldPriceCacheTime=OEPillGoldPriceCacheTime goldTargetCurrency=OEPillGoldCurrency gramTargetCurrency=OEPillGramCurrency hiddenPillsRaw=OEPillHiddenPills infiniteScrolling=OEPillInfiniteScrolling
        lastActivePillId=OEPillLastActiveId rateInstancesMigrated=OEPillRateInstancesMigrated rateInstancesRaw=OEPillRateInstances ratesCache=OEPillRatesCache ratesCacheTime=OEPillRatesCacheTime
        usdTargetCurrency=OEPillUsdCurrency weatherAddress=OEPillWeatherAddress weatherLatitude=OEPillWeatherLat weatherLongitude=OEPillWeatherLon weatherUseCurrentLocation=OEPillWeatherCurrentLocation
        """)
        add(.utils, "predictiveBackIntensity=OEPredictiveBackIntensity")
        add(.glyph, "enabled=OEGlyphEnabled onCall=OEGlyphCalls onNewMessage=OEGlyphNewMessage onRecording=OEGlyphRecording screenOffOnly=OEGlyphScreenOff")
        add(.neko, """
        actionBarDecoration=ActionBarDecoration askBeforeCall=AskBeforeCalling autoPauseVideo=AutoPauseVideo cachePath=cache_path confirmAVMessage=ConfirmAVMessage
        customAudioBitrate customDoH=CustomDoH customSavePath disableAutoDownloadingArchive=ArchiveFiles disableAutoDownloadingWin32Executable=Win32ExecutableFiles
        disableChoosingSticker disableInstantCamera=DisableInstantCamera disableLinkPreviewByDefault=DisableLinkPreviewByDefault disableNotificationBubbles disableNumberRounding=DisableNumberRounding
        disableProximityEvents=DisableProximityEvents disableSwipeToNext=disableSwipeToNextChannel disableSwipeToNextTopic disableSystemAccount=DisableSystemAccount disableTrending=DisableTrending
        disableVibration=DisableVibration displayPersianCalendarByLatin=DisplayPersianCalendarByLatin dnsType=DnsType dontSendGreetingSticker=DontSendGreetingSticker enhancedFileLoader
        forceFontWeightFallback googleCloudTranslateKey=GoogleCloudTransKey hideAllTab=HideAllTab hideGroupSticker hideKeyboardOnChatScroll=HideKeyboardOnChatScroll
        hidePhone=HidePhone hideSendAsChannel hideTimeForSticker=HideTimeForSticker ignoreBlocked=IgnoreBlocked ignoreContentRestrictions
        localPremium mapDriftingFixForGoogleMaps mapPreviewProvider=MapPreviewProvider markReadAfterSend maxRecentStickerCount
        mediaPreview=MediaPreview minimizedStickerCreator nameOrder=NameOrder openArchiveOnPull=OpenArchiveOnPull rearVideoMessages=RearVideoMessages
        rememberAllBackMessages repeatConfirm sendCommentAfterForward=SendCommentAfterForward sendOfflinePacketAfterOnline sendOfflinePacketAfterOnlineLocked
        sendOnlinePackets sendOnlinePacketsLocked sendReadMessagePackets sendReadMessagePacketsLocked sendReadStoriesPackets
        sendReadStoriesPacketsLocked sendUploadProgress sendUploadProgressLocked showAddToSavedMessages showAdminActions
        showChangePermissions showDeleteDownloadedFile showGhostInDrawer showGhostModeStatus showIdAndDc=ShowIdAndDc
        showMessageDetails showMessageHide showRepeat showReport showSeconds
        showShareMessages showSpoilersDirectly showTranslate showViewHistory skipOpenLinkConfirm=SkipOpenLinkConfirm
        sortByContacts=sort_by_contacts sortByUnmuted=sort_by_unmuted sortByUnread=sort_by_unread sortByUser=sort_by_user stickerSize
        tabletMode=TabletMode tabsTitleType=TabTitleType takeGIFasVideo=TakeGIFasVideo translateInputLang=TransInputToLang translateToLang=TransToLang
        translationProvider typeface=TypefaceUseDefault unlimitedFavedStickers=UnlimitedFavoredStickers unlimitedPinnedDialogs=UnlimitedPinnedDialogs unreadBadgeOnBackButton
        uploadBoost useChatAttachMediaMenu=UseChatAttachEnterMenu useCustomEmoji useIPv6=IPv6 useOSMDroidMap
        usePersianCalendar=UsePersianCalendar useSystemEmoji=EmojiUseDefault
        """)
        add(.nagram, """
        ActionBarButtonCopy=Copy ActionBarButtonEdit=Edit ActionBarButtonForward=Forward ActionBarButtonReply=Reply ActionBarButtonSelectBetween=SelectBetween
        alwaysShowDownloadIcon=AlwaysShowDownloadIcon articleTranslationProvider=ArticleTranslationProvider askBeforeOpeningStory=AskBeforeOpeningStory autoUpdateChannel=AutoUpdateChannel backAnimationStyle=BackAnimationStyle
        blockedChannelsData=BlockedChannelsData cameraInVideoMessages=CameraInVideoMessages centerActionBarTitle=CenterActionBarTitle centerActionBarTitleType=CenterActionBarTitleType chatDecoration=ChatDecoration
        chatMenuItemBoostGroup=ChatMenuItemBoostGroup chatMenuItemClearDeleted=ChatMenuItemClearDeleted chatMenuItemDeleteOwnMessages=ChatMenuItemDeleteOwnMessages chatMenuItemGoToMessage=ChatMenuItemGoToMessage chatMenuItemHideTitle=ChatMenuItemHideTitle
        chatMenuItemLinkedChat=ChatMenuItemLinkedChat chatMenuItemToBeginning=ChatMenuItemToBeginning chatMenuItemViewDeleted=ChatMenuItemViewDeleted combineMessage=CombineMessage confirmAllLinks=ConfirmAllLinks
        customDeletedMark=CustomDeletedMark customEditedMessage=CustomEditedMessage customFilteredUsersData=CustomFilteredUsersData customTitle=CustomTitle customTitleUserName=CustomTitleUserName
        dateOfForwardedMsg=DateOfForwardedMsg deepLFormality=DeepLFormality deepLTranslateKey=DeepLTranslateKey defaultDeleteMenReportSpam=DeleteReportSpam defaultDeleteMenu=DefaultDeleteMenu
        defaultDeleteMenuBanUsers=DeleteBanUsers defaultDeleteMenuDeleteAll=DeleteAll defaultDeleteMenuDoActionsInCommonGroups=DoActionsInCommonGroups defaultHlsVideoQuality=DefaultHlsVideoQuality defaultScheduledTime=DefaultScheduledTime
        deleteChatForBothSides=DeleteChatForBothSides deletedMarkColor=DeletedMarkColor disableAvatarBlur=DisableAvatarBlur disableBotOpenButton=DisableBotOpenButton disableChannelMuteButton=DisableChannelMuteButton
        disableClickCommandToSend=DisableClickCommandToSend disableCrashlyticsCollection=DisableCrashlyticsCollection disableDialogsFloatingButton=DisableDialogsFloatingButton disableGlobalSearch=DisableGlobalSearch disableInAppBrowserGestures=DisableInAppBrowserGestures
        disableMarkdown=DisableMarkdown disablePreviewVideoSoundShortcut=DisablePreviewVideoSoundShortcut disableProxyWhenVpnEnabled=DisableProxyWhenVpnEnabled disableStories=DisableStories doNotUnarchiveBySwipe=DoNotUnarchiveBySwipe
        dontAutoPlayNextVoice=DontAutoPlayNextVoice doubleTapAction=DoubleTapAction doubleTapActionOut=DoubleTapActionOut enablePanguOnSending=EnablePanguOnSending enableSaveDeletedMessages=EnableSaveDeletedMessages
        enableSaveEditsHistory=EnableSaveEditsHistory enableSeparateArticleTranslator=EnableSeparateArticleTranslator enhancedVideoBitrate=EnhancedVideoBitrate fixLinkPreview=FixLinkPreview folderNameAsTitle=FolderNameAsTitle
        forwardProtectedAsCopy=ForwardProtectedAsCopy ghostScheduledSend=GhostScheduledSend googleTranslateExp=GoogleTranslateExp groupedMessageMenu=GroupedMessageMenu hideArchive=HideArchive
        hideBotButtonInInputField=HideBotButtonInInputField hideBottomNavigationBar=HideBottomNavigationBar hideDialogsSearchField=HideDialogsSearchField hideDividers=HideDividers hideGiftButtonInChannel=HideGiftButtonInChannel
        hideHelpSection=HideHelpSection hidePremiumSection=HidePremiumSection hideReactions=HideReactions hideShareButtonInChannel=HideShareButtonInChannel hideStoriesFromHeader=HideStoriesFromHeader
        iconReplacements=IconReplacements idDcType=IdDcType ignoreUnreadCount=IgnoreUnreadCount keepTranslatorPreferences=KeepTranslatorPreferences leftBottomButton=LeftBottomButtonAction
        llmApiKey=LlmApiKey llmApiUrl=LlmApiUrl llmContextSize=LlmContextSize llmModelName=LlmModelName llmProviderCerebrasKey=LlmProviderCerebrasKey
        llmProviderCerebrasModel=LlmProviderCerebrasModel llmProviderDeepSeekKey=LlmProviderDeepSeekKey llmProviderDeepSeekModel=LlmProviderDeepSeekModel llmProviderGeminiKey=LlmProviderGeminiKey llmProviderGeminiModel=LlmProviderGeminiModel
        llmProviderGroqKey=LlmProviderGroqKey llmProviderGroqModel=LlmProviderGroqModel llmProviderOllamaCloudKey=LlmProviderOllamaCloudKey llmProviderOllamaCloudModel=LlmProviderOllamaCloudModel llmProviderOpenAIKey=LlmProviderOpenAIKey
        llmProviderOpenAIModel=LlmProviderOpenAIModel llmProviderOpenRouterKey=LlmProviderOpenRouterKey llmProviderOpenRouterModel=LlmProviderOpenRouterModel llmProviderPreset=LlmProviderPreset llmProviderVercelAIGatewayKey=LlmProviderVercelAIGatewayKey
        llmProviderVercelAIGatewayModel=LlmProviderVercelAIGatewayModel llmProviderVertexKey=LlmProviderVertexKey llmProviderVertexModel=LlmProviderVertexModel llmProviderXAIKey=LlmProviderXAIKey llmProviderXAIModel=LlmProviderXAIModel
        llmSystemPrompt=LlmSystemPrompt llmTemperature=LlmTemperature llmUseContext=LlmUseContext llmUseContextInAutoTranslate=LlmUseContextInAutoTranslate llmUserPrompt=LlmUserPrompt
        mainTabsHideCallsSettings=MainTabsHideCallsSettings mainTabsHideContacts=MainTabsHideContacts mainTabsHideProfile=MainTabsHideProfile mainTabsHideTitles=MainTabsHideTitles markdownParser=MarkdownParser
        mediaViewerMenuItemCopyFrame=MediaViewerMenuItemCopyFrame mediaViewerMenuItemCopyPhoto=MediaViewerMenuItemCopyPhoto mediaViewerMenuItemForward=MediaViewerMenuItemForward mediaViewerMenuItemNoQuoteForward=MediaViewerMenuItemNoQuoteForward mediaViewerMenuItemScanQRCode=MediaViewerMenuItemScanQRCode
        mediaViewerMenuItemSetProfilePhoto=MediaViewerMenuItemSetProfilePhoto messageColoredBackground=MessageColoredBackground messageSavingSaveMedia=MessageSavingSaveMedia noiseSuppressAndVoiceEnhance=NoiseSuppressAndVoiceEnhance notificationIcon=NotificationIcon
        performanceClass=PerformanceClass pinnedReactionsChannels=PinnedReactionsChannels pinnedReactionsChats=PinnedReactionsChats playerDecoder=VideoPlayerDecoder preferCommonGroupsTab=PreferCommonGroupsTab
        preferredTranslateTargetLang=PreferredTranslateTargetLang premiumItemBoosts=PremiumItemBoosts premiumItemCustomColorInReplies=PremiumItemCustomColorInReplies premiumItemCustomWallpaper=PremiumItemCustomWallpaper premiumItemEmojiInReplies=PremiumItemEmojiInReplies
        premiumItemEmojiStatus=PremiumItemEmojiStatus premiumItemStarInReactions=PremiumItemStarInReactions premiumItemStickerEffects=PremiumItemStickerEffects premiumItemVideoAvatar=PremiumItemVideoAvatar pushServiceType=PushServiceType
        pushServiceTypeInAppDialog=PushServiceTypeInAppDialog pushServiceTypeUnifiedGateway=PushServiceTypeUnifiedGateway pushServiceTypeUnifiedSimple=PushServiceTypeUnifiedSimple pushServiceTypeUnifiedWebPushAuthSecret=PushServiceTypeUnifiedWebPushAuthSecret pushServiceTypeUnifiedWebPushPrivateKey=PushServiceTypeUnifiedWebPushPrivateKey
        pushServiceTypeUnifiedWebPushPublicKey=PushServiceTypeUnifiedWebPushPublicKey regexChatFiltersData=RegexChatFiltersData regexFiltersData=RegexFiltersData regexFiltersEnableInChats=RegexFiltersEnableInChats regexFiltersEnabled=RegexFilters
        regexFiltersExcludedDialogs=RegexFiltersExcludedDialogs replyToDeletedAsQuote=ReplyToDeletedAsQuote saveDeletedExceptionsMode=SaveDeletedExceptionsMode saveDeletedInChannels=SaveDeletedInChannels saveDeletedInGroups=SaveDeletedInGroups
        saveDeletedInPrivateChats=SaveDeletedInPrivateChats saveDeletedMessageForBot=SaveDeletedMessageForBot saveDeletedMessageForBotUser=SaveDeletedMessageForBotUser saveEditedExceptionsMode=SaveEditedExceptionsMode saveInArchivedChats=SaveInArchivedChats
        saveLocalLastSeen=SaveLocalLastSeen saveMediaInPrivateChannels=SaveMediaInPrivateChannels saveMediaInPrivateChats=SaveMediaInPrivateChats saveMediaInPrivateGroups=SaveMediaInPrivateGroups saveMediaInPublicChannels=SaveMediaInPublicChannels
        saveMediaInPublicGroups=SaveMediaInPublicGroups saveReadDate=OEAyuSaveReadDate saveToChatSubfolder=SaveToChatSubfolder searchHashtagDefaultPageChannel=SearchHashtagDefaultPageChannel searchHashtagDefaultPageChat=SearchHashtagDefaultPageChat
        sendLockedCustomEmojiAsSticker=SendLockedCustomEmojiAsSticker sendMp4DocumentAsVideo=SendMp4DocumentAsVideo shortcutsAdministrators=ChannelAdministrators shortcutsMembers=GroupMembers shortcutsPermissions=ChannelPermissions
        shortcutsRecentActions=EventLog shortcutsStatistics=Statistics showAddToBookmark=ShowAddToBookmark showAddToFavorites=AddToFavorites showAddToStickers=AddToStickers
        showCopyAsSticker=CopyPhotoAsSticker showCopyFrame=MessageMenuCopyFrame showCopyLink=CopyLink showCopyPhoto=CopyPhoto showFullAbout=ShowFullAbout
        showMessageID=ShowMessageID showNoQuoteForward=NoQuoteForward showNotificationPreviewWhenLocked=ShowNotificationPreviewWhenLocked showOnlineStatus=ShowOnlineStatus showQuickReplyInBotCommands=ShowQuickReplyInBotCommands
        showRPCError=ShowRPCError showReactions=Reactions showRepeatAsCopy=RepeatAsCopy showReplyInPrivate=ReplyInPrivate showSendAsUnderMessageHint=ShowSendAsUnderMessageHint
        showSetReminder=SetReminder showSmallGIF=ShowSmallGIF showStickersRowToplevel=ShowStickersRowToplevel showTextBold=TextBold showTextCreateDate=TextCreateDate
        showTextCreateLink=TextLink showTextCreateMention=TextCreateMention showTextItalic=TextItalic showTextMono=TextMonospace showTextMonoCode=TextMonoCode
        showTextQuote=TextQuote showTextRegular=TextRegular showTextSpoiler=TextSpoiler showTextStrikethrough=TextStrikethrough showTextTranslate=TextTranslate
        showTextUnderline=TextUnderline showTimeHint=ShowTimeHint showTranslateMessageLLM=TranslateMessageLLM silentMessageByDefault=SilentMessageByDefault sliderStyle=SliderStyle
        sortByUnread=SortByUnread springAnimationCrossfade=SpringAnimationCrossfade strokeOnViews=StrokeOnViews switchStyle=SwitchStyle telegramUIAutoTranslate=TelegramUIAutoTranslate
        textStyleOrder=TextStyleOrder transcribeProvider=TranscribeProvider transcribeProviderCfAccountID=TranscribeProviderCfAccountID transcribeProviderCfApiToken=TranscribeProviderCfApiToken transcribeProviderGeminiApiKey=TranscribeProviderGeminiApiKey
        transcribeProviderGeminiPrompt=TranscribeProviderGeminiPrompt transcribeProviderOpenAiApiBase=TranscribeProviderOpenAiApiBase transcribeProviderOpenAiApiKey=TranscribeProviderOpenAiApiKey transcribeProviderOpenAiModel=TranscribeProviderOpenAiModel transcribeProviderOpenAiPrompt=TranscribeProviderOpenAiPrompt
        translatorKeepMarkdown=TranslatorKeepMarkdown translatorMode=TranslatorMode translatorModeWithOriginalMigrated=TranslatorModeWithOriginalMigrated translucentDeletedMessages=TranslucentDeletedMessages typeMessageHintUseGroupName=TypeMessageHintUseGroupName
        unlimitedSavedGifs=UnlimitedSavedGifs useDeletedIcon=UseDeletedIcon useEditedIcon=UseEditedIcon useLocalEmojiStatusData useLocalQuoteColorData
        usePinnedReactionsChannels=UsePinnedReactionsChannels usePinnedReactionsChats=UsePinnedReactionsChats zalgoFilter=ZalgoFilter
        """)
        add(.cloud, "autoSync=auto_sync includeApiKeys=include_api_keys localSyncedDate=updated_at")
        add(.clientAPI, "customApi=custom_api customAppId=custom_app_id customAppHash=custom_app_hash")
        for (symbol, key) in [
            // Non-ConfigItem keys read by the pinned Appearance/Na migration
            // bodies. These are All-only; reset()'s ConfigItem loops omit them.
            ("nkmrcfg.OEAppearanceTitleTextMigrated", "OEAppearanceTitleTextMigrated"),
            ("nkmrcfg.IgnoreFolderCount", "IgnoreFolderCount"),
            ("nkmrcfg.IgnoreMutedCount", "IgnoreMutedCount"),
            ("nkmrcfg.SpringAnimation", "SpringAnimation"),
            ("nkmrcfg.SendHighQualityPhoto", "SendHighQualityPhoto"),
            ("AyuGhostPreferences.ghostModeReadExclusions", "ghostModeReadExclusion_*"),
            ("AyuGhostPreferences.ghostModeTypingExclusions", "ghostModeTypingExclusion_*"),
            ("AyuSavePreferences.saveDeletedExclusions", "saveDeletedExclusion_*"),
            ("AyuSavePreferences.saveEditedExclusions", "saveEditedExclusion_*"),
            ("LocalNameHelper.chatNameOverride", "chatNameOverride_*"),
            ("LocalNameHelper.userNameOverride", "userNameOverride_*"),
            ("DialogConfig.customForumTabsEnable", "customForumTabs_*"),
            ("MainTabsLayout.bottomNavigationFloating", "OEAppearanceBottomNavigationFloating"),
            ("Translator.inputTranslateLangForChat", "translateInputLang_*"),
            ("VoskManager.language", "OEVoskLanguage")
        ] {
            result.append(CoreSettingsResetSourceField(group: .otherNeko, symbol: symbol, preferenceKey: key))
        }
        return result
    }()
}
