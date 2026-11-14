import Foundation

/// Android field names are kept here, rather than the ExteraConfig compatibility getters.
public enum PrivacyFeatures {
    public static let ghostFields = [
        "sendReadMessagePackets", "sendReadStoriesPackets", "sendOnlinePackets",
        "sendUploadProgress", "sendOfflinePacketAfterOnline"
    ]

    public static let definitions: [ClientSettingDefinition] = {
        var result = [
            flag("sendReadMessagePackets", "Send message read receipts", true, "Ghost mode", "Also controls played voice/video receipts, discussion reads and channel view increments."),
            flag("sendReadStoriesPackets", "Send story views", true, "Ghost mode"),
            flag("sendOnlinePackets", "Send online status", true, "Ghost mode", "When off, status updates report offline. Sending messages can still briefly reveal activity."),
            flag("sendUploadProgress", "Send typing and upload activity", true, "Ghost mode", "Includes recording, sticker selection, games and emoji interaction activity."),
            flag("sendOfflinePacketAfterOnline", "Go offline after sending", false, "Ghost mode", "Sends an offline update one second after an outgoing send or edit finishes."),
            flag("markReadAfterSend", "Read chat after sending", true, "Ghost mode", "When automatic read receipts are off, sending deliberately marks that chat read on the server."),
            flag("showGhostInDrawer", "Quick ghost toggle in Settings", false, "Ghost mode", "Native counterpart of the Android drawer shortcut."),
            flag("showGhostModeStatus", "Show ghost status in chat titles", false, "Ghost mode"),
            flag("askBeforeOpeningStory", "Ask before opening stories", false, "Ghost mode", "Choose normal viewing or a private session. Your own stories do not prompt.", owner: "NaConfig"),
            flag("ghostScheduledSend", "Schedule ghost sends by 12 seconds", false, "Ghost mode", "When online packets are off, eligible messages use Telegram's scheduler. Bots, Saved Messages, secret chats and special send flows keep their native path.", owner: "NaConfig"),
            flag("hidePhone", "Hide my phone number locally", true, "Local privacy", "Hides your number on profile/settings surfaces. Server phone privacy is configured separately."),
            flag("contentCapture", "Share message activity with Siri", false, "Local privacy", "Allows notification interaction donation to Siri suggestions. Notification display works independently.", owner: "GeneralConfig"),
            flag("saveLocalLastSeen", "Remember observed last seen", false, "Local privacy", "Keeps observed activity locally for seven days. Does not request hidden activity.", owner: "NaConfig"),
            flag("saveReadDate", "Remember observed read dates", false, "Local privacy", "Keeps dates from received read/played updates locally; it cannot recover dates that were never observed.", owner: "NaConfig"),
            flag("showNotificationPreviewWhenLocked", "Message previews while app is locked", false, "Notifications", "When off, locking the app removes existing message alerts and redacts new ones. iOS and each chat's preview settings still apply.", owner: "NaConfig"),
            ClientSettingDefinition(key: "privacy.proxyDisableConditions", title: "Pause proxy on", section: "Proxy", defaultValue: .integer(0), options: [
                ClientSettingOption(value: .integer(0), title: "Never"),
                ClientSettingOption(value: .integer(2), title: "Mobile data"),
                ClientSettingOption(value: .integer(4), title: "Wi-Fi"),
                ClientSettingOption(value: .integer(6), title: "Mobile data and Wi-Fi")
            ], explanation: "Keeps the selected proxy and your on/off choice; resumes when the condition ends. iOS does not expose a reliable system-wide VPN state to this app.", androidSymbols: ["OpenExteraConfig.proxyDisableConditions", "ProxyDisableCondition", "ProxyUtil.applyProxyDisableConditions"]),
            flag("botPrivacyEnabled", "Use a selected account for new bots", false, "Bot privacy", "Established conversations retain their account. Multiple established accounts require a choice.", owner: "GeneralConfig"),
            flag("botPrivacyAlwaysAsk", "Ask which account to use for new bots", false, "Bot privacy", owner: "GeneralConfig"),
            ClientSettingDefinition(key: "privacy.botPrivacyUserId", title: "Bot account user ID", section: "Bot privacy", defaultValue: .integer(0), minimum: 0, explanation: "Set by Select bot account. This is a Telegram user ID, never an account slot.", androidSymbols: ["GeneralConfig.botPrivacyUserId"]),
            ClientSettingDefinition(key: "privacy.ghostModeReadExclusions", title: "Read receipt exceptions", section: "Ghost exceptions", defaultValue: .object([:]), explanation: "Managed by Privacy for a chat; keyed by account and native peer ID.", androidSymbols: ["AyuGhostPreferences.ghostModeReadExclusions"]),
            ClientSettingDefinition(key: "privacy.ghostModeTypingExclusions", title: "Typing exceptions", section: "Ghost exceptions", defaultValue: .object([:]), explanation: "Managed by Privacy for a chat; keyed by account and native peer ID.", androidSymbols: ["AyuGhostPreferences.ghostModeTypingExclusions"])
        ]
        for field in ghostFields {
            result.append(flag(field + "Locked", "Keep “\(result.first(where: { $0.key == "privacy." + field })?.title ?? field)” when toggling ghost mode", false, "Ghost toggle exclusions"))
        }
        return result
    }()

    private static func flag(_ name: String, _ title: String, _ value: Bool, _ section: String, _ explanation: String? = nil, owner: String = "NekoConfig") -> ClientSettingDefinition {
        ClientSettingDefinition(key: "privacy." + name, title: title, section: section, defaultValue: .bool(value), explanation: explanation, androidSymbols: [owner + "." + name])
    }
}
