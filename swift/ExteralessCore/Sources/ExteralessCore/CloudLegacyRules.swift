import Foundation

/// Audited preference conversions, distinct from the reporting-only source index.
/// Booleans remain booleans. Numeric options use explicit semantic conversions;
/// there is no generic Android-int -> native-enum operation.
enum CloudLegacyRules {
    enum Conversion: Sendable {
        case boolean, text, language, languages, model, endpoint, builtinRole, vendorAccount, integer(ClosedRange<Int64>)
        case float(ClosedRange<Double>)
        case translationProvider, llmPreset, doubleTap, translatorMode, transcription
        case options([Int64: Int64])
    }
    struct Rule: Sendable { let key: String; let conversion: Conversion }

    static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        func booleans(_ source: String, _ target: String, _ fields: String) {
            for rawField in fields.split(whereSeparator: { $0.isWhitespace }) {
                let field = String(rawField)
                rules[source + "." + field] = Rule(key: target + "." + field, conversion: .boolean)
            }
        }
        booleans("ai", "ai", "disableTools insertAsQuote replaceTelegramEditor replaceTelegramSummaries responseStreaming saveHistory showResponseOnly")
        booleans("appearance", "appearance", """
        customThemes glassMessageMenu gooeyAvatarAnimation hideActionBarStatus immersiveDrawerAnimation iosNavigationBarStyle
        lrclibAllowed m3ListItems md3MiniPlayer md3Player navigationDrawer newChatHeaderStyle newLoadingStyle newNavigationBarStyle
        playerCoverExtend playerCoverSwipe playerDiscSpin playerMiniArtist playerMiniClose playerMiniCompact playerMiniNext
        playerMiniPrevious playerMiniTop playerShowActions playerShowLike playerShowModes playerShowSource playerTitleAbove playerWavy
        profileMusicCard senderMiniAvatars separateHeaders showFeedTab showFeedUnreadCounter singleCornerRadius squareFab
        """)
        booleans("chats", "chats", """
        alwaysSendInHD hideCallButton hideCameraTile hideChannelSearchButton hideMoneyButton hideReactionsInChannels hideReactionsInGroups
        hideReactionsInPrivate inlineMathCurrency inlineMathResult keepAttachButton pauseOnMinimizeRound pauseOnMinimizeVoice
        preferOriginalQuality removeMessageTail replyBackground replyColors replyEmoji showResultsBeforeVoting stickerTimeSide
        stripTrackingOnOpen stripTrackingOnPaste swipeToPip unreadCapsule wideChannelPosts wideFeedPosts
        """)
        booleans("chats", "tools", "cameraMirrorMode cameraStabilization extendedFramesPerSecond rememberLastUsedCamera startWithWideAngleCamera staticZoom zoomSlider")
        booleans("nagram", "appearance", "alwaysShowDownloadIcon centerActionBarTitle disableAvatarBlur disableBotOpenButton disableDialogsFloatingButton hideBottomNavigationBar hideDialogsSearchField hideStoriesFromHeader mainTabsHideCallsSettings mainTabsHideContacts mainTabsHideProfile mainTabsHideTitles")
        booleans("nagram", "chats", """
        ActionBarButtonCopy ActionBarButtonEdit ActionBarButtonForward ActionBarButtonReply ActionBarButtonSelectBetween
        chatMenuItemBoostGroup chatMenuItemClearDeleted chatMenuItemDeleteOwnMessages chatMenuItemGoToMessage chatMenuItemHideTitle chatMenuItemLinkedChat chatMenuItemToBeginning chatMenuItemViewDeleted
        confirmAllLinks disableClickCommandToSend disableMarkdown dontAutoPlayNextVoice enablePanguOnSending fixLinkPreview hideBotButtonInInputField hideGiftButtonInChannel hideShareButtonInChannel
        mediaViewerMenuItemCopyFrame mediaViewerMenuItemCopyPhoto mediaViewerMenuItemForward mediaViewerMenuItemNoQuoteForward mediaViewerMenuItemScanQRCode mediaViewerMenuItemSetProfilePhoto
        showMessageID showQuickReplyInBotCommands showSendAsUnderMessageHint showTextBold showTextCreateDate showTextCreateLink showTextCreateMention showTextItalic showTextMono showTextMonoCode
        showTextQuote showTextRegular showTextSpoiler showTextStrikethrough showTextTranslate showTextUnderline showTimeHint silentMessageByDefault typeMessageHintUseGroupName
        showAddToBookmark showAddToFavorites showAddToStickers showCopyAsSticker showCopyFrame showCopyLink showCopyPhoto showNoQuoteForward showReactions showRepeatAsCopy showReplyInPrivate showSetReminder
        shortcutsAdministrators shortcutsMembers shortcutsPermissions shortcutsRecentActions shortcutsStatistics
        """)
        booleans("nagram", "privacy", "askBeforeOpeningStory ghostScheduledSend saveLocalLastSeen saveReadDate showNotificationPreviewWhenLocked")
        booleans("nagram", "ai", "enableSeparateArticleTranslator googleTranslateExp keepTranslatorPreferences llmUseContext llmUseContextInAutoTranslate showTranslateMessageLLM telegramUIAutoTranslate translatorKeepMarkdown")
        booleans("nagram", "identity", "dateOfForwardedMsg preferCommonGroupsTab premiumItemBoosts premiumItemCustomColorInReplies premiumItemCustomWallpaper premiumItemEmojiInReplies premiumItemEmojiStatus premiumItemStarInReactions premiumItemStickerEffects premiumItemVideoAvatar showFullAbout showOnlineStatus")
        booleans("neko", "appearance", "disableNumberRounding disableVibration mediaPreview showSeconds")
        booleans("neko", "chats", "askBeforeCall confirmAVMessage disableLinkPreviewByDefault disableProximityEvents hideKeyboardOnChatScroll hideSendAsChannel hideTimeForSticker repeatConfirm sendCommentAfterForward showAddToSavedMessages showAdminActions showChangePermissions showDeleteDownloadedFile showMessageDetails showMessageHide showRepeat showReport showShareMessages showSpoilersDirectly showViewHistory skipOpenLinkConfirm useChatAttachMediaMenu")
        booleans("neko", "privacy", "hidePhone markReadAfterSend sendOfflinePacketAfterOnline sendOfflinePacketAfterOnlineLocked sendOnlinePackets sendOnlinePacketsLocked sendReadMessagePackets sendReadMessagePacketsLocked sendReadStoriesPackets sendReadStoriesPacketsLocked sendUploadProgress sendUploadProgressLocked showGhostInDrawer showGhostModeStatus")
        booleans("neko", "identity", "displayPersianCalendarByLatin localPremium usePersianCalendar")
        booleans("neko", "ai", "showTranslate")
        booleans("neko", "network", "useIPv6")
        booleans("openextera", "chats", "addCommaAfterMention")
        booleans("openextera", "appearance", "relativeLastSeen")
        booleans("general", "privacy", "botPrivacyAlwaysAsk botPrivacyEnabled contentCapture")
        booleans("general", "tools", "crashReports")
        func add(_ id: String, _ key: String, _ conversion: Conversion) { rules[id] = Rule(key: key, conversion: conversion) }
        add("neko.typeface", CoreAppearanceFontFamilyPolicy.key, .boolean)
        add("neko.tabletMode", "appearance.tabletMode", .options([0: 0, 1: 1, 2: 2]))
        add("appearance.monetStyle", AppearanceMonetPolicy.settingKey, .options([0: 0, 1: 1]))
        add("nagram.performanceClass", ToolsPerformancePolicy.key, .options([0: 0, 1: 1, 2: 2, 3: 3]))
        booleans("chats", "chats", "hdrPhotos translateInSheet")
        booleans("nagram", "chats", "disableInAppBrowserGestures sendMp4DocumentAsVideo showSmallGIF")
        booleans("neko", "chats", "autoPauseVideo takeGIFasVideo")
        add("chats.bottomButton", "chats.bottomButton", .options([0: 0, 1: 1, 2: 2]))
        add("etgbackup.ChatSwipeAction", ChatSwipePolicy.settingKey, .options([-1: -1, 0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5]))
        // Source value 1 is projected to preferOriginalQuality before conversion.
        add("nagram.defaultHlsVideoQuality", "chats.defaultHlsVideoQuality", .options([0: 0, 2: 2, 3: 3, 4: 4, 5: 5]))
        add("ai.temperature", "ai.temperature", .integer(0...20))
        add("ai.selectedRole", "ai.selectedRole", .builtinRole)
        add("nagram.customTitle", "appearance.customTitle", .text)
        add("neko.translateToLang", "ai.translateToLang", .language)
        add("neko.translateInputLang", "ai.translateInputLang", .language)
        add("nagram.preferredTranslateTargetLang", "ai.preferredTranslateTargetLang", .languages)
        add("neko.translationProvider", "ai.translationProvider", .translationProvider)
        add("nagram.articleTranslationProvider", "ai.articleTranslationProvider", .translationProvider)
        add("nagram.llmApiUrl", "ai.llmApiUrl", .endpoint)
        add("nagram.llmModelName", "ai.llmModelName", .model)
        add("nagram.llmTemperature", "ai.llmTemperature", .float(0...2))
        add("nagram.llmContextSize", "ai.llmContextSize", .options([0: 0, 1: 1, 2: 2, 3: 3, 4: 4])) // 1/3/5/7/10 messages, not literal counts.
        add("nagram.llmProviderPreset", "ai.llmProviderPreset", .llmPreset)
        add("nagram.translatorMode", "ai.translatorMode", .translatorMode)
        add("nagram.deepLFormality", "ai.deepLFormality", .options([0: 0, 1: 1, 2: 2])) // default/informal/formal.
        add("nagram.transcribeProviderOpenAiApiBase", "ai.transcribeProviderOpenAiApiBase", .endpoint)
        add("nagram.transcribeProviderOpenAiModel", "ai.transcribeProviderOpenAiModel", .model)
        add("nagram.transcribeProviderCfAccountID", "ai.transcribeProviderCfAccountID", .vendorAccount)
        add("nagram.transcribeProvider", "ai.transcribeProvider", .transcription)
        for field in ["OpenAI", "Gemini", "Groq", "DeepSeek", "XAI", "Cerebras", "OllamaCloud", "OpenRouter", "VercelAIGateway", "Vertex"] {
            add("nagram.llmProvider" + field + "Model", "ai.llmProvider" + field + "Model", .model)
        }
        add("nagram.doubleTapAction", "chats.doubleTapAction", .doubleTap)
        add("nagram.doubleTapActionOut", "chats.doubleTapActionOut", .doubleTap)
        // These SharedPreferences store integer PERCENT, unlike ExteraConfig's
        // fractional getter aliases. Never multiply the original stored value.
        add("chats.flashIntensity", "tools.flashIntensity", .integer(0...100))
        add("chats.flashWarmth", "tools.flashWarmth", .integer(0...100))
        add("neko.tabsTitleType", "appearance.tabsTitleType", .options([0: 0, 1: 1, 2: 2])) // names/icons/both.
        add("openextera.proxyDisableConditions", "privacy.proxyDisableConditions", .options([0: 0, 2: 2, 4: 4, 6: 6])) // none/mobile/Wi-Fi/either; VPN bit is not guessed.
        return rules
    }()

    static func convert(_ value: ClientSettingValue, rule: Rule, suffix: String?, nkmrcfg: [String: ClientSettingValue],
                        definition: ClientSettingDefinition) throws -> ClientSettingValue {
        let converted: ClientSettingValue
        switch rule.conversion {
        case .boolean:
            let acceptsBoolean: Bool
            switch definition.defaultValue {
            case .bool, .null: acceptsBoolean = true
            default: acceptsBoolean = false
            }
            guard suffix == nil, case .bool = value, acceptsBoolean else { throw CloudLegacySkipReason.incompatibleType }
            converted = value
        case .text, .language, .languages, .model, .endpoint, .builtinRole, .vendorAccount:
            guard suffix == nil, case let .string(raw) = value, raw.utf8.count <= 4_096, !raw.contains("\0") else { throw CloudLegacySkipReason.incompatibleType }
            switch rule.conversion {
            case .builtinRole:
                guard AIRole.suggestions.contains(where: { $0.name == raw }) else { throw CloudLegacySkipReason.unsupportedOption }
                converted = .string(raw)
            case .vendorAccount:
                guard raw.isEmpty || (raw.utf8.count == 32 && raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })) else { throw CloudLegacySkipReason.invalidValue }
                converted = .string(raw)
            case .endpoint:
                converted = .string(raw.isEmpty ? "" : try AIRequestBuilder.normalizedBaseURL(raw).absoluteString)
            case .model:
                if !raw.isEmpty { try AIRequestBuilder.validateModel(raw) }
                converted = .string(raw)
            case .language, .languages:
                let values = { if case .languages = rule.conversion { return raw.split(separator: ",").map(String.init) }; return [raw] }()
                for language in values where !language.trimmingCharacters(in: .whitespaces).isEmpty {
                    _ = try AITranslationLanguage.normalize(language.trimmingCharacters(in: .whitespaces), provider: .google)
                }
                converted = .string(raw)
            default: converted = .string(raw)
            }
        case let .float(range):
            guard suffix == "_float" else { throw CloudLegacySkipReason.incompatibleType }
            let number: Double
            switch value {
            case let .number(value): number = value
            case let .integer(value): guard let exact = Double(exactly: value) else { throw CloudLegacySkipReason.invalidValue }; number = exact
            default: throw CloudLegacySkipReason.incompatibleType
            }
            guard number.isFinite, range.contains(number) else { throw CloudLegacySkipReason.invalidValue }
            converted = .number(number)
        default:
            guard suffix == nil, case let .integer(number) = value else { throw CloudLegacySkipReason.incompatibleType }
            switch rule.conversion {
            case let .integer(range): guard range.contains(number) else { throw CloudLegacySkipReason.invalidValue }; converted = value
            case let .options(options): guard let result = options[number] else { throw CloudLegacySkipReason.unsupportedOption }; converted = .integer(result)
            case .translationProvider:
                let providers: [Int64: AITranslationProvider] = [1: .google, 3: .yandex, 4: .lingo, 5: .microsoft, 6: .realMicrosoft, 7: .deepL, 8: .telegram, 9: .tranSmart, 10: .llm]
                guard let provider = providers[number] else { throw CloudLegacySkipReason.unsupportedOption }
                converted = .integer(Int64(provider.rawValue))
            case .llmPreset:
                let presets: [Int64: AILLMPreset] = [0: .custom, 1: .openAI, 2: .gemini, 3: .groq, 4: .deepSeek, 5: .xAI, 6: .cerebras, 7: .ollamaCloud, 8: .openRouter, 9: .vercel, 10: .vertex]
                guard let preset = presets[number] else { throw CloudLegacySkipReason.unsupportedOption }
                converted = .integer(Int64(preset.rawValue))
            case .transcription:
                let providers: [Int64: AITranscriptionProvider] = [0: .auto, 2: .workersAI, 3: .gemini, 4: .openAI, 5: .apple]
                guard let provider = providers[number] else { throw CloudLegacySkipReason.unsupportedOption }
                converted = .integer(Int64(provider.rawValue))
            case .doubleTap:
                let actions: [Int64: ChatDoubleTapAction] = [0: .disabled, 1: .quickReaction, 2: .reactions, 3: .translate, 4: .reply, 5: .save,
                    6: .repeatMessage, 7: .repeatAsCopy, 8: .edit, 9: .translateLLM, 10: .delete, 11: .forward, 12: .download]
                guard let action = actions[number] else { throw CloudLegacySkipReason.unsupportedOption }
                converted = .integer(Int64(action.rawValue))
            case .translatorMode:
                guard (0...2).contains(number) else { throw CloudLegacySkipReason.unsupportedOption }
                let migrated = nkmrcfg["TranslatorModeWithOriginalMigrated"] == .bool(true)
                converted = .integer(migrated ? number : Int64(AITranslationModeMigration.mappedLegacyValue(Int(number))))
            default: throw CloudLegacySkipReason.unsupportedOption
            }
        }
        return try definition.validatedValue(converted)
    }
}

extension CloudLegacySkipReason: Error {}
