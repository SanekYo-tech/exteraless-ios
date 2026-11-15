import Foundation

/// Existing chat, feed, playback and pill definitions remain registered here.
/// Domain-specific feature files add only the previously missing preferences.
public enum ChatFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(key: "chats.activePillsRaw", title: "Active status pills", section: "Chats · Status pills", defaultValue: .string("5,6"), explanation: "Ordered original IDs and configured rate instances. Use Status Pills for selection and reordering.", androidSymbols: ["PillStackConfig.activePillsRaw"]),
        ClientSettingDefinition(key: "chats.hiddenPillsRaw", title: "Hidden status pills", section: "Chats · Status pills", defaultValue: .string(""), androidSymbols: ["PillStackConfig.hiddenPillsRaw"]),
        ClientSettingDefinition(key: "chats.lastActivePillId", title: "Last selected status pill", section: "Chats · Status pills", defaultValue: .integer(-1), androidSymbols: ["PillStackConfig.lastActivePillId"]),
        toggle("infiniteScrolling", "Loop status pills", "Chats · Status pills", true,
            nil, "PillStackConfig.infiniteScrolling"),
        toggle("inlineMathResult", "Inline calculator", "Chats · Composer", true,
            "Type an expression ending in =, then tap its result to insert it.", "ChatsConfig.inlineMathResult"),
        toggle("inlineMathCurrency", "Inline currency conversion", "Chats · Composer", true,
            "Recognized currency expressions are queried through @calcmulabot. Results are inserted only when tapped.", "ChatsConfig.inlineMathCurrency"),
        toggle("keepAttachButton", "Keep attachment button while typing", "Chats · Composer", false, nil, "ChatsConfig.keepAttachButton"),
        toggle("hideBotButtonInInputField", "Hide bot menu button", "Chats · Composer", false, nil, "NaConfig.hideBotButtonInInputField"),
        toggle("showQuickReplyInBotCommands", "Quick replies alongside bot commands", "Chats · Composer", false, nil, "NaConfig.showQuickReplyInBotCommands"),
        toggle("typeMessageHintUseGroupName", "Chat name in message placeholder", "Chats · Composer", false, nil, "NaConfig.typeMessageHintUseGroupName"),
        toggle("showSendAsUnderMessageHint", "Sender in message placeholder", "Chats · Composer", false, nil, "NaConfig.showSendAsUnderMessageHint"),
        toggle("useChatAttachMediaMenu", "Choose recording type from a menu", "Chats · Composer", false, nil, "NekoConfig.useChatAttachMediaMenu"),
        toggle("confirmAVMessage", "Preview voice and video before sending", "Chats · Sending", false, nil, "NekoConfig.confirmAVMessage"),
        toggle("askBeforeCall", "Confirm before calling", "Chats · Calls", true, nil, "NekoConfig.askBeforeCall"),
        ClientSettingDefinition(key: ChatDeleteMenuDefaults.key, title: "Deletion defaults · raw bitmask", section: "Chats · Actions", defaultValue: .integer(0), explanation: "The Deletion defaults screen edits the four original linked flags: ban (8), report (4), delete all (2), common groups (1).", androidSymbols: ["NaConfig.defaultDeleteMenu", "ConfigItemKeyLinked"]),
        toggle("sendCommentAfterForward", "Comment after forwarded messages", "Chats · Sending", true, nil, "NekoConfig.sendCommentAfterForward"),
        toggle("disableMarkdown", "Disable automatic typed Markdown", "Chats · Composer", false,
            "Explicit formatting and existing rich content are preserved.", "NaConfig.disableMarkdown"),
        ClientSettingDefinition(key: "chats.markdownParser", title: "Typed Markdown grammar", section: "Chats · Composer", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "Telegram"),
            ClientSettingOption(value: .integer(1), title: "Neko · inline links and adjacent markers")
        ], androidSymbols: ["NaConfig.markdownParser", "EntitiesHelper.parseMarkdown"]),
        toggle("enablePanguOnSending", "CJK–Latin spacing on send", "Chats · Sending", false,
            "Thin spaces preserve formatting; URLs, code and structural rich messages remain literal.", "NaConfig.enablePanguOnSending"),
        toggle("disableLinkPreviewByDefault", "Disable link previews by default", "Chats · Composer", false,
            "The composer More menu can enable a preview for the current draft.", "NekoConfig.disableLinkPreviewByDefault"),
        toggle("fixLinkPreview", "Repair supported link previews", "Chats · Links", true,
            "Uses the original built-in alternate preview hosts. Sent link text stays unchanged; signed links are preserved.", "NaConfig.fixLinkPreview"),
        ClientSettingDefinition(key: "chats.defaultScheduledTime", title: "Default schedule delay", section: "Chats · Sending", defaultValue: .integer(10), options: ChatComposerPolicy.scheduleMinutes.map { minutes in
            ClientSettingOption(value: .integer(Int64(minutes)), title: minutes < 60 ? "\(minutes) minutes" : (minutes < 1440 ? "\(minutes / 60) hours" : "\(minutes / 1440) days"))
        }, androidSymbols: ["NaConfig.defaultScheduledTime", "ScheduleTimeHelper"]),
        toggle("stripTrackingOnPaste", "Remove tracking from pasted links", "Chats · Composer", true,
            "Uses URL-tracking filter rules. Signed links and literal code remain intact.", "ChatsConfig.stripTrackingOnPaste"),
        toggle("stripTrackingOnOpen", "Remove tracking when opening links", "Chats · Links", true,
            "Uses the same URL-tracking filter as pasted links.", "ChatsConfig.stripTrackingOnOpen"),
        toggle("confirmAllLinks", "Confirm all links", "Chats · Links", false,
            nil, "NaConfig.confirmAllLinks"),
        toggle("skipOpenLinkConfirm", "Skip ordinary concealed-link prompts", "Chats · Links", false,
            "Explicit confirmations, proxy links and hidden-host login URLs retain their native checks. Confirm all links takes precedence.", "NekoConfig.skipOpenLinkConfirm"),
        toggle("addCommaAfterMention", "Comma after an @mention", "Chats · Composer", true,
            nil, "OpenExteraConfig.addCommaAfterMention"),
        toggle("hideSendAsChannel", "Hide send-as selector", "Chats · Composer", false,
            "Hides the local selector. The selected sender and server permissions are retained.", "NekoConfig.hideSendAsChannel"),
        toggle("hideKeyboardOnChatScroll", "Hide keyboard when scrolling chat", "Chats · Composer", false,
            nil, "NekoConfig.hideKeyboardOnChatScroll"),
        toggle("hideCameraTile", "Hide attachment camera tile", "Chats · Attachments", false,
            "Applies to the chat media picker; the camera remains available through attachment actions.", "ChatsConfig.hideCameraTile"),
        toggle("alwaysSendInHD", "Prefer HD photos by default", "Chats · Attachments", true,
            "Each photo can still override quality. Turning this off restores Telegram's remembered quality.", "ChatsConfig.alwaysSendInHD"),
        toggle("hdrPhotos", "Display HDR photos", "Chats · Media", true,
            "Uses the original image's HDR data in the gallery on iOS 17 and supported displays. Other images use standard range.", "ChatsConfig.hdrPhotos"),
        toggle("sendMp4DocumentAsVideo", "Send MP4 files as videos", "Chats · Attachments", true,
            "Adds native video metadata to playable MP4 documents. Captions, grouping and other attributes are retained.", "NaConfig.sendMp4DocumentAsVideo"),
        toggle("showSmallGIF", "Compact GIFs in chat", "Chats · Media", false,
            "Single GIFs use a compact 120-point preview. Albums retain their native mosaic geometry.", "NaConfig.showSmallGIF"),
        toggle("takeGIFasVideo", "Video controls for GIFs", "Chats · Playback", false,
            "Adds the native gallery scrubber and video controls without changing the message's media type.", "NekoConfig.takeGIFasVideo"),
        toggle("autoPauseVideo", "Pause videos in background", "Chats · Playback", true,
            "Resumes the same gallery video on return if this preference paused it.", "NekoConfig.autoPauseVideo"),
        toggle("disableInAppBrowserGestures", "Disable browser navigation gestures", "Chats · Links", false,
            "Disables swipe-back navigation and interactive browser dismissal. Toolbar buttons and page scrolling remain available.", "NaConfig.disableInAppBrowserGestures"),
        toggle("translateInSheet", "Translate messages in a sheet", "Chats · Translation", false,
            "Eligible messages open the native translation sheet using the selected provider and rich content.", "ChatsConfig.translateInSheet"),
        toggle("wideChannelPosts", "Wide channel posts", "Chats · Messages", false,
            "Uses the native full-width layout within safe insets and the share-button slot.", "ChatsConfig.wideChannelPosts"),
        toggle("wideFeedPosts", "Edge-to-edge feed rows", "Chats · Feed", false,
            "Applies when reopening the feed.", "ChatsConfig.wideFeedPosts"),
        toggle("hideGiftButtonInChannel", "Hide channel gift button", "Chats · Messages", false,
            nil, "NaConfig.hideGiftButtonInChannel"),
        ClientSettingDefinition(key: "chats.bottomButton", title: "Channel bottom action", section: "Chats · Messages", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "Hidden"),
            ClientSettingOption(value: .integer(1), title: "Mute / unmute"),
            ClientSettingOption(value: .integer(2), title: "Discussion")
        ], explanation: "Joined broadcast channels only. Join, moderation and pinned-message actions remain available. Discussion falls back to mute when there is no linked group.", androidSymbols: ["ChatsConfig.bottomButton"]),
        toggle("showMessageDetails", "Message details", "Chats · Message actions", false,
            "Adds a details screen with copyable message, chat and sender IDs.", "NekoConfig.showMessageDetails"),
        toggle("showMessageID", "Copy message ID", "Chats · Message actions", false,
            nil, "NaConfig.showMessageID"),
        toggle("showAddToSavedMessages", "Save to Saved Messages", "Chats · Message actions", false,
            nil, "NekoConfig.showAddToSavedMessages"),
        toggle("showRepeat", "Repeat message", "Chats · Message actions", false,
            "Uses Telegram's native forwarding operation and keeps media and entities.", "NekoConfig.showRepeat"),
        toggle("repeatConfirm", "Confirm repeat", "Chats · Message actions", true,
            nil, "NekoConfig.repeatConfirm"),
        toggle("disableClickCommandToSend", "Confirm bot commands", "Chats · Message actions", false,
            nil, "NaConfig.disableClickCommandToSend"),
        toggle("silentMessageByDefault", "Send silently by default", "Chats · Sending", false,
            "Explicit sound/silent choices override this default; media, inline and forwarded content use their native enqueue path.", "NaConfig.silentMessageByDefault"),
        toggle("stickerTimeSide", "Sticker time beside sticker", "Chats · Stickers", false,
            "Falls back to the native overlay if the time, name and share control do not fit.", "ChatsConfig.stickerTimeSide"),
        toggle("hideTimeForSticker", "Hide sticker time", "Chats · Stickers", false,
            nil, "NekoConfig.hideTimeForSticker"),
        ClientSettingDefinition(key: "chats.stickerShape", title: "Sticker shape", section: "Chats · Stickers", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "Original"),
            ClientSettingOption(value: .integer(1), title: "Rounded"),
            ClientSettingOption(value: .integer(2), title: "Message corners")
        ], androidSymbols: ["ChatsConfig.stickerShape"]),
        toggle("replyColors", "Peer colors in replies", "Chats · Replies", true, nil, "ChatsConfig.replyColors"),
        toggle("replyEmoji", "Emoji in replies", "Chats · Replies", true, nil, "ChatsConfig.replyEmoji"),
        toggle("replyBackground", "Reply background", "Chats · Replies", true, nil, "ChatsConfig.replyBackground"),
        toggle("removeMessageTail", "Remove message tail", "Chats · Messages", true, nil, "ChatsConfig.removeMessageTail"),
        toggle("unreadCapsule", "Unread separator capsule", "Chats · Messages", false, nil, "ChatsConfig.unreadCapsule"),
        toggle("hideShareButtonInChannel", "Hide channel share button", "Chats · Messages", false, nil, "NaConfig.hideShareButtonInChannel"),
        toggle("showTimeHint", "Tap message time for details", "Chats · Messages", false, nil, "NaConfig.showTimeHint"),
        toggle("showSpoilersDirectly", "Reveal text spoilers", "Chats · Messages", false,
            "Reveals message text locally. Media spoilers and secret-media controls retain their native behavior.", "NekoConfig.showSpoilersDirectly"),
        toggle("hideCallButton", "Hide chat call action", "Chats · Header actions", false, nil, "ChatsConfig.hideCallButton"),
        toggle("hideChannelSearchButton", "Hide channel search action", "Chats · Header actions", false, nil, "ChatsConfig.hideChannelSearchButton"),
        toggle("hideMoneyButton", "Hide attachment Money tab", "Chats · Attachments", false, nil, "ChatsConfig.hideMoneyButton"),
        toggle("hideReactionsInChannels", "Hide channel reactions", "Chats · Reactions", false,
            "Local display only.", "ChatsConfig.hideReactionsInChannels"),
        toggle("hideReactionsInGroups", "Hide group reactions", "Chats · Reactions", false,
            "Local display only.", "ChatsConfig.hideReactionsInGroups"),
        toggle("hideReactionsInPrivate", "Hide private-chat reactions", "Chats · Reactions", false,
            "Local display only.", "ChatsConfig.hideReactionsInPrivate"),
        toggle("showResultsBeforeVoting", "Show available poll results before voting", "Chats · Messages", false,
            "Shows only counts already supplied by Telegram; hidden server results stay hidden.", "ChatsConfig.showResultsBeforeVoting"),
        toggle("pauseOnMinimizeVoice", "Pause voice messages in background", "Chats · Playback", false,
            nil, "ChatsConfig.pauseOnMinimizeVoice"),
        toggle("pauseOnMinimizeRound", "Pause video messages in background", "Chats · Playback", false,
            nil, "ChatsConfig.pauseOnMinimizeRound"),
        toggle("dontAutoPlayNextVoice", "Stop after each voice message", "Chats · Playback", false,
            "Manual Next and Previous remain available.", "NaConfig.dontAutoPlayNextVoice"),
        toggle("disableProximityEvents", "Disable proximity playback", "Chats · Playback", false,
            "Applies to new playback sessions. Telegram's Raise to Listen preference is also respected.", "NekoConfig.disableProximityEvents"),
        toggle("preferOriginalQuality", "Prefer highest video quality", "Chats · Playback", false,
            "Selects the highest available native video quality when opening the viewer.", "ChatsConfig.preferOriginalQuality"),
        ClientSettingDefinition(key: "chats.defaultHlsVideoQuality", title: "Default streaming video quality", section: "Chats · Playback", defaultValue: .integer(0), options: [
            .init(value: .integer(0), title: "Automatic"), .init(value: .integer(2), title: "1440p or higher"),
            .init(value: .integer(3), title: "1080p"), .init(value: .integer(4), title: "720p"),
            .init(value: .integer(5), title: "480p")
        ], explanation: "Falls back to lower available qualities. Prefer highest video quality takes precedence. Legacy value 1 migrates to that preference.", androidSymbols: ["NaConfig.defaultHlsVideoQuality", "VideoPlayer.getDefaultSavedQuality", "ChatsConfig.migrateLegacyKeys"]),
        ClientSettingDefinition(key: "chats.doubleTapSeekDuration", title: "Double-tap video seek", section: "Chats · Playback", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "5 seconds"),
            ClientSettingOption(value: .integer(1), title: "10 seconds"),
            ClientSettingOption(value: .integer(2), title: "15 seconds"),
            ClientSettingOption(value: .integer(3), title: "30 seconds")
        ], androidSymbols: ["ChatsConfig.doubleTapSeekDuration", "ChatsConfig.SEEK_DURATIONS"]),
        ClientSettingDefinition(key: "chats.musicPlaybackSpeed", title: "Music playback speed", section: "Chats · Playback", defaultValue: .number(1.0), minimum: 0.5, maximum: 2.0, step: 0.1, androidSymbols: ["MediaController.musicPlaybackSpeed", "PlayerSheet.SPEEDS"])
    ] + ["doubleTapAction", "doubleTapActionOut"].map { field in
        ClientSettingDefinition(key: "chats.\(field)", title: field == "doubleTapAction" ? "Incoming message double tap" : "Outgoing message double tap", section: "Chats · Gestures", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "Disabled"),
            ClientSettingOption(value: .integer(1), title: "Quick reaction (native)"),
            ClientSettingOption(value: .integer(2), title: "Reactions and message menu"),
            ClientSettingOption(value: .integer(3), title: "Translate"),
            ClientSettingOption(value: .integer(4), title: "Reply"),
            ClientSettingOption(value: .integer(5), title: "Save to Saved Messages"),
            ClientSettingOption(value: .integer(6), title: "Repeat"),
            ClientSettingOption(value: .integer(7), title: "Repeat as copy"),
            ClientSettingOption(value: .integer(8), title: "Edit"),
            ClientSettingOption(value: .integer(9), title: "Translate with AI"),
            ClientSettingOption(value: .integer(10), title: "Delete"),
            ClientSettingOption(value: .integer(11), title: "Forward"),
            ClientSettingOption(value: .integer(12), title: "Save to device")
        ], androidSymbols: ["NaConfig.\(field)", "DoubleTap"])
    } + ["includeArchived", "addNewChannels", "excludedChannels", "knownChannels"].map { field in
        ClientSettingDefinition(key: "chats.\(field)", title: "Feed · \(field)", section: "Chats · Feed account data", defaultValue: .object([:]), explanation: "Account-keyed data managed by the Channel feed → Channels screen. New accounts exclude the archive, automatically add joined channels and have no exclusions.", androidSymbols: ["FeedConfig.\(field)"])
    } + ChatMenuPolicy.preferences.map { item in
        toggle(item.field, item.title, "Chats · Actions", item.initial, nil, item.source + "." + item.field)
    } + [
        ClientSettingDefinition(key: "chats.leftBottomButton", title: "Left selection action", section: "Chats · Actions", defaultValue: .integer(0), options: [
            .init(value: .integer(0), title: "Forward without sender"), .init(value: .integer(1), title: "Reply"),
            .init(value: .integer(2), title: "Save to Saved Messages"), .init(value: .integer(3), title: "Share"),
            .init(value: .integer(4), title: "Select between"), .init(value: .integer(5), title: "Forward without caption")
        ], androidSymbols: ["NaConfig.leftBottomButton", "ChatsHelper.getLeftButtonAction"]),
        ClientSettingDefinition(key: "chats.combineMessage", title: "Combined message reply", section: "Chats · Actions", defaultValue: .integer(0), options: [
            .init(value: .integer(0), title: "Keep the first message's reply"), .init(value: .integer(1), title: "Current thread")
        ], explanation: "Combine selected text into an editable draft before native Send. Structured/media messages keep their own actions.", androidSymbols: ["NaConfig.combineMessage"])
    ] + ChatFormattingPolicy.actions.map { action in
        toggle(action.settingField, action.title, "Chats · Formatting menu", true, nil, "NaConfig.\(action.settingField)")
    } + [
        ClientSettingDefinition(key: "chats.textStyleOrder", title: "Formatting order", section: "Chats · Formatting menu", defaultValue: .string(ChatFormattingPolicy.defaultOrder), explanation: "Comma-separated: translate, bold, italic, mono, code, strike, underline, quote, spoiler, link, mention, date, regular. Missing actions are appended.", androidSymbols: ["NaConfig.textStyleOrder", "TextStyleDialog.DEFAULT_ORDER"])
    ]

    /// Run after registration and before either chat or AI consumers start. The existing
    /// canonical override wins, including explicit true; migration is atomic and idempotent.
    public static func migrateSettings(in settings: ClientSettings = .shared) throws {
        try settings.migrateKey(from: "ai.showTextTranslate", to: "chats.showTextTranslate")
    }

    private static func toggle(_ field: String, _ title: String, _ section: String, _ value: Bool, _ explanation: String?, _ symbol: String) -> ClientSettingDefinition {
        return ClientSettingDefinition(key: "chats.\(field)", title: title, section: section, defaultValue: .bool(value), explanation: explanation, androidSymbols: [symbol])
    }
}
