import Foundation

/// Only the two missing feed presentation fields. The four account-local FeedConfig
/// fields and wideFeedPosts are already owned and registered by ChatFeatures.
public enum FeedFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(
            key: "appearance.showFeedTab", title: "Channel feed tab", section: "Chats · Feed",
            defaultValue: .bool(false),
            explanation: "Show the channel feed in place of the Contacts tab. Contacts remain available from Chats.",
            androidSymbols: ["AppearanceConfig.showFeedTab"]
        ),
        ClientSettingDefinition(
            key: "appearance.showFeedUnreadCounter", title: "Feed unread badge", section: "Chats · Feed",
            defaultValue: .bool(true),
            explanation: "Count unread posts in this account's included channels, including muted channels.",
            androidSymbols: ["AppearanceConfig.showFeedUnreadCounter"]
        )
    ]
}
