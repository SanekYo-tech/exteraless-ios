import Foundation

/// Exact SharedPreferences projection from ChatsConfig.migrateLegacyKeys.
/// Run on an imported nkmrcfg dictionary before mapping native keys, not on live
/// native preferences. Legacy true/false predicates intentionally take precedence
/// over conflicting OE fields in that same archive, as in the original source.
public enum ChatLegacyPreferenceMigration {
    public static func apply(to preferences: [String: ClientSettingValue]) -> [String: ClientSettingValue] {
        var result = preferences
        let hidden = preferences["DisableChannelMuteButton"] == .bool(true)
        if hidden && preferences["OEChatsBottomButton"] != .integer(0) {
            result["OEChatsBottomButton"] = .integer(0)
        } else if !hidden && preferences["OEChatsBottomButton"] == .integer(0) {
            result["DisableChannelMuteButton"] = .bool(true)
        }
        if preferences["HideReactions"] == .bool(true) {
            result["OEChatsHideReactionsChannels"] = .bool(true)
            result["OEChatsHideReactionsGroups"] = .bool(true)
            result["OEChatsHideReactionsPrivate"] = .bool(true)
            result["HideReactions"] = .bool(false)
        }
        if preferences["MessageColoredBackground"] == .bool(false) {
            result["OEChatsReplyBackground"] = .bool(false)
            result["MessageColoredBackground"] = .bool(true)
        }
        if preferences["DefaultHlsVideoQuality"] == .integer(1) {
            result["OEChatsPreferOriginalQuality"] = .bool(true)
            result["DefaultHlsVideoQuality"] = .integer(0)
        }
        return result
    }
}
