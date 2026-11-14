import Foundation

/// Only preferences consumed by the native chat/media paths are registered here.
/// Account-scoped feed membership and pill selection are edited by their own screens.
public enum ChatFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        toggle("inlineMathResult", "Inline calculator", "Chats · Composer", true,
            "Type an expression ending in =, then tap its result to insert it.", "ChatsConfig.inlineMathResult"),
        toggle("inlineMathCurrency", "Inline currency conversion", "Chats · Composer", true,
            "Recognized currency expressions are queried through @calcmulabot. Results are inserted only when tapped.", "ChatsConfig.inlineMathCurrency"),
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
            "Uses Telegram's native forward-as-copy operation and keeps media and entities.", "NekoConfig.showRepeat"),
        toggle("repeatConfirm", "Confirm repeat", "Chats · Message actions", true,
            nil, "NekoConfig.repeatConfirm"),
        toggle("disableClickCommandToSend", "Confirm bot commands", "Chats · Message actions", false,
            nil, "NaConfig.disableClickCommandToSend"),
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
        ClientSettingDefinition(key: "chats.doubleTapSeekDuration", title: "Double-tap video seek", section: "Chats · Playback", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "5 seconds"),
            ClientSettingOption(value: .integer(1), title: "10 seconds"),
            ClientSettingOption(value: .integer(2), title: "15 seconds"),
            ClientSettingOption(value: .integer(3), title: "30 seconds")
        ], androidSymbols: ["ChatsConfig.doubleTapSeekDuration", "ChatsConfig.SEEK_DURATIONS"]),
        ClientSettingDefinition(key: "chats.musicPlaybackSpeed", title: "Music playback speed", section: "Chats · Playback", defaultValue: .number(1.0), minimum: 0.5, maximum: 2.0, step: 0.1, androidSymbols: ["MediaController.musicPlaybackSpeed", "PlayerSheet.SPEEDS"]),
        ClientSettingDefinition(key: "chats.activePillsRaw", title: "Active status pills", section: "Chats · Status pills", defaultValue: .string("5,6"), explanation: "Ordered IDs: 5 = cache, 6 = proxy. The Status pills screen also provides these controls.", androidSymbols: ["PillStackConfig.activePillsRaw"]),
        ClientSettingDefinition(key: "chats.hiddenPillsRaw", title: "Hidden status pills", section: "Chats · Status pills", defaultValue: .string(""), androidSymbols: ["PillStackConfig.hiddenPillsRaw"]),
        ClientSettingDefinition(key: "chats.lastActivePillId", title: "Last selected status pill", section: "Chats · Status pills", defaultValue: .integer(-1), androidSymbols: ["PillStackConfig.lastActivePillId"]),
        toggle("infiniteScrolling", "Loop status pills", "Chats · Status pills", true,
            nil, "PillStackConfig.infiniteScrolling")
    ] + ["doubleTapAction", "doubleTapActionOut"].map { field in
        ClientSettingDefinition(key: "chats.\(field)", title: field == "doubleTapAction" ? "Incoming message double tap" : "Outgoing message double tap", section: "Chats · Gestures", defaultValue: .integer(1), options: [
            ClientSettingOption(value: .integer(0), title: "Disabled"),
            ClientSettingOption(value: .integer(1), title: "Quick reaction (native)"),
            ClientSettingOption(value: .integer(2), title: "Reactions and message menu"),
            ClientSettingOption(value: .integer(4), title: "Reply")
        ], androidSymbols: ["NaConfig.\(field)", "DoubleTap"])
    } + ["includeArchived", "addNewChannels", "excludedChannels", "knownChannels"].map { field in
        ClientSettingDefinition(key: "chats.\(field)", title: "Feed · \(field)", section: "Chats · Feed account data", defaultValue: .object([:]), explanation: "Account-keyed data managed by the Channel feed → Channels screen. New accounts exclude the archive, automatically add joined channels and have no exclusions.", androidSymbols: ["FeedConfig.\(field)"])
    } + ChatFormattingPolicy.actions.map { action in
        toggle(action.settingField, action.title, "Chats · Formatting menu", true, nil, "NaConfig.\(action.settingField)")
    } + [
        ClientSettingDefinition(key: "chats.textStyleOrder", title: "Formatting order", section: "Chats · Formatting menu", defaultValue: .string(ChatFormattingPolicy.defaultOrder), explanation: "Comma-separated: bold, italic, mono, code, strike, underline, quote, spoiler, link, date. Missing actions are appended.", androidSymbols: ["NaConfig.textStyleOrder", "TextStyleDialog.DEFAULT_ORDER"])
    ]

    private static func toggle(_ field: String, _ title: String, _ section: String, _ value: Bool, _ explanation: String?, _ symbol: String) -> ClientSettingDefinition {
        return ClientSettingDefinition(key: "chats.\(field)", title: title, section: section, defaultValue: .bool(value), explanation: explanation, androidSymbols: [symbol])
    }
}
