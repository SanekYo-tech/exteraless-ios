import Foundation

/// Separate registration keeps the reviewed Chat/CMC cohort immutable.
public enum ChatSwipeFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(key: ChatSwipePolicy.settingKey, title: "Primary chat swipe", section: "Chats · Chat list",
            defaultValue: .integer(-1), options: [
                .init(value: .integer(-1), title: "Automatic · folders or archive"),
                .init(value: .integer(0), title: "Pin / unpin"),
                .init(value: .integer(1), title: "Read / unread"),
                .init(value: .integer(2), title: "Archive / unarchive"),
                .init(value: .integer(3), title: "Mute / unmute"),
                .init(value: .integer(4), title: "Delete"),
                .init(value: .integer(5), title: "Folders")
            ], explanation: "Automatic uses folder paging when folders are available, otherwise Archive. Folders falls back to Archive without folders. Other choices select the primary eligible swipe action; existing buttons and native confirmations remain available.",
            androidSymbols: ["SharedConfig.chatSwipeAction", "SharedConfig.getChatSwipeAction", "SharedConfig.updateChatListSwipeSetting", "SwipeGestureSettingsView", "mainconfig.ChatSwipeAction"])
    ]
}
