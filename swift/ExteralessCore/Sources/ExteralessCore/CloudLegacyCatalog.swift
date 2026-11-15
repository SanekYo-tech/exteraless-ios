import Foundation

/// Source preference identity only. This table grants NO import permission: the
/// separate audited conversion table decides which fields can affect native state.
/// Pinned to docs/parity/client-features.json, not ExteraConfig shim overloads.
enum CloudLegacyCatalog {
    static let entries: [String: [String]] = {
        var result: [String: [String]] = [:]
        func add(_ group: String, _ section: String = "nkmrcfg", _ fields: String) {
            for item in fields.split(whereSeparator: { $0.isWhitespace }) {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                result[section + "." + (parts.count == 2 ? parts[1] : parts[0]), default: []].append(group + "." + parts[0])
            }
        }
        add("ai", "aiConfig", """
        disableTools history insertAsQuote replaceTelegramEditor replaceTelegramSummaries responseStreaming roles saveHistory selectedRole
        selectedServiceHash=selectedService selectedServiceId services showResponseOnly temperature
        """)
        add("appearance", "nkmrcfg", """
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
        add("chats", "nkmrcfg", """
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
        add("nagram", "nkmrcfg", """
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
        add("neko", "nkmrcfg", """
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
        add("general", "nkmrcfg", """
        botPrivacyAlwaysAsk=OEGeneralBotPrivacyAlwaysAsk botPrivacyEnabled=OEGeneralBotPrivacyEnabled botPrivacyUserId=OEGeneralBotPrivacyUserId contentCapture=OEGeneralContentCapture crashReports=OEGeneralCrashReports downloadSpeedBoost=OEGeneralDownloadSpeedBoost showNagramSettings=OEGeneralShowNagramSettings
        """)
        add("openextera", "nkmrcfg", "addCommaAfterMention=OEAddCommaAfterMention downloadEmojiPacks=OEDownloadEmojiPacks proxyDisableConditions=OEProxyDisableConditions relativeLastSeen=OERelativeLastSeen")
        add("glyph", "nkmrcfg", "enabled=OEGlyphEnabled onCall=OEGlyphCalls onNewMessage=OEGlyphNewMessage onRecording=OEGlyphRecording screenOffOnly=OEGlyphScreenOff")
        add("icons", "nkmrcfg", "activePacks=OEIconPacksActive customNotificationIcon=OEIconPacksNotificationIcon editingPackId=OEIconPacksEditing enabled=OEIconPacksEnabled useSystemIconShape=OEIconPacksSystemShape")
        add("pillstack", "nkmrcfg", """
        activePillsRaw=OEPillActivePills btcTargetCurrency=OEPillBtcCurrency ethTargetCurrency=OEPillEthCurrency eurTargetCurrency=OEPillEurCurrency goldPriceCache=OEPillGoldPriceCache
        goldPriceCacheTime=OEPillGoldPriceCacheTime goldTargetCurrency=OEPillGoldCurrency gramTargetCurrency=OEPillGramCurrency hiddenPillsRaw=OEPillHiddenPills infiniteScrolling=OEPillInfiniteScrolling
        lastActivePillId=OEPillLastActiveId rateInstancesMigrated=OEPillRateInstancesMigrated rateInstancesRaw=OEPillRateInstances ratesCache=OEPillRatesCache ratesCacheTime=OEPillRatesCacheTime
        usdTargetCurrency=OEPillUsdCurrency weatherAddress=OEPillWeatherAddress weatherLatitude=OEPillWeatherLat weatherLongitude=OEPillWeatherLon weatherUseCurrentLocation=OEPillWeatherCurrentLocation
        """)
        add("utils", "nkmrcfg", "predictiveBackIntensity=OEPredictiveBackIntensity")
        add("cloudsettingshelper", "nekocloud", "autoSync=auto_sync includeApiKeys=include_api_keys localSyncedDate=updated_at")
        add("nekox", "nekox_config", "customApi=custom_api customAppHash=custom_app_hash customAppId=custom_app_id")
        add("etgbackup", "mainconfig", "ChatSwipeAction")
        return result
    }()

    static func ids(section: String, key: String) -> [String] {
        if let exact = entries[section + "." + key] { return exact }
        for suffix in ["_long", "_float"] where key.hasSuffix(suffix) {
            if let ids = entries[section + "." + String(key.dropLast(suffix.count))] { return ids }
        }
        if section == "nkmrcfg", key.hasPrefix("translateInputLang_") { return ["translator.inputTranslateLangForChat"] }
        if section == "nkmrcfg", key.hasPrefix("chatNameOverride_") { return ["localnamehelper.chatNameOverride"] }
        if section == "nkmrcfg", key.hasPrefix("userNameOverride_") { return ["localnamehelper.userNameOverride"] }
        if section == "nkmrcfg", key.hasPrefix("customForumTabs_") { return ["dialog.customForumTabsEnable"] }
        if section == "nkmrcfg", key.hasPrefix("useLocalEmojiStatusData_") { return ["nagram.useLocalEmojiStatusData"] }
        if section == "nkmrcfg", key.hasPrefix("useLocalQuoteColorData_") { return ["nagram.useLocalQuoteColorData"] }
        return []
    }
}
